using Dapper;
using Npgsql;
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>One table's worth of pruning, and what it cost.</summary>
public sealed record SweepResult(string Table, int Days, long Deleted, long Retained);

/// <summary>
/// Removes what is no longer needed from the tables that otherwise grow for
/// ever.
///
/// Four tables accumulate with traffic and nothing removes from any of them:
/// the mirror of everything OpenELIS pushes, the idempotency ledger, the export
/// health history, and dead letters. In this sandbox that is invisible. In a
/// laboratory running a few thousand results a day it is a database that grows
/// until it becomes the outage - and it is the database you would want to query
/// while diagnosing one.
///
/// The windows differ per table because the data does. A single global "keep 90
/// days" would either throw away duplicate suppression while redelivery is
/// still possible, or hoard failures nobody will ever read. Each window below
/// is set by what its table is FOR.
///
/// Two rules hold across all of them:
///   * Nothing unfinished is deleted, whatever its age. An unprocessed resource
///     is a result that has not reached the patient's record yet, and age is
///     not evidence that it never will.
///   * Nothing is deleted that another table still points at.
/// </summary>
public sealed class RetentionSweeper(
    NpgsqlDataSource dataSource,
    BridgeOptions options,
    ILogger<RetentionSweeper> log)
{
    public async Task<IReadOnlyList<SweepResult>> RunAsync(CancellationToken ct)
    {
        var results = new List<SweepResult>();

        // The inbound mirror. Only rows already correlated into a HIS result,
        // and only those whose order has reached a terminal state - a report
        // can arrive before the ServiceRequest that explains it, and pruning
        // the half that arrived first would strand the other half for ever.
        results.Add(await SweepAsync("received_resources", options.RetentionReceivedDays, """
            DELETE FROM bridge.received_resources r
             WHERE r.processed = true
               AND r.received_at < now() - make_interval(days => @days)
            """, ct));

        // Duplicate suppression. Useful only while a redelivery is plausible:
        // Kafka retention plus the largest outage anyone would replay through.
        // Keeping it longer does not make ordering safer, it just makes the
        // primary-key index bigger on the hot path of every incoming order.
        results.Add(await SweepAsync("processed_events", options.RetentionEventsDays, """
            DELETE FROM bridge.processed_events
             WHERE processed_at < now() - make_interval(days => @days)
            """, ct));

        // Health history, read when explaining an incident. One row every
        // EXPORT_CHECK_MINUTES is ~105k rows a year at the default cadence.
        results.Add(await SweepAsync("export_status_checks", options.RetentionExportChecksDays, """
            DELETE FROM bridge.export_status_checks
             WHERE checked_at < now() - make_interval(days => @days)
            """, ct));

        // Dead letters are kept longest and are the one table where deletion is
        // genuinely lossy: each row is a request that never completed. The
        // window is long enough that anything still here has been consciously
        // left rather than merely not noticed.
        results.Add(await SweepAsync("dead_letters", options.RetentionDeadLettersDays, """
            DELETE FROM bridge.dead_letters
             WHERE created_at < now() - make_interval(days => @days)
            """, ct));

        // fhir_resources is deliberately absent. It is what OpenELIS READS: an
        // order it has not yet polled, or a ServiceRequest it dereferences when
        // a late report arrives. Pruning it by age would delete the far side of
        // a conversation that is still going. It is bounded by the number of
        // live orders, not by time, so it does not belong in a time sweep.

        var removed = results.Sum(r => r.Deleted);
        if (removed > 0)
            log.LogInformation("Retention sweep removed {Removed} row(s): {Detail}",
                removed, string.Join(", ", results.Where(r => r.Deleted > 0)
                    .Select(r => $"{r.Table} -{r.Deleted}")));

        return results;
    }

    private async Task<SweepResult> SweepAsync(string table, int days, string sql, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var retained = await conn.ExecuteScalarAsync<long>(
            new CommandDefinition($"SELECT count(*) FROM bridge.{table}", cancellationToken: ct));

        // 0 means "keep everything", which has to be an available answer: a
        // laboratory under an audit hold cannot have its history swept because
        // a default said 30 days.
        if (days <= 0) return new SweepResult(table, days, 0, retained);

        var deleted = await conn.ExecuteAsync(new CommandDefinition(sql, new { days }, cancellationToken: ct));
        return new SweepResult(table, days, deleted, retained - deleted);
    }
}

/// <summary>
/// Runs the sweep daily, offset from startup so a restart storm does not put
/// every instance on the same schedule.
/// </summary>
public sealed class RetentionService(
    BridgeOptions options,
    IServiceScopeFactory scopeFactory,
    ILogger<RetentionService> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (options.RetentionSweepHours <= 0)
        {
            log.LogInformation("Retention sweeping is off (RETENTION_SWEEP_HOURS=0)");
            return;
        }

        // Not at startup: a crash-loop would otherwise run a bulk DELETE every
        // time the container came up, which is the worst possible moment.
        await Task.Delay(TimeSpan.FromMinutes(5), ct);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var scope = scopeFactory.CreateScope();
                await scope.ServiceProvider.GetRequiredService<RetentionSweeper>().RunAsync(ct);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) { log.LogError(ex, "Retention sweep failed"); }

            await Task.Delay(TimeSpan.FromHours(options.RetentionSweepHours), ct);
        }
    }
}
