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

        // The sample type's LOCAL ABBREVIATION, which is the only key OpenELIS
        // will resolve a specimen by, and is not the name.
        //
        // LabOrderSearchProvider reads the sample type off the order's Specimen
        // and looks it up with getTypeOfSampleIdForLocalAbbreviation - an exact
        // HashMap hit on type_of_sample.local_abbrev. That column is NOT the
        // display name: "Whole Blood" is stored as "Whole Bld", "Respiratory
        // Swab" as "Resp Swab". Send the name and the lookup misses, and the
        // miss is SILENT - OpenELIS falls through to the first test matching the
        // LOINC, which for a multi-specimen code is very likely the wrong one.
        //
        // rest/test-catalog/.../terminology only gives us id and name, so the
        // abbreviation comes from this second endpoint. Same ADMIN role, so it
        // costs one extra call per sync and no new permission.
        var abbreviations = await GetSampleTypeAbbreviationsAsync(ct);

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

            if (specimens.Count == 0)
            {
                // Nothing to collect. Not orderable in any meaningful sense.
                Skip("no specimen");
                continue;
            }

            // ONE ENTRY PER SPECIMEN, rather than discarding a test that runs on
            // more than one.
            //
            // A LOINC code says what is measured, not what it is measured in, so
            // "HIV Viral Load" on plasma and on serum are two orderable things
            // wearing one code. Offering them as one row forced somebody to guess
            // the specimen later; offering them as two lets the DOCTOR choose,
            // which is the only point in the workflow where the answer is known
            // for certain — they know what will be drawn.
            //
            // OpenELIS 3.2.2.0 resolves the pair (OGC-1145) in TWO places, and
            // they are not the same check:
            //
            //   import     TaskInterpreterImpl.createTestFromFHIR - only decides
            //              whether to HOLD the order AwaitingSpecimen. A carried
            //              Specimen skips the hold, then binds tests.get(0)
            //              regardless. Import never picks by specimen.
            //   accession  LabOrderSearchProvider.addToTestOrPanel - the one that
            //              actually binds, via getActiveTestByLoincCodeAndSampleType.
            //
            // So "the order imported as Entered rather than AwaitingSpecimen"
            // proves only that the hold was skipped. Binding the RIGHT test needs
            // the sample-type coding below to resolve, and a miss is silent.
            var testName = basic.RootElement.GetPropertyOrNull("name")?.GetString() ?? name;

            foreach (var specimen in specimens)
            {
                // No abbreviation means no order we place for this specimen could
                // bind deterministically, so it does not belong on the menu.
                if (!abbreviations.TryGetValue(specimen.Id!, out var abbreviation)
                    || string.IsNullOrWhiteSpace(abbreviation))
                {
                    Skip("specimen has no local abbreviation to resolve by");
                    log.LogWarning(
                        "Sample type {SpecimenId} ({Specimen}) has no local abbreviation; tests on it "
                        + "cannot be bound deterministically and are withheld from the menu",
                        specimen.Id, specimen.Name);
                    continue;
                }

                entries.Add(new CatalogueEntry(
                    Loinc: loincCodes[0]!,
                    OpenElisTestId: testId,
                    // Qualified when the test runs on several specimens, so the
                    // doctor's search box shows what actually distinguishes them.
                    // A bare "HIV Viral Load" three times over is a menu that
                    // invites picking the wrong one.
                    Name: specimens.Count == 1 ? testName : $"{testName} ({specimen.Name})",
                    SpecimenName: specimen.Name!,
                    SpecimenId: specimen.Id!,
                    SpecimenAbbreviation: abbreviation,
                    ResultUnit: null));
            }
        }

        // Collisions are judged on (LOINC, specimen) - the pair the laboratory
        // actually resolves on - not on the code alone.
        //
        // Several OpenELIS tests share a code: 94547-7 is on four COVID antibody
        // tests, 10351-5 on three HIV viral loads. That alone is no longer
        // disqualifying, because 3.2.2.0 narrows candidates by the sample type
        // the order carries, and we now send one catalogue row per specimen.
        //
        // What remains unresolvable is two tests sharing a code AND a specimen.
        // No information in the order could separate them, so both sides are
        // dropped. Picking one would be guessing which test the laboratory
        // meant, and guessing wrong sends the specimen to the wrong bench.
        var ambiguous = entries.GroupBy(e => (e.Loinc, e.SpecimenId))
                               .Where(g => g.Select(e => e.OpenElisTestId).Distinct().Count() > 1)
                               .ToList();

        foreach (var collision in ambiguous)
        {
            skipped["LOINC and specimen shared with another test"] =
                skipped.GetValueOrDefault("LOINC and specimen shared with another test") + collision.Count();
            log.LogWarning(
                "LOINC {Loinc} on specimen {Specimen} is claimed by {Count} tests ({Tests}); none is "
                + "orderable from the HIS until the laboratory disambiguates them",
                collision.Key.Loinc, collision.First().SpecimenName, collision.Count(),
                string.Join(", ", collision.Select(e => $"{e.OpenElisTestId} {e.Name}")));
        }

        var unique = entries
            .Where(e => ambiguous.All(g => g.Key != (e.Loinc, e.SpecimenId)))
            // One test may legitimately list the same specimen twice; the key
            // must not carry duplicates into an insert that now enforces it.
            .GroupBy(e => (e.Loinc, e.SpecimenId))
            .Select(g => g.First())
            .ToList();

        log.LogInformation(
            "OpenELIS catalogue: {Orderable} orderable of {Total} listed ({Skipped})",
            unique.Count, rows.GetArrayLength(),
            string.Join(", ", skipped.Select(kv => $"{kv.Value} {kv.Key}")));

        return unique;
    }

    /// <summary>
    /// Sample type id -> local abbreviation, the key OpenELIS binds specimens by.
    ///
    /// rest/sample-types is the only endpoint that exposes local_abbrev; the
    /// test-catalog terminology endpoint returns id, name and domain only. Both
    /// sit behind hasRole('ADMIN'), which the sync already holds.
    /// </summary>
    private async Task<IReadOnlyDictionary<string, string>> GetSampleTypeAbbreviationsAsync(CancellationToken ct)
    {
        var response = await GetJsonAsync("rest/sample-types", ct);

        // { success, message, data: [ { id, name, abbreviation, ... } ] }
        if (!response.RootElement.TryGetProperty("data", out var data)
            || data.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException(
                "rest/sample-types returned no data array; cannot resolve specimen abbreviations. "
                + "Refusing to sync a catalogue whose orders would bind the wrong test.");
        }

        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var row in data.EnumerateArray())
        {
            var id = row.GetPropertyOrNull("id")?.GetString();
            var abbreviation = row.GetPropertyOrNull("abbreviation")?.GetString();
            if (!string.IsNullOrWhiteSpace(id) && !string.IsNullOrWhiteSpace(abbreviation))
            {
                map[id] = abbreviation;
            }
        }

        log.LogInformation("Resolved {Count} sample type abbreviations from OpenELIS", map.Count);
        return map;
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
    // type_of_sample.local_abbrev. NOT the name, and often different from it -
    // "Whole Blood" is "Whole Bld". This is the value OpenELIS resolves an
    // incoming order's specimen by, so it is what the order must carry.
    string SpecimenAbbreviation,
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
