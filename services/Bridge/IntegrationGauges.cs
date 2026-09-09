using Dapper;
using Npgsql;
using Prometheus;
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// The four numbers that say whether the integration is actually working.
///
/// WHY THESE FOUR, AND WHY THEY DID NOT EXIST BEFORE
/// The bridge already exposed request counts and durations, which answer "is the
/// process up and serving". Every failure mode that actually costs a patient
/// their result is INVISIBLE in those:
///
///   an order published and never polled     — no request fails, none is made
///   OpenELIS stopping its poll entirely     — the busiest endpoint simply goes quiet
///   a catalogue sync failing months ago     — yesterday's menu still serves fine
///   dead letters accumulating               — each one was handled correctly
///
/// All four look exactly like a healthy idle system, which is why they need a
/// gauge rather than an error rate. A quiet laboratory and a broken integration
/// produce identical graphs until something measures the AGE of things.
///
/// WHY A TIMER RATHER THAN A SCRAPE CALLBACK
/// Prometheus scrapes /metrics, and a callback would run these four queries on
/// whatever schedule the scraper chose — including several times a second if
/// someone pointed two scrapers at it. Refreshing on our own timer bounds the
/// database cost at four cheap queries every thirty seconds regardless of who is
/// watching, and a gauge thirty seconds stale is indistinguishable from a fresh
/// one at the thresholds these alerts use (minutes to days).
/// </summary>
public sealed class IntegrationGauges(
    NpgsqlDataSource dataSource,
    ILogger<IntegrationGauges> log) : BackgroundService
{
    /// <summary>
    /// How long the oldest undelivered order has been waiting.
    ///
    /// Zero when nothing is waiting, which is the normal state. This is the
    /// closest thing the system has to "is anything stuck", and it is deliberately
    /// an age rather than a count: one order stuck for a day matters more than
    /// fifty published in the last minute, and a count cannot tell them apart.
    /// </summary>
    private static readonly Gauge OldestRequested = Metrics.CreateGauge(
        "bridge_oldest_requested_task_age_seconds",
        "Age of the oldest Task still awaiting collection by the laboratory. 0 when none.");

    /// <summary>
    /// Failures nobody has dealt with. A counter would reset when the bridge
    /// restarts; the point of this one is that it does not.
    /// </summary>
    private static readonly Gauge DeadLetters = Metrics.CreateGauge(
        "bridge_dead_letters_total",
        "Rows in bridge.dead_letters — failures that need a human.");

    /// <summary>
    /// How old the test menu is.
    ///
    /// A failed sync leaves the previous menu in place and serving, so the
    /// laboratory can withdraw a test and keep receiving orders for it with
    /// nothing failing anywhere. Only the AGE of the last successful sync says so.
    /// </summary>
    private static readonly Gauge CatalogueAge = Metrics.CreateGauge(
        "bridge_catalogue_age_seconds",
        "Time since the test menu was last synced from OpenELIS.");

    /// <summary>
    /// Time since OpenELIS last asked for orders.
    ///
    /// The one gauge here that is not backed by a table: nothing records a poll,
    /// because a poll that returns nothing writes nothing. Stamped in memory by
    /// the search handler instead — which is why it reads as "never polled since
    /// this process started" after a restart rather than as an outage, and why
    /// the alert on it has to tolerate that.
    /// </summary>
    private static readonly Gauge LastPollAge = Metrics.CreateGauge(
        "bridge_last_poll_age_seconds",
        "Time since OpenELIS last polled for orders. -1 until the first poll of this process.");

    /// <summary>
    /// When the order poll last arrived. Static because the handler that stamps
    /// it is a minimal-API delegate with no instance to reach.
    /// </summary>
    private static DateTimeOffset? _lastPoll;

    /// <summary>Called by the Task search handler on a real poll — see FhirEndpoints.</summary>
    public static void RecordPoll() => _lastPoll = DateTimeOffset.UtcNow;

    /// <summary>
    /// Nothing is published until a refresh has actually succeeded.
    ///
    /// THE MISTAKE THIS EXISTS TO PREVENT, WHICH WAS MADE HERE FIRST
    /// prometheus-net registers a gauge at zero. The first version of this class
    /// had a query Dapper could not materialise, so every refresh threw, and the
    /// four gauges sat at 0 — which reads as "nothing is stuck, no dead letters,
    /// catalogue fresh". The most alarming possible state published the most
    /// reassuring possible numbers, and every alert in alerts.yml was quietly
    /// satisfied by a component that had never once queried the database.
    ///
    /// An ABSENT metric cannot do that. It breaks the alert expression instead of
    /// answering it falsely, and `up`/`absent()` catch it. A monitoring component
    /// that fails silently is worse than no monitoring, because it also removes
    /// the suspicion that would have made someone look.
    /// </summary>
    private bool _published;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        // Unpublished until proven otherwise — see above. Registration alone must
        // not put a reassuring zero on the scrape.
        OldestRequested.Unpublish();
        DeadLetters.Unpublish();
        CatalogueAge.Unpublish();
        LastPollAge.Unpublish();

        // Behind the database wait in Program.cs.
        await Task.Delay(TimeSpan.FromSeconds(20), ct);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await RefreshAsync(ct);

                if (!_published)
                {
                    OldestRequested.Publish();
                    DeadLetters.Publish();
                    CatalogueAge.Publish();
                    LastPollAge.Publish();
                    _published = true;
                    log.LogInformation("Integration gauges are live");
                }
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                // Already-published gauges keep their previous values rather than
                // being zeroed: a failed refresh is not evidence that nothing is
                // stuck, and zeroing would resolve a firing alert on no
                // information at all. Gauges that have NEVER refreshed stay
                // absent, which is the honest answer to "we do not know".
                log.LogWarning("Could not refresh the integration gauges: {Message}", ex.Message);
            }

            await Task.Delay(TimeSpan.FromSeconds(30), ct);
        }
    }

    private async Task RefreshAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);

        // One round trip for the three table-backed gauges. They are read
        // together and alerted on together; three separate connections would be
        // three chances for a partial refresh to publish an inconsistent set.
        // ::double precision on both ages, deliberately.
        //
        // extract(epoch …) returns NUMERIC, which Dapper materialises as decimal
        // and refuses to bind to a double parameter — the error is a
        // materialisation failure, not a conversion warning, so the whole refresh
        // throws. A gauge is a float64 by definition; casting here matches the
        // wire format rather than converting after the fact.
        var row = await conn.QuerySingleAsync<GaugeRow>(new CommandDefinition("""
            SELECT
                coalesce(extract(epoch FROM now() - (
                    SELECT min(r.last_updated)
                      FROM bridge.fhir_resources r
                      LEFT JOIN bridge.order_tracking t ON t.fhir_task_id = r.resource_id
                     WHERE r.resource_type = 'Task'
                       AND r.content ->> 'status' = 'requested'
                       -- A result came back, so the order manifestly WAS
                       -- delivered, whatever the Task status still says. The
                       -- acknowledgement is the thing that went missing, and a
                       -- missing acknowledgement is not a waiting patient.
                       --
                       -- Without this the gauge measures "un-acknowledged", which
                       -- is not what the alert claims and not what anyone would
                       -- get out of bed for: it fires for ever on any order whose
                       -- accept-write was lost, long after its result reached the
                       -- ward.
                       AND NOT EXISTS (
                           SELECT 1 FROM bridge.forwarded_results f
                            WHERE f.order_id = t.order_id))), 0)
                    ::double precision AS oldest_requested_seconds,
                (SELECT count(*) FROM bridge.dead_letters) AS dead_letters,
                coalesce(extract(epoch FROM now() - (
                    SELECT max(synced_at) FROM bridge.test_catalogue)), -1)
                    ::double precision AS catalogue_age_seconds;
            """, cancellationToken: ct));

        OldestRequested.Set(row.OldestRequestedSeconds);
        DeadLetters.Set(row.DeadLetters);

        // -1, not 0, for a catalogue that has never synced. Zero would mean
        // "synced just now" — the healthiest possible reading for the least
        // healthy possible state.
        CatalogueAge.Set(row.CatalogueAgeSeconds);

        LastPollAge.Set(_lastPoll is { } polled
            ? (DateTimeOffset.UtcNow - polled).TotalSeconds
            : -1);
    }

    private sealed record GaugeRow(
        double OldestRequestedSeconds, long DeadLetters, double CatalogueAgeSeconds);
}
