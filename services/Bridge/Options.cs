namespace Bridge;

public sealed class BridgeOptions
{
    public required string ConnectionString { get; init; }
    public required string HisApiBaseUrl { get; init; }
    public required string KafkaBootstrap { get; init; }

    public string TopicOrderCreated { get; init; } = "lab.order.created";
    public string TopicOrderSent { get; init; } = "lab.order.sent";
    public string TopicOrderFailed { get; init; } = "lab.order.failed";
    public string TopicResultReleased { get; init; } = "lab.result.released";
    public string TopicResultFailed { get; init; } = "lab.result.failed";
    public string ConsumerGroup { get; init; } = "bridge";

    /// <summary>
    /// Value stamped on Task.owner. OpenELIS searches for exactly this string,
    /// so it must equal org.openelisglobal.remote.source.identifier.
    /// </summary>
    public string LabOwnerReference { get; init; } = "Practitioner/openelis-sandbox-lab";

    public int MaxRetries { get; init; } = 5;
    public int RetryBaseDelaySeconds { get; init; } = 2;
    public int CorrelationRetryMinutes { get; init; } = 15;

    public static BridgeOptions FromEnvironment() => new()
    {
        ConnectionString = Require("BRIDGE_DB_CONNECTION"),
        HisApiBaseUrl = Env("HIS_API_INTERNAL_URL", "http://his-api:8080"),
        KafkaBootstrap = Env("KAFKA_BOOTSTRAP", "kafka:9092"),
        TopicOrderCreated = Env("TOPIC_ORDER_CREATED", "lab.order.created"),
        TopicOrderSent = Env("TOPIC_ORDER_SENT", "lab.order.sent"),
        TopicOrderFailed = Env("TOPIC_ORDER_FAILED", "lab.order.failed"),
        TopicResultReleased = Env("TOPIC_RESULT_RELEASED", "lab.result.released"),
        TopicResultFailed = Env("TOPIC_RESULT_FAILED", "lab.result.failed"),
        LabOwnerReference = Env("OE_REMOTE_SOURCE_IDENTIFIER", "Practitioner/openelis-sandbox-lab"),
        MaxRetries = int.Parse(Env("BRIDGE_MAX_RETRIES", "5")),
        RetryBaseDelaySeconds = int.Parse(Env("BRIDGE_RETRY_BASE_DELAY_SECONDS", "2")),
        CorrelationRetryMinutes = int.Parse(Env("BRIDGE_RESULT_CORRELATION_RETRY_MINUTES", "15"))
    };

    public static string Env(string key, string fallback) =>
        Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : fallback;

    private static string Require(string key) =>
        Environment.GetEnvironmentVariable(key) is { Length: > 0 } v
            ? v
            : throw new InvalidOperationException($"{key} is required.");
}

/// <summary>The HIS order payload, exactly as /internal/lab-orders/{id} returns it.</summary>
public sealed record HisOrder(
    Guid OrderId,
    string OrderNumber,
    string TestCode,
    string TestName,
    string LoincCode,
    string SpecimenType,
    string? SpecimenSnomed,
    string? ResultUnit,
    string OrderStatus,
    string OrderingProvider,
    string FacilityCode,
    string Priority,
    DateTimeOffset CreatedAt,
    HisPatient Patient);

public sealed record HisPatient(
    Guid PatientId,
    string ExternalPatientId,
    string FirstName,
    string LastName,
    string Sex,
    DateOnly DateOfBirth,
    string? Phone,
    string? NationalId);

public sealed record OrderCreatedEvent(
    string? EventId,
    string? CorrelationId,
    Guid OrderId,
    string OrderNumber,
    Guid PatientId,
    string TestCode);

public sealed record TrackedOrder(
    Guid OrderId,
    string OrderNumber,
    Guid PatientId,
    string TestCode,
    string LoincCode,
    string FhirTaskId,
    string FhirServicerequestId,
    string FhirPatientId,
    string? FhirSpecimenId,
    string TaskStatus,
    int Attempts,
    string? CorrelationId);
