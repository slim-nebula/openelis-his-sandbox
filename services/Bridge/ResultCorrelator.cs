using Hl7.Fhir.Model;
using Hl7.Fhir.Utility;
// Disambiguate from Hl7.Fhir.Model.Task, the FHIR resource.
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// Turns what OpenELIS pushes back into HIS-shaped results.
///
/// OpenELIS reports a released analysis as a DiagnosticReport whose basedOn
/// points at a per-analysis ServiceRequest, which in turn points at the
/// ServiceRequest the bridge originally published. Those resources arrive
/// independently and in no guaranteed order, so correlation runs on a timer
/// over the inbound mirror rather than inline on the HTTP push: a report whose
/// chain has not landed yet is simply left for the next pass, and only
/// dead-lettered once it has been unresolvable for CorrelationRetryMinutes.
/// </summary>
public sealed class ResultCorrelator(
    BridgeOptions options,
    IServiceScopeFactory scopeFactory,
    EventPublisher publisher,
    ILogger<ResultCorrelator> log) : BackgroundService
{
    /// <summary>
    /// Statuses that must reach the HIS. A laboratory does not only publish
    /// results, it corrects and withdraws them, and each of those is as clinically
    /// significant as the original.
    ///
    /// entered-in-error is included deliberately: it retracts a result the
    /// clinician has already seen. Suppressing it would leave a withdrawn value
    /// on screen indefinitely, which is worse than showing a stale one, because
    /// nothing signals that it is wrong.
    /// </summary>
    private static readonly string[] ReleasedStatuses =
        ["final", "amended", "corrected", "entered-in-error"];

    /// <summary>A retracted result carries no value - only the retraction.</summary>
    private const string RetractedStatus = "entered-in-error";

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        // Give the rest of the stack a moment before the first sweep.
        await Task.Delay(TimeSpan.FromSeconds(15), ct);

        while (!ct.IsCancellationRequested)
        {
            try { await SweepAsync(ct); }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) { log.LogError(ex, "Result correlation sweep failed"); }

            await Task.Delay(TimeSpan.FromSeconds(10), ct);
        }
    }

    private async Task SweepAsync(CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var store = scope.ServiceProvider.GetRequiredService<BridgeStore>();

        var reports = await store.GetUnprocessedAsync<DiagnosticReport>("DiagnosticReport", ct);
        if (reports.Count == 0) return;

        foreach (var (report, receivedAt) in reports)
        {
            // GetLiteral, not ToString: the enum member is EnteredInError while
            // the FHIR code is "entered-in-error", so ToString().ToLower() gives
            // "enteredinerror" and silently fails to match. final, amended and
            // corrected happen to round-trip, which is exactly why this hid.
            var status = report.Status is { } reportStatus
                ? reportStatus.GetLiteral() ?? "unknown"
                : "unknown";

            if (!ReleasedStatuses.Contains(status))
            {
                // Not validated yet. Mark handled; an updated push resets the
                // processed flag and brings it back through here.
                log.LogDebug("DiagnosticReport/{Id} is {Status}; not a released result", report.Id, status);
                await store.MarkProcessedAsync("DiagnosticReport", report.Id!, ct);
                continue;
            }

            var tracked = await ResolveOrderAsync(store, report, ct);
            if (tracked is null)
            {
                var age = DateTimeOffset.UtcNow - receivedAt;
                if (age > TimeSpan.FromMinutes(options.CorrelationRetryMinutes))
                {
                    await store.DeadLetterAsync("fhir:DiagnosticReport",
                        $"Could not correlate DiagnosticReport/{report.Id} to a HIS order after {age.TotalMinutes:F0} min",
                        BridgeStore.ToJson(report), null, ct);
                    await store.MarkProcessedAsync("DiagnosticReport", report.Id!, ct);

                    await publisher.PublishAsync(options.TopicResultFailed, report.Id!, new
                    {
                        eventId = Guid.NewGuid().ToString(),
                        openelisResultRef = $"DiagnosticReport/{report.Id}",
                        status = "UNCORRELATED",
                        detail = "No HIS order matches this report's ServiceRequest chain"
                    }, Guid.NewGuid().ToString(), ct);
                }
                else
                {
                    log.LogInformation(
                        "DiagnosticReport/{Id} not correlated yet ({Age:F0}s old); waiting for its ServiceRequest chain",
                        report.Id, age.TotalSeconds);
                }
                continue;
            }

            await ForwardAsync(store, report, tracked, status, ct);
        }
    }

    /// <summary>
    /// Walks DiagnosticReport -> ServiceRequest -> ServiceRequest back to the
    /// order the bridge published, with progressively looser fallbacks.
    /// </summary>
    private async Task<TrackedOrder?> ResolveOrderAsync(
        BridgeStore store, DiagnosticReport report, CancellationToken ct)
    {
        foreach (var srId in report.BasedOn.Select(IdOf).Where(x => x is not null))
        {
            // 1. The report points straight at a ServiceRequest we published.
            if (await store.GetTrackedByServiceRequestAsync(srId!, ct) is { } direct)
                return direct;

            var analysisSr = await store.GetReceivedAsync<ServiceRequest>("ServiceRequest", srId!, ct);
            if (analysisSr is null) continue;

            // 2. OpenELIS's per-analysis ServiceRequest points back at ours.
            foreach (var parentId in analysisSr.BasedOn.Select(IdOf).Where(x => x is not null))
            {
                if (await store.GetTrackedByServiceRequestAsync(parentId!, ct) is { } viaParent)
                    return viaParent;

                var parentSr = await store.GetReceivedAsync<ServiceRequest>("ServiceRequest", parentId!, ct);
                if (parentSr is not null &&
                    await MatchByOrderNumberAsync(store, parentSr, ct) is { } viaParentIdentifier)
                    return viaParentIdentifier;
            }

            // 3. The order number travelled on the ServiceRequest identifier.
            if (await MatchByOrderNumberAsync(store, analysisSr, ct) is { } viaIdentifier)
                return viaIdentifier;
        }

        return null;
    }

    private static async Task<TrackedOrder?> MatchByOrderNumberAsync(
        BridgeStore store, ServiceRequest sr, CancellationToken ct)
    {
        foreach (var identifier in sr.Identifier.Where(i => !string.IsNullOrWhiteSpace(i.Value)))
        {
            if (await store.GetTrackedByOrderNumberAsync(identifier.Value, ct) is { } match)
                return match;
        }
        return null;
    }

    private async Task ForwardAsync(
        BridgeStore store, DiagnosticReport report, TrackedOrder tracked, string status, CancellationToken ct)
    {
        var resultRef = $"DiagnosticReport/{report.Id}";

        // OpenELIS increments meta.versionId when it corrects a result, so the
        // version is part of the identity of what we are forwarding. Absent a
        // version we fall back to "1", which reproduces the old
        // one-forward-per-report behaviour rather than forwarding endlessly.
        var versionId = report.Meta?.VersionId ?? "1";

        if (!await store.TryClaimResultAsync(resultRef, versionId, tracked.OrderId, ct))
        {
            log.LogInformation("{Ref} version {Version} already forwarded for order {OrderNumber}; skipping",
                resultRef, versionId, tracked.OrderNumber);
            await store.MarkProcessedAsync("DiagnosticReport", report.Id!, ct);
            return;
        }

        var retracted = status == RetractedStatus;
        var observation = await FirstObservationAsync(store, report, ct);
        var (value, unit, range, interpretation) = retracted
            // Forwarding the old number alongside a retracted status invites a
            // reader to keep using it. The retraction is the whole message.
            ? ((string?)null, (string?)null, (string?)null, (string?)null)
            : Flatten(observation, report);

        var correlationId = tracked.CorrelationId ?? Guid.NewGuid().ToString();
        var message = new
        {
            eventId = Guid.NewGuid().ToString(),
            eventType = "lab.result.released",
            occurredAt = DateTimeOffset.UtcNow,
            correlationId,
            orderNumber = tracked.OrderNumber,
            // The mandatory back-reference: the HIS copy always points at the
            // OpenELIS record that remains the source of truth.
            openelisResultRef = resultRef,
            testCode = tracked.TestCode,
            testName = report.Code?.Text ?? report.Code?.Coding.FirstOrDefault()?.Display,
            resultValue = value,
            resultUnit = unit,
            referenceRange = range,
            interpretation,
            resultStatus = status,
            releasedAt = ReleasedAt(report)
        };

        await publisher.PublishAsync(options.TopicResultReleased, tracked.OrderNumber, message, correlationId, ct);
        await store.MarkProcessedAsync("DiagnosticReport", report.Id!, ct);

        log.LogInformation("Forwarded released result {Ref} for order {OrderNumber}: {Value} {Unit}",
            resultRef, tracked.OrderNumber, value, unit);
    }

    private static async Task<Observation?> FirstObservationAsync(
        BridgeStore store, DiagnosticReport report, CancellationToken ct)
    {
        foreach (var id in report.Result.Select(IdOf).Where(x => x is not null))
        {
            var observation = await store.GetReceivedAsync<Observation>("Observation", id!, ct);
            if (observation is not null) return observation;
        }
        return null;
    }

    /// <summary>Collapses the FHIR result into the flat fields the HIS stores.</summary>
    private static (string? Value, string? Unit, string? Range, string? Interpretation) Flatten(
        Observation? observation, DiagnosticReport report)
    {
        if (observation is null)
            return (report.Conclusion, null, null, null);

        string? value;
        string? unit = null;

        switch (observation.Value)
        {
            case Quantity q:
                value = q.Value?.ToString();
                unit = q.Unit ?? q.Code;
                break;
            case FhirString s:
                value = s.Value;
                break;
            case CodeableConcept c:
                value = c.Text ?? c.Coding.FirstOrDefault()?.Display;
                break;
            case Integer i:
                value = i.Value?.ToString();
                break;
            case FhirBoolean b:
                value = b.Value?.ToString();
                break;
            case null:
                // Some OpenELIS analyses report only a narrative conclusion.
                value = report.Conclusion;
                break;
            default:
                value = observation.Value.ToString();
                break;
        }

        var interpretation = observation.Interpretation
            .SelectMany(i => i.Coding)
            .Select(c => c.Display ?? c.Code)
            .FirstOrDefault(x => !string.IsNullOrWhiteSpace(x))
            ?? observation.Interpretation.Select(i => i.Text).FirstOrDefault();

        var referenceRange = observation.ReferenceRange
            .Select(r => r.Text ?? FormatRange(r))
            .FirstOrDefault(x => !string.IsNullOrWhiteSpace(x));

        return (value, unit, referenceRange, interpretation);
    }

    private static string? FormatRange(Observation.ReferenceRangeComponent r) =>
        r.Low?.Value is null && r.High?.Value is null
            ? null
            : $"{r.Low?.Value?.ToString() ?? ""}-{r.High?.Value?.ToString() ?? ""}".Trim('-');

    private static DateTimeOffset ReleasedAt(DiagnosticReport report)
    {
        if (report.Issued is { } issued) return issued;
        if (report.Effective is FhirDateTime dt &&
            DateTimeOffset.TryParse(dt.Value, out var parsed)) return parsed;
        return DateTimeOffset.UtcNow;
    }

    private static string? IdOf(ResourceReference reference)
    {
        var value = reference?.Reference;
        if (string.IsNullOrWhiteSpace(value)) return null;
        var segments = value.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return segments.Length == 0 ? null : segments[^1];
    }
}
