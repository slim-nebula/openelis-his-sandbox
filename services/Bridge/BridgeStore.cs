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
public sealed class BridgeStore(NpgsqlDataSource dataSource, ILogger<BridgeStore> log)
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
    /// </summary>
    public async Task<IReadOnlyList<Resource>> SearchTasksAsync(
        string? status, string? owner, string? id, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<string>(new CommandDefinition("""
            SELECT content::text FROM bridge.fhir_resources
            WHERE resource_type = 'Task'
              AND (@status IS NULL OR content ->> 'status' = @status)
              AND (@owner  IS NULL OR content -> 'owner' ->> 'reference' = @owner)
              AND (@id     IS NULL OR resource_id = @id)
            ORDER BY last_updated;
            """, new { status, owner, id }, cancellationToken: ct));
        return rows.Select(Parser.Parse<Resource>).ToList();
    }

    public async Task<IReadOnlyList<Resource>> SearchByTypeAsync(string type, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<string>(new CommandDefinition("""
            SELECT content::text FROM bridge.fhir_resources
            WHERE resource_type = @type ORDER BY last_updated;
            """, new { type }, cancellationToken: ct));
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

    public static string ToJson(Resource resource) => Serializer.SerializeToString(resource);
    public static Resource ParseResource(string json) => Parser.Parse<Resource>(json);

    public static string SerializeForDeadLetter(object o) => JsonSerializer.Serialize(o);
}

public sealed record DeadLetterRow(
    long Id, string Source, string Reason, string? CorrelationId, DateTimeOffset CreatedAt);

internal sealed record MirrorRow(string Content, DateTimeOffset ReceivedAt);
