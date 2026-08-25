using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// Refreshes the cached test menu from OpenELIS, on demand.
///
/// Sync is manual by design. A clinic changes its test menu when it commissions
/// an analyser - a handful of times a year - so a polling loop would run
/// thousands of times to catch that, and would slide changes in unnoticed. A
/// person presses the button, reads the diff, and is present to notice if it
/// says something they did not expect.
///
/// That choice moves where the risk sits, so two guards matter more here than
/// they would under a timer:
///
///   * an expired session returns an EMPTY LIST rather than an error, and
///     applying it would empty the doctor's menu with one button press;
///   * the whole set is swapped in one transaction, so there is never a moment
///     when the menu is half-written.
/// </summary>
public sealed class CatalogueSync(
    BridgeOptions options,
    BridgeStore store,
    ILogger<CatalogueSync> log)
{
    public async Task<SyncResult> RunAsync(bool force, CancellationToken ct)
    {
        var before = await store.GetCatalogueAsync(ct);
        var syncId = await store.BeginCatalogueSyncAsync(before.Count, ct);

        try
        {
            using var client = new OpenElisClient(options, log.ForClient());
            await client.AuthenticateAsync(ct);
            var discovered = await client.GetOrderableTestsAsync(ct);

            var diff = Diff(before, discovered);

            if (Reject(before.Count, discovered.Count, force) is { } reason)
            {
                await store.FinishCatalogueSyncAsync(syncId, "REJECTED", discovered.Count, diff, reason, ct);
                log.LogWarning("Catalogue sync rejected: {Reason}", reason);
                return new SyncResult(false, reason, before.Count, discovered.Count, diff);
            }

            await store.ReplaceCatalogueAsync(discovered, ct);
            await store.FinishCatalogueSyncAsync(syncId, "SUCCEEDED", discovered.Count, diff, null, ct);

            log.LogInformation(
                "Catalogue synced: {Before} -> {After} (+{Added} -{Removed} ~{Changed})",
                before.Count, discovered.Count, diff.Added.Count, diff.Removed.Count, diff.Changed.Count);

            return new SyncResult(true, null, before.Count, discovered.Count, diff);
        }
        catch (Exception ex)
        {
            await store.FinishCatalogueSyncAsync(syncId, "FAILED", before.Count, CatalogueDiff.Empty, ex.Message, ct);
            log.LogError(ex, "Catalogue sync failed; the previous menu is unchanged");
            throw;
        }
    }

    /// <summary>
    /// Why this sync must not be applied, or null if it may be.
    ///
    /// The empty case is not hypothetical: the servlet answers an expired
    /// session with a redirect, and a client that shrugged that off would parse
    /// zero tests and treat it as a laboratory that had switched everything off.
    /// </summary>
    private string? Reject(int before, int after, bool force)
    {
        if (force) return null;

        if (after == 0)
            return "the sync returned no orderable tests at all, which is far more likely to be "
                 + "a failed login than a laboratory that has switched everything off";

        if (before > 0)
        {
            var dropped = (before - after) / (double)before;
            if (dropped > options.CatalogueMaxShrink)
                return $"the menu would shrink from {before} to {after} tests "
                     + $"({dropped:P0}, limit {options.CatalogueMaxShrink:P0}); "
                     + "re-run with force if the laboratory really did withdraw them";
        }

        return null;
    }

    private static CatalogueDiff Diff(
        IReadOnlyList<CatalogueEntry> before, IReadOnlyList<CatalogueEntry> after)
    {
        // Keyed on (LOINC, specimen), because that is the identity of an
        // orderable thing — one code names several of them. Keying on the code
        // alone threw outright once the menu carried HIV viral load on three
        // specimens, and would have reported the surviving sibling as "changed"
        // when a specimen was withdrawn.
        static (string, string) Key(CatalogueEntry e) => (e.Loinc, e.SpecimenId);

        var oldByKey = before.ToDictionary(Key);
        var newByKey = after.ToDictionary(Key);

        var added = after.Where(e => !oldByKey.ContainsKey(Key(e)))
                         .Select(Describe).ToList();
        var removed = before.Where(e => !newByKey.ContainsKey(Key(e)))
                            .Select(Describe).ToList();

        // A test whose name or underlying OpenELIS test changed matters as much
        // as one that appeared. The specimen is part of the key now, so a
        // specimen change reads as a removal plus an addition — which is what it
        // clinically is, not one test edited but one withdrawn and another
        // offered.
        // The abbreviation is in this comparison because a laboratory renaming a
        // sample type's local abbreviation would otherwise change how every order
        // on that specimen binds, invisibly. It is the one field where drifting
        // out of step with OpenELIS is silent rather than loud.
        var changed = after
            .Where(e => oldByKey.TryGetValue(Key(e), out var old) &&
                        (old.Name != e.Name || old.OpenElisTestId != e.OpenElisTestId
                         || old.SpecimenAbbreviation != e.SpecimenAbbreviation))
            .Select(e => $"{Describe(e)} (was {Describe(oldByKey[Key(e)])})")
            .ToList();

        return new CatalogueDiff(added, removed, changed);
    }

    private static string Describe(CatalogueEntry e) => $"{e.Loinc} {e.Name} [{e.SpecimenName}]";
}

public sealed record CatalogueDiff(
    IReadOnlyList<string> Added,
    IReadOnlyList<string> Removed,
    IReadOnlyList<string> Changed)
{
    public static CatalogueDiff Empty { get; } = new([], [], []);
}

public sealed record SyncResult(
    bool Applied,
    string? Reason,
    int TestsBefore,
    int TestsAfter,
    CatalogueDiff Diff);

internal static class LoggerExtensions
{
    /// <summary>The client logs through the sync's category; it has no own DI scope.</summary>
    public static ILogger<OpenElisClient> ForClient(this ILogger<CatalogueSync> log) =>
        (ILogger<OpenElisClient>)new TypedLogger(log);

    private sealed class TypedLogger(ILogger inner) : ILogger<OpenElisClient>
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => inner.BeginScope(state);
        public bool IsEnabled(LogLevel logLevel) => inner.IsEnabled(logLevel);
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter) =>
            inner.Log(logLevel, eventId, state, exception, formatter);
    }
}
