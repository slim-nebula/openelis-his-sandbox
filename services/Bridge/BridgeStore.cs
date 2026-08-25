using System.Text.Json;
using Dapper;
using Hl7.Fhir.Model;
using Hl7.Fhir.Serialization;
using Npgsql;
// Hl7.Fhir.Model defines its own Task resource, which collides with the
// implicitly imported System.Threading.Tasks.Task in every async signature.
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// The bridge's own database. It holds the FHIR resources the bridge publishes
/// for OpenELIS to poll, a mirror of what OpenELIS pushes back, and the
/// idempotency and dead-letter bookkeeping. Neither the HIS service nor
/// OpenELIS has credentials for it.
/// </summary>
public sealed class BridgeStore(
    NpgsqlDataSource dataSource, BridgeOptions options, ILogger<BridgeStore> log)
{
    private static readonly FhirJsonSerializer Serializer = new();
    private static readonly FhirJsonParser Parser = new(new ParserSettings
    {
        AcceptUnknownMembers = true,
        AllowUnrecognizedEnums = true,
        PermissiveParsing = true
    });

    // --- Published (outbound) resources ------------------------------------

    public async Task PutResourceAsync(Resource resource, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await PutResourceAsync(conn, null, resource, ct);
    }

    public static async Task PutResourceAsync(
        NpgsqlConnection conn, System.Data.Common.DbTransaction? tx, Resource resource, CancellationToken ct)
    {
        var json = Serializer.SerializeToString(resource);
        await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO bridge.fhir_resources (resource_type, resource_id, version_id, content, last_updated)
            VALUES (@type, @id, 1, @content::jsonb, now())
            ON CONFLICT (resource_type, resource_id) DO UPDATE SET
                version_id   = bridge.fhir_resources.version_id + 1,
                content      = excluded.content,
                last_updated = now();
            """, new { type = resource.TypeName, id = resource.Id, content = json }, tx, cancellationToken: ct));
    }

    public async Task<Resource?> GetResourceAsync(string type, string id, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var json = await conn.ExecuteScalarAsync<string?>(new CommandDefinition("""
            SELECT content::text FROM bridge.fhir_resources
            WHERE resource_type = @type AND resource_id = @id;
            """, new { type, id }, cancellationToken: ct));
        return json is null ? null : Parser.Parse<Resource>(json);
    }

    /// <summary>
    /// Backs GET /fhir/Task?status=requested&amp;owner=... — the query OpenELIS
    /// issues on every poll.
    ///
    /// Capped, and oldest first. Uncapped, one poll serialises every Task the
    /// bridge has ever published, so the cost of asking "anything new?" grows
    /// with the age of the deployment and is worst exactly when the laboratory
    /// is busiest.
    ///
    /// The cap needs no paging to be correct HERE, because of what the query
    /// is: OpenELIS searches status=requested, and accepting an order moves it
    /// out of that set. So a capped page drains itself over successive polls.
    /// Oldest first is what makes that a queue rather than a lottery - without
    /// the ordering, an order arriving during a backlog could be starved
    /// indefinitely while newer ones are served.
    /// </summary>
    public async Task<IReadOnlyList<Resource>> SearchTasksAsync(
        string? status, string? owner, string? id, int limit, CancellationToken ct)
    {
        // A lookup by id is a read, not a delivery, and must never be withheld:
        // GET /fhir/Task/{id} and ?_id= have to agree, or debugging this becomes
        // impossible. Only the poll — which never carries _id — takes a lease.
        if (id is not null)
        {
            await using var direct = await dataSource.OpenConnectionAsync(ct);
            var one = await direct.QueryAsync<string>(new CommandDefinition("""
                SELECT content::text FROM bridge.fhir_resources
                WHERE resource_type = 'Task'
                  AND (@status IS NULL OR content ->> 'status' = @status)
                  AND (@owner  IS NULL OR content -> 'owner' ->> 'reference' = @owner)
                  AND resource_id = @id
                ORDER BY last_updated
                LIMIT @limit;
                """, new { status, owner, id, limit }, cancellationToken: ct));
            return one.Select(Parser.Parse<Resource>).ToList();
        }

        return await SearchAndLeaseTasksAsync(status, owner, limit, ct);
    }

    /// <summary>
    /// The order poll: returns Tasks and claims them in one statement.
    ///
    /// The claim has to be atomic with the read, because the failure it exists
    /// to prevent IS two polls landing together (db/bridge/005_delivery_lease.sql).
    /// Two things make it so:
    ///
    ///   * the LEFT JOIN drops Tasks under a live lease, which handles the
    ///     ordinary case and keeps LIMIT counting only claimable rows;
    ///   * `ON CONFLICT ... DO UPDATE ... WHERE leased_until &lt;= now()` handles
    ///     the simultaneous case. It takes a row lock, so of two transactions
    ///     racing for the same Task the second finds the lease already moved
    ///     into the future, its WHERE fails, and it RETURNSs nothing. Only the
    ///     winner is handed the Task.
    ///
    /// A Task is therefore delivered to exactly one poll at a time, without its
    /// status being touched.
    /// </summary>
    private async Task<IReadOnlyList<Resource>> SearchAndLeaseTasksAsync(
        string? status, string? owner, int limit, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);

        var rows = await conn.QueryAsync<(string Content, int Deliveries)>(new CommandDefinition("""
            WITH candidates AS (
                SELECT r.resource_id
                  FROM bridge.fhir_resources r
                  LEFT JOIN bridge.delivery_leases l ON l.resource_id = r.resource_id
                 WHERE r.resource_type = 'Task'
                   AND (@status IS NULL OR r.content ->> 'status' = @status)
                   AND (@owner  IS NULL OR r.content -> 'owner' ->> 'reference' = @owner)
                   AND (l.leased_until IS NULL OR l.leased_until <= now())
                 ORDER BY r.last_updated
                 LIMIT @limit
            ),
            claimed AS (
                INSERT INTO bridge.delivery_leases AS l (resource_id, leased_until)
                SELECT resource_id, now() + make_interval(secs => @leaseSeconds) FROM candidates
                ON CONFLICT (resource_id) DO UPDATE
                   SET leased_until = excluded.leased_until,
                       deliveries   = l.deliveries + 1,
                       last_at      = now()
                 WHERE l.leased_until <= now()
                RETURNING resource_id, deliveries
            )
            SELECT r.content::text AS "Content", c.deliveries AS "Deliveries"
              FROM bridge.fhir_resources r
              JOIN claimed c ON c.resource_id = r.resource_id
             ORDER BY r.last_updated;
            """, new { status, owner, limit, leaseSeconds = (double)options.TaskLeaseSeconds },
            cancellationToken: ct));

        var delivered = rows.ToList();

        // Above one means the LIS was given this order and never came back with
        // a verdict. Nothing else counts that — OpenELIS keeps no attempt
        // counter for a failing import — so this is the only place a repeatedly
        // failing order announces itself.
        foreach (var (content, deliveries) in delivered.Where(r => r.Deliveries > 1))
        {
            log.LogWarning(
                "Task handed to the LIS for the {Ordinal} time — the previous delivery was never " +
                "acknowledged. Repeated growth here means the LIS cannot import it: {Task}",
                deliveries, Parser.Parse<Resource>(content).Id);
        }

        return delivered.Select(r => Parser.Parse<Resource>(r.Content)).ToList();
    }

    /// <summary>
    /// Records which HIS clinician a published Practitioner stands for.
    ///
    /// The id is still derived from the user id, so this is not what makes the
    /// mapping work — it is what stops the mapping DEPENDING on the id's
    /// content, which FHIR says is opaque and not ours to read. It also makes
    /// the reverse direction possible at all: a hash does not run backwards.
    ///
    /// Orders placed before the HIS recorded identity have no user id. Those are
    /// skipped rather than stored under a placeholder — a row claiming to
    /// identify a clinician it cannot is worse than no row.
    /// </summary>
    /// <summary>
    /// Ends the lease once the laboratory has given a verdict, WITHOUT erasing
    /// the delivery history.
    ///
    /// This used to DELETE the row, which quietly defeated the point of the
    /// table. `deliveries` is the attempt counter OpenELIS does not have — the
    /// only record of how many times an order had to be handed over before it
    /// stuck — and deleting on success threw that away for every order that
    /// worked, leaving the counter meaningful only for failures. It also meant a
    /// Task re-delivered later started counting from one again, so the number
    /// under-reported precisely when someone was investigating.
    ///
    /// Expiring instead releases the Task just as effectively — the claim query
    /// tests `leased_until <= now()` — and keeps first_at, last_at and the
    /// count. Retention sweeps the table; releasing is not the place to prune.
    /// </summary>
    public async Task ReleaseDeliveryLeaseAsync(string resourceId, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await conn.ExecuteAsync(new CommandDefinition("""
            UPDATE bridge.delivery_leases
               SET leased_until = now() - interval '1 second'
             WHERE resource_id = @resourceId;
            """, new { resourceId }, cancellationToken: ct));
    }

    /// <summary>Total matching the same predicate, so a bundle can report a truthful total when it is truncated.</summary>
    public async Task<int> CountTasksAsync(string? status, string? owner, string? id, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        return await conn.ExecuteScalarAsync<int>(new CommandDefinition("""
            SELECT count(*) FROM bridge.fhir_resources
            WHERE resource_type = 'Task'
              AND (@status IS NULL OR content ->> 'status' = @status)
              AND (@owner  IS NULL OR content -> 'owner' ->> 'reference' = @owner)
              AND (@id     IS NULL OR resource_id = @id);
            """, new { status, owner, id }, cancellationToken: ct));
    }

    public async Task<IReadOnlyList<Resource>> SearchByTypeAsync(string type, int limit, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<string>(new CommandDefinition("""
            SELECT content::text FROM bridge.fhir_resources
            WHERE resource_type = @type ORDER BY last_updated LIMIT @limit;
            """, new { type, limit }, cancellationToken: ct));
        return rows.Select(Parser.Parse<Resource>).ToList();
    }

    // --- Order tracking -----------------------------------------------------

    public async Task SaveOrderAsync(
        TrackedOrder tracked, IReadOnlyList<Resource> resources, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        foreach (var resource in resources)
            await PutResourceAsync(conn, tx, resource, ct);

        await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO bridge.order_tracking
                (order_id, order_number, patient_id, test_code, loinc_code, fhir_task_id,
                 fhir_servicerequest_id, fhir_patient_id, fhir_specimen_id, task_status,
                 attempts, correlation_id)
            VALUES (@OrderId, @OrderNumber, @PatientId, @TestCode, @LoincCode, @FhirTaskId,
                    @FhirServicerequestId, @FhirPatientId, @FhirSpecimenId, @TaskStatus,
                    @Attempts, @CorrelationId)
            ON CONFLICT (order_id) DO UPDATE SET
                task_status = excluded.task_status,
                attempts    = bridge.order_tracking.attempts + 1,
                updated_at  = now();
            """, tracked, tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
    }

    public async Task<TrackedOrder?> GetTrackedByTaskAsync(string taskId, CancellationToken ct) =>
        await QueryTrackedAsync("fhir_task_id = @v", taskId, ct);

    public async Task<TrackedOrder?> GetTrackedByServiceRequestAsync(string srId, CancellationToken ct) =>
        await QueryTrackedAsync("fhir_servicerequest_id = @v", srId, ct);

    public async Task<TrackedOrder?> GetTrackedByOrderNumberAsync(string orderNumber, CancellationToken ct) =>
        await QueryTrackedAsync("order_number = @v", orderNumber, ct);

    private async Task<TrackedOrder?> QueryTrackedAsync(string predicate, string value, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        return await conn.QuerySingleOrDefaultAsync<TrackedOrder>(new CommandDefinition($"""
            SELECT order_id, order_number, patient_id, test_code, loinc_code, fhir_task_id,
                   fhir_servicerequest_id, fhir_patient_id, fhir_specimen_id, task_status,
                   attempts, correlation_id
            FROM bridge.order_tracking WHERE {predicate};
            """, new { v = value }, cancellationToken: ct));
    }

    public async Task SetTaskStatusAsync(string taskId, string status, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await conn.ExecuteAsync(new CommandDefinition("""
            UPDATE bridge.order_tracking SET task_status = @status, updated_at = now()
            WHERE fhir_task_id = @taskId;
            """, new { taskId, status }, cancellationToken: ct));
    }

    public async Task RecordFailureAsync(Guid orderId, string error, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await conn.ExecuteAsync(new CommandDefinition("""
            UPDATE bridge.order_tracking
               SET attempts = attempts + 1, last_error = @error, updated_at = now()
             WHERE order_id = @orderId;
            """, new { orderId, error }, cancellationToken: ct));
    }

    // --- Inbound mirror -----------------------------------------------------

    public async Task StoreReceivedAsync(Resource resource, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var json = Serializer.SerializeToString(resource);
        await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO bridge.received_resources (resource_type, resource_id, content, processed)
            VALUES (@type, @id, @content::jsonb, false)
            ON CONFLICT (resource_type, resource_id) DO UPDATE SET
                content     = excluded.content,
                received_at = now(),
                processed   = false;
            """, new { type = resource.TypeName, id = resource.Id, content = json },
            cancellationToken: ct));
    }

    public async Task<IReadOnlyList<(T Resource, DateTimeOffset ReceivedAt)>> GetUnprocessedAsync<T>(
        string type, CancellationToken ct) where T : Resource
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<MirrorRow>(new CommandDefinition("""
            SELECT content::text AS content, received_at
            FROM bridge.received_resources
            WHERE resource_type = @type AND processed = false
            ORDER BY received_at;
            """, new { type }, cancellationToken: ct));

        var parsed = new List<(T, DateTimeOffset)>();
        foreach (var row in rows)
        {
            try { parsed.Add(((T)Parser.Parse<Resource>(row.Content), row.ReceivedAt)); }
            catch (Exception ex) { log.LogWarning(ex, "Skipping unparseable {Type} in mirror", type); }
        }
        return parsed;
    }

    public async Task<T?> GetReceivedAsync<T>(string type, string id, CancellationToken ct) where T : Resource
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var json = await conn.ExecuteScalarAsync<string?>(new CommandDefinition("""
            SELECT content::text FROM bridge.received_resources
            WHERE resource_type = @type AND resource_id = @id;
            """, new { type, id }, cancellationToken: ct));
        return json is null ? null : (T)Parser.Parse<Resource>(json);
    }

    public async Task MarkProcessedAsync(string type, string id, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await conn.ExecuteAsync(new CommandDefinition("""
            UPDATE bridge.received_resources SET processed = true
            WHERE resource_type = @type AND resource_id = @id;
            """, new { type, id }, cancellationToken: ct));
    }

    // --- Idempotency and dead letters --------------------------------------

    /// <summary>Returns false when this event key has already been handled.</summary>
    public async Task<bool> TryClaimEventAsync(string eventKey, string eventType, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var inserted = await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO bridge.processed_events (event_key, event_type)
            VALUES (@eventKey, @eventType)
            ON CONFLICT (event_key) DO NOTHING;
            """, new { eventKey, eventType }, cancellationToken: ct));
        return inserted > 0;
    }

    public async Task ReleaseEventClaimAsync(string eventKey, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await conn.ExecuteAsync(new CommandDefinition(
            "DELETE FROM bridge.processed_events WHERE event_key = @eventKey;",
            new { eventKey }, cancellationToken: ct));
    }

    /// <summary>
    /// Claims one VERSION of a result for forwarding, returning false if that
    /// exact version has already gone downstream.
    ///
    /// Keying on the reference alone would be wrong: OpenELIS corrects a result
    /// by updating the same DiagnosticReport and incrementing meta.versionId, so
    /// a correction would look like a duplicate and be dropped, leaving the HIS
    /// showing a superseded value. Keying on (reference, version) still
    /// suppresses genuine at-least-once redelivery, which is what this guard is
    /// for.
    /// </summary>
    public async Task<bool> TryClaimResultAsync(
        string openelisRef, string versionId, Guid orderId, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var inserted = await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO bridge.forwarded_results (openelis_result_ref, version_id, order_id)
            VALUES (@openelisRef, @versionId, @orderId)
            ON CONFLICT (openelis_result_ref, version_id) DO NOTHING;
            """, new { openelisRef, versionId, orderId }, cancellationToken: ct));
        return inserted > 0;
    }

    public async Task DeadLetterAsync(
        string source, string reason, string? payload, string? correlationId, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO bridge.dead_letters (source, reason, payload, correlation_id)
            VALUES (@source, @reason, @payload::jsonb, @correlationId);
            """, new { source, reason, payload, correlationId }, cancellationToken: ct));
        log.LogError("Dead-lettered from {Source}: {Reason} (correlation {CorrelationId})",
            source, reason, correlationId);
    }

    public async Task<IReadOnlyList<DeadLetterRow>> GetDeadLettersAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<DeadLetterRow>(new CommandDefinition("""
            SELECT id, source, reason, correlation_id, created_at
            FROM bridge.dead_letters ORDER BY created_at DESC LIMIT 100;
            """, cancellationToken: ct));
        return rows.ToList();
    }

    // --- Discovered test catalogue -----------------------------------------

    public async Task<IReadOnlyList<CatalogueEntry>> GetCatalogueAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<CatalogueEntry>(new CommandDefinition("""
            SELECT loinc            AS Loinc,
                   openelis_test_id AS OpenElisTestId,
                   name             AS Name,
                   specimen_name    AS SpecimenName,
                   specimen_id      AS SpecimenId,
                   specimen_abbrev  AS SpecimenAbbreviation,
                   result_unit      AS ResultUnit
            FROM bridge.test_catalogue
            ORDER BY name;
            """, cancellationToken: ct));
        return rows.ToList();
    }

    public async Task<DateTimeOffset?> GetCatalogueSyncedAtAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        return await conn.ExecuteScalarAsync<DateTimeOffset?>(new CommandDefinition(
            "SELECT max(synced_at) FROM bridge.test_catalogue;", cancellationToken: ct));
    }

    /// <summary>
    /// Swaps the whole menu in one transaction. Deleting and re-inserting across
    /// two statements would leave a window in which the catalogue endpoint
    /// returns nothing, and a doctor loading the ordering screen in that window
    /// would see an empty list rather than an error.
    /// </summary>
    public async Task ReplaceCatalogueAsync(IReadOnlyList<CatalogueEntry> entries, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        await conn.ExecuteAsync(new CommandDefinition(
            "DELETE FROM bridge.test_catalogue;", transaction: tx, cancellationToken: ct));

        await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO bridge.test_catalogue
                (loinc, openelis_test_id, name, specimen_name, specimen_id,
                 specimen_abbrev, result_unit, synced_at)
            VALUES (@Loinc, @OpenElisTestId, @Name, @SpecimenName, @SpecimenId,
                    @SpecimenAbbreviation, @ResultUnit, now());
            """, entries, transaction: tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
    }

    public async Task<long> BeginCatalogueSyncAsync(int testsBefore, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        return await conn.ExecuteScalarAsync<long>(new CommandDefinition("""
            INSERT INTO bridge.catalogue_syncs (status, tests_before)
            VALUES ('RUNNING', @testsBefore) RETURNING id;
            """, new { testsBefore }, cancellationToken: ct));
    }

    public async Task FinishCatalogueSyncAsync(
        long id, string status, int testsAfter, CatalogueDiff diff, string? detail, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await conn.ExecuteAsync(new CommandDefinition("""
            UPDATE bridge.catalogue_syncs
               SET finished_at = now(), status = @status, tests_after = @testsAfter,
                   added = @added, removed = @removed, changed = @changed, detail = @detail
             WHERE id = @id;
            """, new
        {
            id, status, testsAfter, detail,
            added = string.Join("; ", diff.Added),
            removed = string.Join("; ", diff.Removed),
            changed = string.Join("; ", diff.Changed)
        }, cancellationToken: ct));
    }

    public async Task<IReadOnlyList<SyncHistoryRow>> GetCatalogueSyncsAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<SyncHistoryRow>(new CommandDefinition("""
            SELECT id, started_at AS StartedAt, finished_at AS FinishedAt, status,
                   tests_before AS TestsBefore, tests_after AS TestsAfter,
                   added, removed, changed, detail
            FROM bridge.catalogue_syncs ORDER BY started_at DESC LIMIT 20;
            """, cancellationToken: ct));
        return rows.ToList();
    }

    // --- Result push channel health ----------------------------------------

    public async Task RecordExportCheckAsync(
        string verdict, ExportSubscription? s, string detail, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO bridge.export_status_checks
                (subscription_id, endpoint, verdict, last_status, last_success, last_attempt,
                 failed_last_24h, total_last_24h, max_interval_minutes, detail)
            VALUES (@id, @endpoint, @verdict, @lastStatus, @lastSuccess, @lastAttempt,
                    @failed, @total, @maxInterval, @detail);
            """, new
        {
            id = s?.Id, endpoint = s?.Endpoint, verdict, detail,
            lastStatus = s?.LastStatus, lastSuccess = s?.LastSuccess, lastAttempt = s?.LastAttempt,
            failed = s?.FailedLast24h, total = s?.TotalLast24h, maxInterval = s?.MaxIntervalMinutes
        }, cancellationToken: ct));
    }

    public async Task<ExportCheckRow?> GetLatestExportCheckAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        return await conn.QuerySingleOrDefaultAsync<ExportCheckRow>(new CommandDefinition("""
            SELECT checked_at AS CheckedAt, verdict, endpoint, last_status AS LastStatus,
                   last_success AS LastSuccess, failed_last_24h AS FailedLast24h,
                   total_last_24h AS TotalLast24h, detail
            FROM bridge.export_status_checks ORDER BY checked_at DESC LIMIT 1;
            """, cancellationToken: ct));
    }

    public async Task<IReadOnlyList<ExportCheckRow>> GetExportChecksAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<ExportCheckRow>(new CommandDefinition("""
            SELECT checked_at AS CheckedAt, verdict, endpoint, last_status AS LastStatus,
                   last_success AS LastSuccess, failed_last_24h AS FailedLast24h,
                   total_last_24h AS TotalLast24h, detail
            FROM bridge.export_status_checks ORDER BY checked_at DESC LIMIT 50;
            """, cancellationToken: ct));
        return rows.ToList();
    }

    public static string ToJson(Resource resource) => Serializer.SerializeToString(resource);
    public static Resource ParseResource(string json) => Parser.Parse<Resource>(json);

    public static string SerializeForDeadLetter(object o) => JsonSerializer.Serialize(o);
}

public sealed record DeadLetterRow(
    long Id, string Source, string Reason, string? CorrelationId, DateTimeOffset CreatedAt);

public sealed record ExportCheckRow(
    DateTimeOffset CheckedAt, string Verdict, string? Endpoint, string? LastStatus,
    DateTimeOffset? LastSuccess, int? FailedLast24h, int? TotalLast24h, string? Detail);

public sealed record SyncHistoryRow(
    long Id, DateTimeOffset StartedAt, DateTimeOffset? FinishedAt, string Status,
    int TestsBefore, int TestsAfter, string? Added, string? Removed, string? Changed, string? Detail);

internal sealed record MirrorRow(string Content, DateTimeOffset ReceivedAt);
