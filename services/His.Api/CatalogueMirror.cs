using System.Text.Json;
using Dapper;
using Npgsql;

namespace His.Api;

/// <summary>
/// Refreshes his.test_catalogue from the menu the bridge discovered in OpenELIS.
///
/// The HIS keeps a copy rather than calling the bridge on every page load for
/// two reasons that both matter more than freshness: lab_orders.test_code has a
/// foreign key into this table, so a test that has ever been ordered can never
/// be dropped; and a doctor opening the ordering screen while the bridge is
/// restarting should see the menu they saw yesterday, not an empty list.
///
/// This is a projection, not a second opinion. Nothing in the HIS decides what
/// is orderable - it only remembers what OpenELIS last said.
/// </summary>
public sealed class CatalogueMirror(
    NpgsqlDataSource dataSource,
    IHttpClientFactory httpClientFactory,
    ILogger<CatalogueMirror> log)
{
    public async Task<MirrorResult> RefreshAsync(string bridgeBaseUrl, CancellationToken ct)
    {
        var http = httpClientFactory.CreateClient();
        http.Timeout = TimeSpan.FromSeconds(60);

        using var response = await http.GetAsync($"{bridgeBaseUrl.TrimEnd('/')}/catalogue", ct);
        response.EnsureSuccessStatusCode();

        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        var root = doc.RootElement;

        var tests = root.GetProperty("tests").EnumerateArray().Select(t => new DiscoveredTest(
            Loinc: t.GetProperty("loinc").GetString()!,
            Name: t.GetProperty("name").GetString()!,
            SpecimenName: t.GetProperty("specimenName").GetString()!,
            ResultUnit: t.TryGetProperty("resultUnit", out var u) && u.ValueKind == JsonValueKind.String
                ? u.GetString() : null)).ToList();

        // An empty menu is refused here as well as in the bridge. The bridge
        // guards against a bad read from OpenELIS; this guards against the
        // bridge itself being freshly deployed with nothing synced yet, which
        // would otherwise deactivate every test in the HIS.
        if (tests.Count == 0)
        {
            log.LogWarning("Bridge returned an empty catalogue; leaving the HIS menu untouched");
            return new MirrorResult(false, "the bridge has no catalogue yet — run a sync there first", 0, 0, 0);
        }

        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        var before = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT count(*) FROM his.test_catalogue WHERE is_active AND source = 'DISCOVERED';",
            transaction: tx, cancellationToken: ct));

        // Matched on loinc_code so a test we already know keeps its established
        // test_code and the orders referencing it stay intact. A newly
        // discovered test has no local code to preserve, so it takes its LOINC:
        // unfamiliar to read, but stable and unambiguous, which is what a key
        // needs to be.
        var upserted = await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO his.test_catalogue
                (test_code, test_name, loinc_code, specimen_type, specimen_snomed,
                 result_unit, is_active, source, synced_at)
            VALUES (@Loinc, @Name, @Loinc, @SpecimenName, NULL,
                    @ResultUnit, true, 'DISCOVERED', now())
            ON CONFLICT (loinc_code) DO UPDATE SET
                test_name     = excluded.test_name,
                specimen_type = excluded.specimen_type,
                result_unit   = coalesce(excluded.result_unit, his.test_catalogue.result_unit),
                is_active     = true,
                source        = 'DISCOVERED',
                synced_at     = now()
            WHERE his.test_catalogue.source <> 'LOCAL';
            """, tests, transaction: tx, cancellationToken: ct));

        // Withdrawn tests are deactivated, never deleted: historical orders
        // reference them, and an order from last year must still say what it was
        // for. LOCAL rows are left alone - DRIFT is unmapped on purpose.
        var deactivated = await conn.ExecuteAsync(new CommandDefinition("""
            UPDATE his.test_catalogue
               SET is_active = false, synced_at = now()
             WHERE source = 'DISCOVERED'
               AND is_active
               AND loinc_code <> ALL (@loincs);
            """, new { loincs = tests.Select(t => t.Loinc).ToArray() },
            transaction: tx, cancellationToken: ct));

        await tx.CommitAsync(ct);

        log.LogInformation(
            "Catalogue mirror refreshed: {Upserted} offered, {Deactivated} withdrawn (was {Before})",
            tests.Count, deactivated, before);

        return new MirrorResult(true, null, tests.Count, upserted, deactivated);
    }

    private sealed record DiscoveredTest(string Loinc, string Name, string SpecimenName, string? ResultUnit);
}

public sealed record MirrorResult(
    bool Applied, string? Reason, int Offered, int Upserted, int Deactivated);
