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

    /// <summary>
    /// Largest number of resources one search may return. Without a cap the
    /// order poll serialises every Task the bridge has ever published into one
    /// response, and the cost of a poll grows with the age of the deployment.
    /// </summary>
    public int MaxSearchResults { get; init; } = 200;

    // --- Access -------------------------------------------------------------
    /// <summary>
    /// Shared token for the endpoints that change something or expose
    /// operational detail. Those endpoints also accept a user token from IAM;
    /// see OpsAccessFilter for why both, and for why an unset value refuses
    /// everything rather than allowing it.
    /// </summary>
    public string AdminToken { get; init; } = "";

    /// <summary>
    /// Hostnames permitted to call /fhir. Empty disables the check. This is a
    /// network-layer control because OpenELIS cannot present a credential at
    /// all - the reasoning is recorded on FhirPeerGuard.
    /// </summary>
    public string[] FhirAllowedPeers { get; init; } = [];

    // --- Retention ----------------------------------------------------------
    public int RetentionReceivedDays { get; init; } = 30;
    public int RetentionEventsDays { get; init; } = 14;
    public int RetentionExportChecksDays { get; init; } = 30;
    public int RetentionDeadLettersDays { get; init; } = 180;
    public int RetentionSweepHours { get; init; } = 24;

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

    // --- Result push monitoring ---------------------------------------------
    /// <summary>How often to ask OpenELIS whether it is still pushing results.</summary>
    public int ExportCheckMinutes { get; init; } = 5;

    /// <summary>
    /// How many of OpenELIS's own declared push cycles may pass without a
    /// success before the channel counts as stale. One missed push is a hiccup;
    /// several in a row is an outage.
    /// </summary>
    public int ExportStaleCycles { get; init; } = 5;

    /// <summary>Host OpenELIS names in its subscription, used to find our own entry.</summary>
    public string PublicFhirHost { get; init; } = "bridge";

    // --- Estate identity ------------------------------------------------------
    /// <summary>
    /// The secret IAM signs user tokens with. Shared, because the estate signs
    /// HS256: the key that verifies is the key that signs, so every holder can
    /// also mint. Empty means /ops accepts the operator token only.
    /// </summary>
    public string JwtSecret { get; init; } = "";

    /// <summary>IAM group a user token must carry to reach /ops. Empty allows any authenticated user.</summary>
    public string OpsGroup { get; init; } = "";

    /// <summary>host:port for the revocation check. Empty disables it - see HisTokenValidator.</summary>
    public string RedisConfiguration { get; init; } = "";

    /// <summary>Presented to the HIS service on /internal/*, in the estate's service-to-service header.</summary>
    public string InternalApiKey { get; init; } = "";

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
        MaxSearchResults = int.Parse(Env("BRIDGE_MAX_SEARCH_RESULTS", "200")),
        AdminToken = Env("BRIDGE_ADMIN_TOKEN", ""),
        FhirAllowedPeers = SplitPeers(Env("BRIDGE_FHIR_ALLOWED_PEERS", "")),
        RetentionReceivedDays = int.Parse(Env("RETENTION_RECEIVED_DAYS", "30")),
        RetentionEventsDays = int.Parse(Env("RETENTION_EVENTS_DAYS", "14")),
        RetentionExportChecksDays = int.Parse(Env("RETENTION_EXPORT_CHECKS_DAYS", "30")),
        RetentionDeadLettersDays = int.Parse(Env("RETENTION_DEAD_LETTERS_DAYS", "180")),
        RetentionSweepHours = int.Parse(Env("RETENTION_SWEEP_HOURS", "24")),
        OpenElisBaseUrl = Env("OE_REST_BASE_URL", ""),
        OpenElisUser = Env("OE_SERVICE_USER", ""),
        OpenElisPassword = Env("OE_SERVICE_PASSWORD", ""),
        OpenElisTimeoutSeconds = int.Parse(Env("OE_REST_TIMEOUT_SECONDS", "120")),
        OpenElisAcceptAnyCertificate = Env("OE_REST_ACCEPT_ANY_CERT", "true") == "true",
        CatalogueMaxShrink = double.Parse(Env("CATALOGUE_MAX_SHRINK", "0.30")),
        ExportCheckMinutes = int.Parse(Env("EXPORT_CHECK_MINUTES", "5")),
        ExportStaleCycles = int.Parse(Env("EXPORT_STALE_CYCLES", "5")),
        PublicFhirHost = Env("BRIDGE_PUBLIC_FHIR_HOST", "bridge"),
        JwtSecret = Env("JWT_SECRET", ""),
        OpsGroup = Env("BRIDGE_OPS_GROUP", ""),
        RedisConfiguration = RedisTarget(),
        InternalApiKey = Env("INTERNAL_API_KEY", "")
    };

    /// <summary>
    /// Redis as StackExchange.Redis wants it: host:port.
    ///
    /// REDIS_URL is accepted in the shapes the estate's compose files use
    /// (`redis:6379`, `redis://redis:6379`) because those are what a copied
    /// deployment will set - and a mis-parsed address here fails silently, as a
    /// service that never enforces revocation rather than one that errors.
    /// </summary>
    private static string RedisTarget()
    {
        var host = Env("REDIS_HOST", "");
        var port = Env("REDIS_PORT", "6379");
        if (host.Length > 0) return $"{host}:{port}";

        var raw = Env("REDIS_URL", "");
        if (raw.Length == 0) return "";

        raw = raw.Replace("rediss://", "").Replace("redis://", "");
        return raw.Contains(':') ? raw : $"{raw}:{port}";
    }

    /// <summary>Catalogue discovery is optional; without credentials the endpoints refuse rather than crash the bridge.</summary>
    public bool CatalogueDiscoveryConfigured =>
        OpenElisBaseUrl.Length > 0 && OpenElisUser.Length > 0 && OpenElisPassword.Length > 0;

    private static string[] SplitPeers(string value) =>
        value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

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
