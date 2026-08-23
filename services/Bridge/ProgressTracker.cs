using Hl7.Fhir.Model;
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// Tells the HIS where an order has got to inside the laboratory.
///
/// WHY THIS EXISTS
/// Until now an order went ACCEPTED_BY_LIS and then, some hours later,
/// RESULT_AVAILABLE. Everything in between was silence, and silence is
/// indistinguishable from "lost". The commonest question a ward asks a
/// laboratory - "where is my test?" - had no answer in the ordering system, so
/// it was asked by telephone.
///
/// WHAT IT IS BUILT FROM
/// Nothing new is fetched. OpenELIS already pushes ServiceRequest, Specimen and
/// Task alongside the results, and the bridge already stores them; it simply
/// read only the DiagnosticReports and ignored the rest. This turns what was
/// already arriving into progress.
///
/// That matters for a reason beyond effort: it means progress needs no
/// credential, no polling loop against OpenELIS, and no second integration to
/// keep working. It travels on the mutually authenticated channel that already
/// exists.
///
/// WHAT IT DELIBERATELY DOES NOT DO
/// A preliminary DiagnosticReport carries a value the laboratory has NOT
/// validated. This publishes the fact that such a report exists, and never the
/// number in it. A clinician learning that a result is ready is useful; a
/// clinician acting on an unvalidated potassium is a patient safety incident.
/// </summary>
public sealed class ProgressTracker(
    IServiceScopeFactory scopes,
    BridgeOptions options,
    EventPublisher publisher,
    ILogger<ProgressTracker> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        // Behind the result correlator's own first pass: both walk the same
        // received resources, and the correlator's work is the one a patient is
        // waiting on.
        await Task.Delay(TimeSpan.FromSeconds(20), ct);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await SweepAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                log.LogError(ex, "Progress sweep failed");
            }

            await Task.Delay(TimeSpan.FromSeconds(15), ct);
        }
    }

    private async Task SweepAsync(CancellationToken ct)
    {
        using var scope = scopes.CreateScope();
        var store = scope.ServiceProvider.GetRequiredService<BridgeStore>();

        foreach (var (request, _) in await store.GetUnprocessedAsync<ServiceRequest>("ServiceRequest", ct))
        {
            var tracked = await ResolveAsync(store, request, ct);

            if (tracked is null)
            {
                // Not ours, or its chain has not arrived yet. Left unprocessed
                // so the next sweep tries again — the same patience the result
                // correlator needs, and for the same reason: OpenELIS pushes
                // the pieces of one order in several bundles.
                continue;
            }

            var accession = AccessionOf(request);
            var progress = ProgressOf(request, accession);

            if (progress is not null)
                await PublishAsync(store, tracked, progress, accession, ct);

            await store.MarkProcessedAsync("ServiceRequest", request.Id, ct);
        }
    }

    /// <summary>The system OpenELIS stamps on ITS accession number.</summary>
    private const string AccessionSystem = "http://openelis-global.org/samp_labNo";

    /// <summary>
    /// The laboratory's own accession number — what a human quotes on the
    /// telephone, and the only identifier the two systems share that a
    /// laboratory technician recognises.
    ///
    /// The SYSTEM is what makes this trustworthy, and checking only for a value
    /// was the first mistake here. OpenELIS echoes our own ServiceRequest back
    /// with `requisition` set to the HIS order number under our own system, so
    /// a bare presence check reported every order as "in the laboratory" the
    /// moment it was imported — and then quoted the order number back as if it
    /// were an accession. 102 of 130 requests were echoes; one was real.
    /// </summary>
    private static string? AccessionOf(ServiceRequest request) =>
        request.Requisition?.System == AccessionSystem ? request.Requisition.Value : null;

    /// <summary>
    /// Maps what OpenELIS says about a ServiceRequest onto something a
    /// clinician can act on.
    ///
    /// Coarse on purpose. OpenELIS distinguishes twenty-one sample and analysis
    /// states, most of which are internal to a laboratory's workflow; a ward
    /// needs to know whether the sample arrived, whether testing is happening,
    /// and whether a result is ready. Publishing the finer states would put a
    /// vocabulary in the HIS that only means something to the laboratory.
    /// </summary>
    private static string? ProgressOf(ServiceRequest request, string? accession) => request.Status switch
    {
        // Accessioned: the sample is physically in the laboratory and has been
        // given a number. Without an accession this is only our own request
        // echoed back, which says nothing new.
        RequestStatus.Active when accession is not null => "IN_LABORATORY",

        // The result path already reports this through lab.result.released, and
        // reporting it twice invites the two to disagree.
        RequestStatus.Completed => null,

        _ => null
    };

    /// <summary>
    /// Walks the ServiceRequest back to the order the bridge published.
    ///
    /// The same shape as the result correlator's walk, and needed for the same
    /// reason: what OpenELIS pushes back is ITS resource, not ours. Its
    /// per-analysis ServiceRequest points at the one we published.
    /// </summary>
    private static async Task<TrackedOrder?> ResolveAsync(
        BridgeStore store, ServiceRequest request, CancellationToken ct)
    {
        if (request.Id is not null &&
            await store.GetTrackedByServiceRequestAsync(request.Id, ct) is { } direct)
            return direct;

        foreach (var parentId in request.BasedOn.Select(r => r.Reference?.Split('/').LastOrDefault())
                                                .Where(x => !string.IsNullOrWhiteSpace(x)))
        {
            if (await store.GetTrackedByServiceRequestAsync(parentId!, ct) is { } viaParent)
                return viaParent;
        }

        foreach (var identifier in request.Identifier.Where(i => !string.IsNullOrWhiteSpace(i.Value)))
        {
            if (await store.GetTrackedByOrderNumberAsync(identifier.Value, ct) is { } viaIdentifier)
                return viaIdentifier;
        }

        return null;
    }

    /// <summary>
    /// Publishes once per order and state.
    ///
    /// OpenELIS re-pushes the same resource whenever anything about the sample
    /// changes, so without this the HIS would receive "in the laboratory" a
    /// dozen times for one order — and each would be an audit row and a
    /// notification.
    /// </summary>
    private async Task PublishAsync(
        BridgeStore store, TrackedOrder tracked, string progress, string? accession, CancellationToken ct)
    {
        var key = $"progress:{tracked.OrderNumber}:{progress}";
        if (!await store.TryClaimEventAsync(key, "lab.order.progress", ct))
            return;

        try
        {
            await publisher.PublishAsync(options.TopicOrderProgress, tracked.OrderNumber, new
            {
                eventId = key,
                eventType = "lab.order.progress",
                orderNumber = tracked.OrderNumber,
                progress,
                accessionNumber = accession,
                occurredAt = DateTimeOffset.UtcNow
            }, tracked.CorrelationId ?? key, ct);

            log.LogInformation("Order {OrderNumber} is {Progress} (accession {Accession})",
                tracked.OrderNumber, progress, accession ?? "none");
        }
        catch
        {
            // Release the claim so the next sweep retries. Keeping it would
            // mean one failed publish silently costs that order its progress
            // for ever.
            await store.ReleaseEventClaimAsync(key, ct);
            throw;
        }
    }
}
