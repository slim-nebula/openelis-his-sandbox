using System.Net;
using System.Text.Json;
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// Reads OpenELIS's own test catalogue over its REST API.
///
/// This is the only place the bridge talks to OpenELIS as a client rather than
/// as a FHIR peer, and it is deliberately read-only: the integration reads the
/// laboratory system, it never reshapes it. That matters where the LIS is
/// subject to accreditation.
///
/// Authentication is the servlet form login, not a token: GET the login page for
/// a CSRF value, POST credentials, keep the session cookie. Because sync is
/// manual and infrequent, a session is acquired per run and discarded, so there
/// is no long-lived credential to refresh and no refresh loop to get wrong.
///
/// A LIMIT WORTH KNOWING. OpenELIS holds LOINC codes in two places:
/// clinlims.test.loinc, which TaskInterpreterImpl uses to bind an incoming
/// order, and clinlims.test_terminology_mapping, which is what this REST API
/// reports. They can disagree - in this deployment two tests have a terminology
/// mapping but a null test.loinc, so discovery reports them as ambiguous when
/// the order matcher no longer sees a collision.
///
/// That direction is safe: we under-offer. The unsafe direction would be a test
/// offered here whose test.loinc is null or different, whose orders would then be
/// refused. We cannot rule that out from here, because checking would mean
/// reading OpenELIS's database, which this architecture forbids outright.
///
/// What makes that acceptable is that the failure is loud rather than silent:
/// an unmatched order comes back REJECTED_BY_LIS with a reason, lands in the
/// order's audit trail, and is covered by the rejection suite. A drifted
/// catalogue therefore shows up as a visibly refused order, not a lost one.
/// </summary>
public sealed class OpenElisClient(BridgeOptions options, ILogger<OpenElisClient> log) : IDisposable
{
    private readonly HttpClient _http = new(new HttpClientHandler
    {
        CookieContainer = new CookieContainer(),
        UseCookies = true,
        // The sandbox serves a self-signed certificate. In a real deployment
        // this must be replaced with proper trust, which is why it is a
        // configuration flag rather than an unconditional bypass.
        ServerCertificateCustomValidationCallback = options.OpenElisAcceptAnyCertificate
            ? HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
            : null
    })
    {
        BaseAddress = new Uri(options.OpenElisBaseUrl.TrimEnd('/') + "/"),
        Timeout = TimeSpan.FromSeconds(options.OpenElisTimeoutSeconds)
    };

    public async Task AuthenticateAsync(CancellationToken ct)
    {
        var loginPage = await _http.GetStringAsync("LoginPage", ct);
        var csrf = ExtractCsrf(loginPage)
            ?? throw new InvalidOperationException(
                "No _csrf token on the OpenELIS login page; the login form has changed shape.");

        using var form = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["loginName"] = options.OpenElisUser,
            ["password"] = options.OpenElisPassword,
            ["_csrf"] = csrf
        });

        var response = await _http.PostAsync("ValidateLogin", form, ct);

        // A failed login is a redirect back to the login page rather than a 4xx,
        // so the status code alone cannot be trusted. Ask the session endpoint
        // whether we are actually authenticated.
        var session = await _http.GetStringAsync("session", ct);
        using var doc = JsonDocument.Parse(session);
        if (!doc.RootElement.TryGetProperty("authenticated", out var authenticated) ||
            !authenticated.GetBoolean())
        {
            throw new InvalidOperationException(
                $"OpenELIS rejected the credentials for '{options.OpenElisUser}' " +
                $"(ValidateLogin returned {(int)response.StatusCode}).");
        }

        log.LogInformation("Authenticated to OpenELIS as {User}", options.OpenElisUser);
    }

    /// <summary>
    /// Every test OpenELIS will accept an order for, with the LOINC code and
    /// specimen needed to place one.
    ///
    /// A test is returned only when it is unambiguous on both axes OpenELIS
    /// itself uses to bind an incoming order: exactly one LOINC mapping and
    /// exactly one specimen. Anything else would be accepted into the queue and
    /// then stall at the accessioning screen waiting for a human to pick the
    /// test, which is precisely the behaviour discovery exists to end.
    /// </summary>
    public async Task<IReadOnlyList<CatalogueEntry>> GetOrderableTestsAsync(CancellationToken ct)
    {
        var listed = await GetJsonAsync("rest/test-catalog/tests?page=1&pageSize=1000", ct);
        var rows = listed.RootElement.GetProperty("rows");

        var entries = new List<CatalogueEntry>();
        var skipped = new Dictionary<string, int>();
        void Skip(string reason) => skipped[reason] = skipped.GetValueOrDefault(reason) + 1;

        foreach (var row in rows.EnumerateArray())
        {
            var testId = row.GetProperty("testId").GetString()!;
            var name = row.GetProperty("name").GetString() ?? testId;

            if (!row.TryGetProperty("active", out var active) || !active.GetBoolean())
            {
                Skip("inactive");
                continue;
            }

            // hasLoinc is on the list row but the code itself is not, so a test
            // without one is discarded before spending two calls on it.
            if (!row.TryGetProperty("hasLoinc", out var hasLoinc) || !hasLoinc.GetBoolean())
            {
                Skip("no LOINC code");
                continue;
            }

            var basic = await GetJsonAsync($"rest/test-catalog/tests/{testId}/basic-info", ct);
            if (!basic.RootElement.TryGetProperty("orderable", out var orderable) || !orderable.GetBoolean())
            {
                // The laboratory has this test but has not switched it on for
                // ordering - typically because it owns no analyser for it.
                Skip("not orderable");
                continue;
            }

            var terminology = await GetJsonAsync($"rest/test-catalog/tests/{testId}/terminology", ct);

            var loincCodes = terminology.RootElement.GetProperty("mappings").EnumerateArray()
                .Where(m => string.Equals(m.GetPropertyOrNull("source")?.GetString(), "LOINC",
                                          StringComparison.OrdinalIgnoreCase))
                .Select(m => m.GetPropertyOrNull("code")?.GetString())
                .Where(c => !string.IsNullOrWhiteSpace(c))
                .Distinct()
                .ToList();

            if (loincCodes.Count != 1)
            {
                Skip(loincCodes.Count == 0 ? "no LOINC mapping" : "several LOINC mappings");
                continue;
            }

            var specimens = terminology.RootElement.GetProperty("sampleTypes").EnumerateArray()
                .Select(s => (Id: s.GetPropertyOrNull("id")?.GetString(),
                              Name: s.GetPropertyOrNull("name")?.GetString()))
                .Where(s => s.Id is not null && s.Name is not null)
                .ToList();

            if (specimens.Count != 1)
            {
                // OpenELIS will not choose a specimen for us and does not use the
                // Specimen resource we send to narrow it - verified against the
                // running instance. A multi-specimen test therefore cannot be
                // ordered unattended, whatever we put in the message.
                Skip(specimens.Count == 0 ? "no specimen" : "several specimens");
                continue;
            }

            entries.Add(new CatalogueEntry(
                Loinc: loincCodes[0]!,
                OpenElisTestId: testId,
                Name: basic.RootElement.GetPropertyOrNull("name")?.GetString() ?? name,
                SpecimenName: specimens[0].Name!,
                SpecimenId: specimens[0].Id!,
                ResultUnit: null));
        }

        // One LOINC, one test - checked ACROSS tests, not just within one.
        //
        // The per-test check above only proves a test has a single LOINC code.
        // Several tests can carry the SAME code: this catalogue has 94547-7 on
        // four COVID antibody tests and 777-3 on two platelet tests. OpenELIS
        // matches an incoming order on the code alone and will not choose
        // between the candidates, so an order for a shared code stalls at the
        // accessioning screen exactly as a multi-specimen test does.
        //
        // Dropping both sides of a collision is deliberate. Picking one would be
        // guessing which test the laboratory meant, and guessing wrong sends the
        // specimen to the wrong bench.
        var ambiguous = entries.GroupBy(e => e.Loinc)
                               .Where(g => g.Count() > 1)
                               .ToList();

        foreach (var collision in ambiguous)
        {
            skipped["LOINC shared with another test"] =
                skipped.GetValueOrDefault("LOINC shared with another test") + collision.Count();
            log.LogWarning(
                "LOINC {Loinc} is claimed by {Count} tests ({Tests}); none is orderable from the HIS "
                + "until the laboratory disambiguates them",
                collision.Key, collision.Count(),
                string.Join(", ", collision.Select(e => $"{e.OpenElisTestId} {e.Name}")));
        }

        var unique = entries.Where(e => ambiguous.All(g => g.Key != e.Loinc)).ToList();

        log.LogInformation(
            "OpenELIS catalogue: {Orderable} orderable of {Total} listed ({Skipped})",
            unique.Count, rows.GetArrayLength(),
            string.Join(", ", skipped.Select(kv => $"{kv.Value} {kv.Key}")));

        return unique;
    }

    /// <summary>
    /// How OpenELIS thinks its outbound push subscriptions are doing.
    ///
    /// Reported per endpoint, so the entry naming the bridge is the health of
    /// the channel results actually arrive on. maxIntervalMinutes is the cadence
    /// OpenELIS intends to keep, which is a better basis for judging staleness
    /// than a number we picked.
    /// </summary>
    public async Task<IReadOnlyList<ExportSubscription>> GetDataExportStatusAsync(CancellationToken ct)
    {
        using var doc = await GetJsonAsync("rest/DataExportStatus", ct);

        return doc.RootElement.EnumerateArray().Select(e => new ExportSubscription(
            Id: e.GetPropertyOrNull("id")?.ToString() ?? "",
            Endpoint: e.GetPropertyOrNull("endpoint").GetString() ?? "",
            LastStatus: e.GetPropertyOrNull("lastStatus").GetString(),
            LastSuccess: ParseTime(e, "lastSuccess"),
            LastAttempt: ParseTime(e, "lastAttempt"),
            FailedLast24h: ParseInt(e, "failedLast24h"),
            TotalLast24h: ParseInt(e, "totalLast24h"),
            MaxIntervalMinutes: ParseInt(e, "maxIntervalMinutes"))).ToList();
    }

    private static DateTimeOffset? ParseTime(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String &&
        DateTimeOffset.TryParse(v.GetString(), out var parsed) ? parsed : null;

    private static int? ParseInt(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;

    private async Task<JsonDocument> GetJsonAsync(string path, CancellationToken ct)
    {
        var response = await _http.GetAsync(path, ct);

        // The servlet answers an expired session with a redirect to the login
        // page, which arrives here as HTML and would otherwise surface as an
        // opaque JSON parse error a long way from the cause.
        var body = await response.Content.ReadAsStringAsync(ct);
        if (body.StartsWith("<!doctype", StringComparison.OrdinalIgnoreCase) ||
            body.StartsWith("<html", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"OpenELIS returned HTML for {path}; the session is not authenticated.");
        }

        response.EnsureSuccessStatusCode();
        return JsonDocument.Parse(body);
    }

    private static string? ExtractCsrf(string html)
    {
        var match = System.Text.RegularExpressions.Regex.Match(
            html, """name="_csrf"\s+value="([^"]+)""");
        return match.Success ? match.Groups[1].Value : null;
    }

    public void Dispose() => _http.Dispose();
}

/// <summary>One outbound push subscription, as OpenELIS reports it.</summary>
public sealed record ExportSubscription(
    string Id,
    string Endpoint,
    string? LastStatus,
    DateTimeOffset? LastSuccess,
    DateTimeOffset? LastAttempt,
    int? FailedLast24h,
    int? TotalLast24h,
    int? MaxIntervalMinutes);

/// <summary>One orderable test, as OpenELIS describes it.</summary>
public sealed record CatalogueEntry(
    string Loinc,
    string OpenElisTestId,
    string Name,
    string SpecimenName,
    string SpecimenId,
    string? ResultUnit);

internal static class JsonExtensions
{
    public static JsonElement? GetPropertyOrNull(this JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value)
            ? value
            : null;

    public static string? GetString(this JsonElement? element) =>
        element?.ValueKind == JsonValueKind.String ? element.Value.GetString() : null;
}
