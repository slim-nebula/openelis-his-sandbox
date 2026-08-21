using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// Asks OpenELIS whether it is still pushing released results to us, and judges
/// the answer.
///
/// Without this, a laboratory that has stopped delivering results looks exactly
/// like a laboratory with nothing ready: the bridge receives nothing either way.
/// Orders sit in ACCEPTED_BY_LIS and the detection mechanism is a clinician
/// eventually asking where a result went.
///
/// Separated from the timer that drives it so the same check can be run on
/// demand. An operator asking "is it working right now?" should not have to wait
/// for the next cycle, and a test should not have to sleep for one.
/// </summary>
public sealed class ExportHealthProbe(
    BridgeOptions options,
    BridgeStore store,
    ILogger<ExportHealthProbe> log)
{
    public async Task<(string Verdict, string Detail)> RunAsync(CancellationToken ct)
    {
        ExportSubscription? ours = null;
        string verdict, detail;

        try
        {
            using var client = new OpenElisClient(options, log.AsClientLogger());
            await client.AuthenticateAsync(ct);
            var subscriptions = await client.GetDataExportStatusAsync(ct);

            // Only the subscription pointing at us matters. OpenELIS may push to
            // several places, and another one being broken is not our outage.
            ours = subscriptions.FirstOrDefault(s => LooksLikeUs(s.Endpoint))
                   ?? subscriptions.FirstOrDefault();

            (verdict, detail) = ours is null
                ? ("FAILING", "OpenELIS has no export subscription pointing at the bridge")
                : Judge(ours);
        }
        catch (Exception ex)
        {
            // Not knowing is its own state. Reporting OK because the question
            // could not be asked would be worse than saying so plainly.
            verdict = "UNREACHABLE";
            detail = ex.Message;
        }

        await store.RecordExportCheckAsync(verdict, ours, detail, ct);
        return (verdict, detail);
    }

    private bool LooksLikeUs(string endpoint) =>
        endpoint.Contains("/fhir", StringComparison.OrdinalIgnoreCase) &&
        (endpoint.Contains("bridge", StringComparison.OrdinalIgnoreCase) ||
         endpoint.Contains(options.PublicFhirHost, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// OK, STALE or FAILING — judged against what OpenELIS says it intends to do
    /// rather than a threshold invented here, so the check stays correct if the
    /// laboratory changes its push cadence.
    /// </summary>
    private (string Verdict, string Detail) Judge(ExportSubscription s)
    {
        if (!string.Equals(s.LastStatus, "SUCCEEDED", StringComparison.OrdinalIgnoreCase))
            return ("FAILING",
                $"last attempt {s.LastStatus ?? "unknown"}, {s.FailedLast24h ?? 0} failures in 24h");

        if (s.LastSuccess is null)
            return ("FAILING", "the subscription has never succeeded");

        // A few cycles of grace: one missed push is a hiccup, several in a row
        // is an outage.
        var cadence = TimeSpan.FromMinutes(Math.Max(s.MaxIntervalMinutes ?? 1, 1));
        var tolerance = cadence * options.ExportStaleCycles;
        var age = DateTimeOffset.UtcNow - s.LastSuccess.Value;

        return age > tolerance
            ? ("STALE", $"last successful push {age.TotalMinutes:F0} min ago, " +
                        $"expected every {cadence.TotalMinutes:F0} min")
            : ("OK", $"last push {age.TotalMinutes:F0} min ago, {s.TotalLast24h ?? 0} in 24h");
    }
}

/// <summary>Runs the probe on a timer and says something only when the verdict changes.</summary>
public sealed class ExportMonitor(
    BridgeOptions options,
    IServiceScopeFactory scopeFactory,
    ILogger<ExportMonitor> log) : BackgroundService
{
    private string? _lastVerdict;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (!options.CatalogueDiscoveryConfigured)
        {
            log.LogInformation("Export monitoring is off: no OpenELIS REST credentials configured");
            return;
        }

        // Let OpenELIS finish starting, or restarting the whole stack reports
        // UNREACHABLE for no useful reason.
        await Task.Delay(TimeSpan.FromMinutes(1), ct);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                var probe = scope.ServiceProvider.GetRequiredService<ExportHealthProbe>();
                var (verdict, detail) = await probe.RunAsync(ct);

                // Logged on change, not every cycle. A line every five minutes
                // saying everything is fine trains people to stop reading the log,
                // which is worse than not logging at all.
                if (verdict != _lastVerdict)
                {
                    if (verdict == "OK")
                        log.LogInformation("Result push channel is healthy ({Detail})", detail);
                    else
                        log.LogWarning("Result push channel is {Verdict}: {Detail}", verdict, detail);
                    _lastVerdict = verdict;
                }
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) { log.LogError(ex, "Export status check failed unexpectedly"); }

            await Task.Delay(TimeSpan.FromMinutes(options.ExportCheckMinutes), ct);
        }
    }
}

internal static class ExportLoggerExtensions
{
    public static ILogger<OpenElisClient> AsClientLogger(this ILogger<ExportHealthProbe> log) => new Typed(log);

    private sealed class Typed(ILogger inner) : ILogger<OpenElisClient>
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => inner.BeginScope(state);
        public bool IsEnabled(LogLevel logLevel) => inner.IsEnabled(logLevel);
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter) =>
            inner.Log(logLevel, eventId, state, exception, formatter);
    }
}
