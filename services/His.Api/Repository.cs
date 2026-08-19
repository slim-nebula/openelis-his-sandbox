using System.Text.Json;
using Dapper;
using Npgsql;

namespace His.Api;

/// <summary>
/// All access to the HIS sandbox database. Nothing outside this service holds
/// credentials for it — the bridge and OpenELIS reach HIS data over HTTP only.
/// </summary>
public sealed class Repository(NpgsqlDataSource dataSource, KafkaOptions kafka, ILogger<Repository> log)
{
    private string orderCreatedTopic => kafka.OrderCreated;

    public async Task<Patient> CreatePatientAsync(CreatePatientRequest req, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);

        var patientId = Guid.NewGuid();
        var mrn = string.IsNullOrWhiteSpace(req.ExternalPatientId)
            ? await NextMrnAsync(conn)
            : req.ExternalPatientId.Trim();

        const string sql = """
            INSERT INTO his.patients
                (patient_id, external_patient_id, first_name, last_name, sex,
                 date_of_birth, phone, national_id)
            VALUES (@patientId, @mrn, @firstName, @lastName, @sex, @dob, @phone, @nationalId)
            RETURNING patient_id, external_patient_id, first_name, last_name, sex,
                      date_of_birth, phone, national_id, created_at;
            """;

        return await conn.QuerySingleAsync<Patient>(new CommandDefinition(sql, new
        {
            patientId,
            mrn,
            firstName = req.FirstName.Trim(),
            lastName = req.LastName.Trim(),
            sex = NormaliseSex(req.Sex),
            dob = req.DateOfBirth,
            phone = Blank(req.Phone),
            nationalId = Blank(req.NationalId)
        }, cancellationToken: ct));
    }

    private static async Task<string> NextMrnAsync(NpgsqlConnection conn)
    {
        // A sequence, not count(*) + 1. Counting rows reissues a number as soon
        // as any patient is deleted, and two concurrent registrations read the
        // same count and compute the same MRN. The unique constraint on
        // external_patient_id caught both, so the failure was a registration
        // that errored rather than a duplicate MRN - but that constraint is a
        // last line of defence, not an allocation strategy.
        var n = await conn.ExecuteScalarAsync<long>("SELECT nextval('his.mrn_seq')");
        return $"MRN-{n:D6}";
    }

    public async Task<Patient?> GetPatientAsync(Guid id, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        return await conn.QuerySingleOrDefaultAsync<Patient>(new CommandDefinition("""
            SELECT patient_id, external_patient_id, first_name, last_name, sex,
                   date_of_birth, phone, national_id, created_at
            FROM his.patients WHERE patient_id = @id;
            """, new { id }, cancellationToken: ct));
    }

    public async Task<IReadOnlyList<Patient>> SearchPatientsAsync(string? q, int limit, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var term = $"%{(q ?? string.Empty).Trim().ToLowerInvariant()}%";
        var rows = await conn.QueryAsync<Patient>(new CommandDefinition("""
            SELECT patient_id, external_patient_id, first_name, last_name, sex,
                   date_of_birth, phone, national_id, created_at
            FROM his.patients
            WHERE @term = '%%'
               OR lower(last_name)  LIKE @term
               OR lower(first_name) LIKE @term
               OR lower(external_patient_id) LIKE @term
               OR lower(coalesce(national_id, '')) LIKE @term
            ORDER BY created_at DESC
            LIMIT @limit;
            """, new { term, limit }, cancellationToken: ct));
        return rows.ToList();
    }

    public async Task<IReadOnlyList<CatalogueEntry>> GetCatalogueAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<CatalogueEntry>(new CommandDefinition("""
            SELECT test_code, test_name, loinc_code, specimen_type, specimen_snomed, result_unit
            FROM his.test_catalogue WHERE is_active ORDER BY test_name;
            """, cancellationToken: ct));
        return rows.ToList();
    }

    /// <summary>
    /// Creates the order and records the creation event in one transaction, so
    /// an order can never exist without its audit trail.
    /// </summary>
    public async Task<(LabOrder Order, CatalogueEntry Test)> CreateOrderAsync(
        CreateLabOrderRequest req, string correlationId, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        var test = await conn.QuerySingleOrDefaultAsync<CatalogueEntry>(new CommandDefinition("""
            SELECT test_code, test_name, loinc_code, specimen_type, specimen_snomed, result_unit
            FROM his.test_catalogue WHERE test_code = @code AND is_active;
            """, new { code = req.TestCode }, tx, cancellationToken: ct))
            ?? throw new DomainException($"Unknown or inactive test code '{req.TestCode}'.");

        var patientExists = await conn.ExecuteScalarAsync<bool>(new CommandDefinition(
            "SELECT exists(SELECT 1 FROM his.patients WHERE patient_id = @id);",
            new { id = req.PatientId }, tx, cancellationToken: ct));
        if (!patientExists)
            throw new DomainException($"Unknown patient '{req.PatientId}'.");

        var orderId = Guid.NewGuid();
        // <= 60 characters: OpenELIS truncates electronic_order.external_id beyond that.
        var orderNumber = $"LAB-{DateTime.UtcNow:yyyyMMdd}-{orderId.ToString("N")[..8].ToUpperInvariant()}";

        var order = await conn.QuerySingleAsync<LabOrder>(new CommandDefinition("""
            INSERT INTO his.lab_orders
                (order_id, order_number, patient_id, test_code, test_name, order_status,
                 ordering_provider, facility_code, priority, correlation_id)
            VALUES (@orderId, @orderNumber, @patientId, @testCode, @testName, 'CREATED',
                    @provider, @facility, @priority, @correlationId)
            RETURNING order_id, order_number, patient_id, test_code, test_name, order_status,
                      ordering_provider, facility_code, priority, status_detail,
                      created_at, updated_at;
            """, new
        {
            orderId,
            orderNumber,
            patientId = req.PatientId,
            testCode = test.TestCode,
            testName = test.TestName,
            provider = req.OrderingProvider,
            facility = req.FacilityCode,
            priority = string.IsNullOrWhiteSpace(req.Priority) ? "routine" : req.Priority!.ToLowerInvariant(),
            correlationId
        }, tx, cancellationToken: ct));

        await AppendEventAsync(conn, tx, orderId, "ORDER_CREATED",
            $"Order created for test {test.TestCode}", correlationId, null, ct);

        // The lab.order.created event is written here, in the same transaction
        // as the order itself. Nothing is published to Kafka on this path — the
        // outbox relay does that. One commit decides whether both the order and
        // its event exist, which is what makes a crash survivable.
        var payload = JsonSerializer.Serialize(new
        {
            eventId = Guid.NewGuid().ToString(),
            eventType = "lab.order.created",
            occurredAt = DateTimeOffset.UtcNow,
            correlationId,
            orderId,
            orderNumber,
            patientId = req.PatientId,
            testCode = test.TestCode,
            loincCode = test.LoincCode
        });

        await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO his.outbox
                (event_id, aggregate_type, aggregate_id, topic, partition_key, payload, correlation_id)
            VALUES (@eventId, 'lab_order', @orderId, @topic, @partitionKey, @payload::jsonb, @correlationId);
            """, new
        {
            eventId = Guid.NewGuid(),
            orderId,
            topic = orderCreatedTopic,
            partitionKey = orderId.ToString(),
            payload,
            correlationId
        }, tx, cancellationToken: ct));

        await tx.CommitAsync(ct);
        log.LogInformation("Order {OrderNumber} created for patient {PatientId} (correlation {CorrelationId})",
            orderNumber, req.PatientId, correlationId);

        return (order, test);
    }

    public async Task<LabOrder?> GetOrderAsync(Guid orderId, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        return await conn.QuerySingleOrDefaultAsync<LabOrder>(new CommandDefinition("""
            SELECT order_id, order_number, patient_id, test_code, test_name, order_status,
                   ordering_provider, facility_code, priority, status_detail, created_at, updated_at
            FROM his.lab_orders WHERE order_id = @orderId;
            """, new { orderId }, cancellationToken: ct));
    }

    public async Task<IReadOnlyList<LabOrder>> GetOrdersForPatientAsync(Guid patientId, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<LabOrder>(new CommandDefinition("""
            SELECT order_id, order_number, patient_id, test_code, test_name, order_status,
                   ordering_provider, facility_code, priority, status_detail, created_at, updated_at
            FROM his.lab_orders WHERE patient_id = @patientId ORDER BY created_at DESC;
            """, new { patientId }, cancellationToken: ct));
        return rows.ToList();
    }

    public async Task<BridgeOrderPayload?> GetBridgePayloadAsync(Guid orderId, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);

        // Two round trips rather than a Dapper multi-map: both records are
        // positional, and splitting them by hand keeps the mapping obvious.
        var order = await conn.QuerySingleOrDefaultAsync<OrderWithTest>(new CommandDefinition("""
            SELECT o.order_id, o.order_number, o.test_code, o.test_name,
                   c.loinc_code, c.specimen_type, c.specimen_snomed, c.result_unit,
                   o.order_status, o.ordering_provider, o.facility_code, o.priority,
                   o.created_at, o.patient_id
            FROM his.lab_orders o
            JOIN his.test_catalogue c ON c.test_code = o.test_code
            WHERE o.order_id = @orderId;
            """, new { orderId }, cancellationToken: ct));

        if (order is null) return null;

        var patient = await GetPatientAsync(order.PatientId, ct);
        if (patient is null) return null;

        return new BridgeOrderPayload(
            order.OrderId, order.OrderNumber, order.TestCode, order.TestName,
            order.LoincCode, order.SpecimenType, order.SpecimenSnomed, order.ResultUnit,
            order.OrderStatus, order.OrderingProvider, order.FacilityCode, order.Priority,
            order.CreatedAt, patient);
    }

    private sealed record OrderWithTest(
        Guid OrderId, string OrderNumber, string TestCode, string TestName,
        string LoincCode, string SpecimenType, string? SpecimenSnomed, string? ResultUnit,
        string OrderStatus, string OrderingProvider, string FacilityCode, string Priority,
        DateTimeOffset CreatedAt, Guid PatientId);

    public async Task UpdateOrderStatusAsync(
        string orderNumber, string status, string? detail, string? correlationId, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        // OpenELIS updates the same Task more than once (received, then
        // accepted), and the bridge relays each one. Only a genuine status
        // change earns an audit row, so the trail stays a history of the order
        // rather than a log of how chatty the LIS was.
        var orderId = await conn.ExecuteScalarAsync<Guid?>(new CommandDefinition("""
            UPDATE his.lab_orders
               SET order_status = @status, status_detail = @detail, updated_at = now()
             WHERE order_number = @orderNumber
               AND order_status IS DISTINCT FROM @status
            RETURNING order_id;
            """, new { orderNumber, status, detail }, tx, cancellationToken: ct));

        if (orderId is null)
        {
            var exists = await conn.ExecuteScalarAsync<bool>(new CommandDefinition(
                "SELECT exists(SELECT 1 FROM his.lab_orders WHERE order_number = @orderNumber);",
                new { orderNumber }, tx, cancellationToken: ct));

            if (!exists)
                log.LogWarning("Status update for unknown order {OrderNumber} ignored", orderNumber);
            else
                log.LogDebug("Order {OrderNumber} already {Status}; no audit row written", orderNumber, status);

            await tx.RollbackAsync(ct);
            return;
        }

        await AppendEventAsync(conn, tx, orderId.Value, status, detail, correlationId, null, ct);
        await tx.CommitAsync(ct);
    }

    /// <summary>
    /// Idempotent by OpenELIS record reference: a replayed release message for
    /// the same OpenELIS result updates the projection instead of duplicating it.
    /// </summary>
    public async Task<bool> UpsertResultAsync(ReleasedResultMessage msg, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        var order = await conn.QuerySingleOrDefaultAsync<OrderKey>(
            new CommandDefinition("""
                SELECT order_id, patient_id, test_code, test_name
                FROM his.lab_orders WHERE order_number = @orderNumber;
                """, new { msg.OrderNumber }, tx, cancellationToken: ct));

        if (order is null)
        {
            log.LogWarning("Released result for unknown order {OrderNumber} ignored", msg.OrderNumber);
            await tx.RollbackAsync(ct);
            return false;
        }

        await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO his.lab_results_summary
                (result_id, order_id, patient_id, test_code, test_name, result_value,
                 result_unit, reference_range, interpretation, result_status,
                 released_at, openelis_result_ref)
            VALUES (@resultId, @orderId, @patientId, @testCode, @testName, @value,
                    @unit, @range, @interpretation, @status, @releasedAt, @ref)
            ON CONFLICT (openelis_result_ref) DO UPDATE SET
                result_value    = excluded.result_value,
                result_unit     = excluded.result_unit,
                reference_range = excluded.reference_range,
                interpretation  = excluded.interpretation,
                result_status   = excluded.result_status,
                released_at     = excluded.released_at,
                received_at     = now();
            """, new
        {
            resultId = Guid.NewGuid(),
            orderId = order.OrderId,
            patientId = order.PatientId,
            testCode = msg.TestCode ?? order.TestCode,
            testName = msg.TestName ?? order.TestName,
            value = msg.ResultValue,
            unit = msg.ResultUnit,
            range = msg.ReferenceRange,
            interpretation = msg.Interpretation,
            status = msg.ResultStatus,
            releasedAt = msg.ReleasedAt,
            @ref = msg.OpenelisResultRef
        }, tx, cancellationToken: ct));

        await conn.ExecuteAsync(new CommandDefinition("""
            UPDATE his.lab_orders
               SET order_status = 'RESULT_AVAILABLE', updated_at = now()
             WHERE order_id = @orderId;
            """, new { orderId = order.OrderId }, tx, cancellationToken: ct));

        await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO his.integration_mappings
                (his_entity_type, his_id, external_system, external_type, external_id)
            VALUES ('result', @hisId, 'openelis', 'DiagnosticReport', @externalId)
            ON CONFLICT (his_entity_type, his_id, external_system, external_type) DO NOTHING;
            """, new { hisId = order.OrderId.ToString(), externalId = msg.OpenelisResultRef },
            tx, cancellationToken: ct));

        await AppendEventAsync(conn, tx, order.OrderId, "RESULT_RECEIVED",
            $"Released result {msg.OpenelisResultRef} stored", msg.CorrelationId,
            JsonSerializer.Serialize(msg), ct);

        await tx.CommitAsync(ct);
        log.LogInformation("Stored released result {Ref} for order {OrderNumber}",
            msg.OpenelisResultRef, msg.OrderNumber);
        return true;
    }

    public async Task<IReadOnlyList<ResultSummary>> GetResultsForPatientAsync(Guid patientId, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<ResultSummary>(new CommandDefinition("""
            SELECT result_id, order_id, patient_id, test_code, test_name, result_value,
                   result_unit, reference_range, interpretation, result_status,
                   released_at, openelis_result_ref, received_at
            FROM his.lab_results_summary
            WHERE patient_id = @patientId
            ORDER BY released_at DESC;
            """, new { patientId }, cancellationToken: ct));
        return rows.ToList();
    }

    public async Task<IReadOnlyList<ResultSummary>> GetResultsForOrderAsync(Guid orderId, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        var rows = await conn.QueryAsync<ResultSummary>(new CommandDefinition("""
            SELECT result_id, order_id, patient_id, test_code, test_name, result_value,
                   result_unit, reference_range, interpretation, result_status,
                   released_at, openelis_result_ref, received_at
            FROM his.lab_results_summary WHERE order_id = @orderId ORDER BY released_at DESC;
            """, new { orderId }, cancellationToken: ct));
        return rows.ToList();
    }

    private static async Task AppendEventAsync(
        NpgsqlConnection conn, System.Data.Common.DbTransaction tx, Guid orderId,
        string type, string? detail, string? correlationId, string? payloadJson, CancellationToken ct)
    {
        await conn.ExecuteAsync(new CommandDefinition("""
            INSERT INTO his.lab_order_events (order_id, event_type, detail, correlation_id, payload)
            VALUES (@orderId, @type, @detail, @correlationId, @payload::jsonb);
            """, new { orderId, type, detail, correlationId, payload = payloadJson },
            tx, cancellationToken: ct));
    }

    private static string NormaliseSex(string sex) => sex?.Trim().ToUpperInvariant() switch
    {
        "M" or "MALE" => "M",
        "F" or "FEMALE" => "F",
        _ => "U"
    };

    private static string? Blank(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    private sealed record OrderKey(Guid OrderId, Guid PatientId, string TestCode, string TestName);
}

/// <summary>
/// Npgsql hands back a DateTime for `date` columns via the untyped accessor
/// Dapper uses, so the DateOnly properties need an explicit handler.
/// </summary>
public sealed class DateOnlyTypeHandler : SqlMapper.TypeHandler<DateOnly>
{
    public override DateOnly Parse(object value) => value switch
    {
        DateOnly d => d,
        DateTime dt => DateOnly.FromDateTime(dt),
        string s => DateOnly.Parse(s),
        _ => throw new InvalidCastException($"Cannot convert {value?.GetType().Name} to DateOnly")
    };

    public override void SetValue(System.Data.IDbDataParameter parameter, DateOnly value)
    {
        parameter.DbType = System.Data.DbType.Date;
        parameter.Value = value.ToDateTime(TimeOnly.MinValue);
    }
}

/// <summary>
/// Npgsql materialises `timestamptz` as a UTC DateTime, which Dapper cannot
/// cast to the DateTimeOffset properties on these records.
/// </summary>
public sealed class DateTimeOffsetTypeHandler : SqlMapper.TypeHandler<DateTimeOffset>
{
    public override DateTimeOffset Parse(object value) => value switch
    {
        DateTimeOffset dto => dto,
        DateTime dt => new DateTimeOffset(DateTime.SpecifyKind(dt, DateTimeKind.Utc)),
        string s => DateTimeOffset.Parse(s),
        _ => throw new InvalidCastException($"Cannot convert {value?.GetType().Name} to DateTimeOffset")
    };

    // No DbType: Npgsql infers `timestamptz` from a DateTime with Kind=Utc.
    public override void SetValue(System.Data.IDbDataParameter parameter, DateTimeOffset value) =>
        parameter.Value = value.UtcDateTime;
}

public sealed class DomainException(string message) : Exception(message);
