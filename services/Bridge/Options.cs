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

    // --- Catalogue discovery ------------------------------------------------
    /// <summary>Root of the OpenELIS web application, e.g. https://openelis-proxy/api/OpenELIS-Global</summary>
    public string OpenElisBaseUrl { get; init; } = "";
    public string OpenElisUser { get; init; } = "";
    public string OpenElisPassword { get; init; } = "";
    public int OpenElisTimeoutSeconds { get; init; } = 120;

    /// <summary>
    /// Trust any certificate when talking to OpenELIS. True in the sandbox,
    /// which serves a self-signed certificate; it must be false anywhere real,
    /// which is why it is configuration rather than an unconditional bypass.
    /// </summary>
    public bool OpenElisAcceptAnyCertificate { get; init; } = true;

    /// <summary>
    /// The largest share of the menu a single sync may remove before it is
    /// refused. A laboratory withdrawing a third of its tests at once is
    /// possible; a partial read that looks like one is far likelier.
    /// </summary>
    public double CatalogueMaxShrink { get; init; } = 0.30;

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
        CorrelationRetryMinutes = int.Parse(Env("BRIDGE_RESULT_CORRELATION_RETRY_MINUTES", "15")),
        OpenElisBaseUrl = Env("OE_REST_BASE_URL", ""),
        OpenElisUser = Env("OE_SERVICE_USER", ""),
        OpenElisPassword = Env("OE_SERVICE_PASSWORD", ""),
        OpenElisTimeoutSeconds = int.Parse(Env("OE_REST_TIMEOUT_SECONDS", "120")),
        OpenElisAcceptAnyCertificate = Env("OE_REST_ACCEPT_ANY_CERT", "true") == "true",
        CatalogueMaxShrink = double.Parse(Env("CATALOGUE_MAX_SHRINK", "0.30"))
    };

    /// <summary>Catalogue discovery is optional; without credentials the endpoints refuse rather than crash the bridge.</summary>
    public bool CatalogueDiscoveryConfigured =>
        OpenElisBaseUrl.Length > 0 && OpenElisUser.Length > 0 && OpenElisPassword.Length > 0;

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
