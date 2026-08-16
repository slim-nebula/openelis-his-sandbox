using Dapper;
using Npgsql;

namespace His.Api;

/// <summary>
/// Drains his.outbox to Kafka.
///
/// The relay is what makes the outbox pattern work: order creation commits the
/// event to the database and returns, and this loop is solely responsible for
/// getting it onto the broker. Consequences worth being explicit about:
///
///   * An order is never lost. If the broker is down the row simply stays
///     unpublished and is retried until it lands.
///   * Delivery is at-least-once, not exactly-once. A crash between the publish
///     and the row being marked published re-sends on restart, so consumers
///     must be idempotent — the bridge claims events by id, and the HIS upserts
///     results on the OpenELIS reference.
///   * Per-order ordering is preserved. Rows go out in outbox_id order and the
///     batch stops at the first failure, so a later event for the same order can
///     never overtake an earlier one.
/// </summary>
public sealed class OutboxRelay(
    NpgsqlDataSource dataSource,
    EventPublisher publisher,
    ILogger<OutboxRelay> log) : BackgroundService
{
    private const int BatchSize = 50;
    private static readonly TimeSpan Idle = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan BackOff = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan PruneEvery = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan KeepPublishedFor = TimeSpan.FromDays(7);

    private DateTimeOffset _nextPrune = DateTimeOffset.UtcNow.Add(PruneEvery);

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        log.LogInformation("Outbox relay started");

        while (!ct.IsCancellationRequested)
        {
            var delay = Idle;
            try
            {
                var (published, stalled) = await DrainAsync(ct);
                if (stalled) delay = BackOff;
                else if (published > 0) delay = TimeSpan.Zero;   // more may be waiting

                if (DateTimeOffset.UtcNow >= _nextPrune)
                {
                    await PruneAsync(ct);
                    _nextPrune = DateTimeOffset.UtcNow.Add(PruneEvery);
                }
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                log.LogError(ex, "Outbox relay iteration failed");
                delay = BackOff;
            }

            if (delay > TimeSpan.Zero) await Task.Delay(delay, ct);
        }
    }

    private async Task<(int Published, bool Stalled)> DrainAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        // SKIP LOCKED so a second instance would take different rows rather
        // than block. Rows stay locked until commit, which is what stops two
        // relays publishing the same event.
        var batch = (await conn.QueryAsync<OutboxRow>(new CommandDefinition("""
            SELECT outbox_id, topic, partition_key, payload::text AS payload, correlation_id
            FROM his.outbox
            WHERE published_at IS NULL
            ORDER BY outbox_id
            LIMIT @BatchSize
            FOR UPDATE SKIP LOCKED;
            """, new { BatchSize }, tx, cancellationToken: ct))).ToList();

        if (batch.Count == 0)
        {
            await tx.RollbackAsync(ct);
            return (0, false);
        }

        var published = 0;
        var stalled = false;

        foreach (var row in batch)
        {
            try
            {
                await publisher.PublishRawAsync(
                    row.Topic, row.PartitionKey, row.Payload,
                    row.CorrelationId ?? Guid.NewGuid().ToString(), ct);

                await conn.ExecuteAsync(new CommandDefinition(
                    "UPDATE his.outbox SET published_at = now() WHERE outbox_id = @id;",
                    new { id = row.OutboxId }, tx, cancellationToken: ct));
                published++;
            }
            catch (Exception ex)
            {
                await conn.ExecuteAsync(new CommandDefinition("""
                    UPDATE his.outbox
                       SET attempts = attempts + 1, last_error = @error
                     WHERE outbox_id = @id;
                    """, new { id = row.OutboxId, error = ex.Message }, tx, cancellationToken: ct));

                log.LogWarning("Outbox row {OutboxId} could not be published ({Message}); will retry",
                    row.OutboxId, ex.Message);

                // Stop here rather than skipping ahead: publishing a later event
                // for the same order before this one would reorder the stream.
                stalled = true;
                break;
            }
        }

        await tx.CommitAsync(ct);

        if (published > 0)
            log.LogInformation("Outbox relay published {Count} event(s)", published);

        return (published, stalled);
    }

    private async Task PruneAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var removed = await conn.ExecuteAsync(new CommandDefinition("""
            DELETE FROM his.outbox
            WHERE published_at IS NOT NULL AND published_at < @cutoff;
            """, new { cutoff = DateTimeOffset.UtcNow - KeepPublishedFor }, cancellationToken: ct));

        if (removed > 0)
            log.LogInformation("Pruned {Count} published outbox row(s)", removed);
    }

    private sealed record OutboxRow(
        long OutboxId, string Topic, string PartitionKey, string Payload, string? CorrelationId);
}
