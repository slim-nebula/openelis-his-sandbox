using System.Text.Json.Serialization;

namespace His.Api;

// --- Persistence shapes -----------------------------------------------------

public sealed record Patient(
    Guid PatientId,
    string ExternalPatientId,
    string FirstName,
    string LastName,
    string Sex,
    DateOnly DateOfBirth,
    string? Phone,
    string? NationalId,
    DateTimeOffset CreatedAt);

public sealed record CatalogueEntry(
    string TestCode,
    string TestName,
    string LoincCode,
    string SpecimenType,
    string? SpecimenSnomed,
    string? ResultUnit);

public sealed record LabOrder(
    Guid OrderId,
    string OrderNumber,
    Guid PatientId,
    string TestCode,
    string TestName,
    string OrderStatus,
    string OrderingProvider,
    string FacilityCode,
    string Priority,
    string? StatusDetail,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);

public sealed record ResultSummary(
    Guid ResultId,
    Guid OrderId,
    Guid PatientId,
    string TestCode,
    string TestName,
    string? ResultValue,
    string? ResultUnit,
    string? ReferenceRange,
    string? Interpretation,
    string ResultStatus,
    DateTimeOffset ReleasedAt,
    string OpenelisResultRef,
    DateTimeOffset ReceivedAt);

// --- Request bodies ---------------------------------------------------------

public sealed record CreatePatientRequest(
    string? ExternalPatientId,
    string FirstName,
    string LastName,
    string Sex,
    DateOnly DateOfBirth,
    string? Phone,
    string? NationalId);

public sealed record CreateLabOrderRequest(
    Guid PatientId,
    string TestCode,
    string OrderingProvider,
    string FacilityCode,
    string? Priority);

/// <summary>
/// Simplified released result handed back by the bridge, either as the body of
/// POST /internal/lab-results or as the payload of a lab.result.released event.
/// </summary>
public sealed record ReleasedResultMessage
{
    [JsonPropertyName("eventId")] public string? EventId { get; init; }
    [JsonPropertyName("correlationId")] public string? CorrelationId { get; init; }
    [JsonPropertyName("orderNumber")] public string OrderNumber { get; init; } = "";
    [JsonPropertyName("openelisResultRef")] public string OpenelisResultRef { get; init; } = "";
    [JsonPropertyName("testCode")] public string? TestCode { get; init; }
    [JsonPropertyName("testName")] public string? TestName { get; init; }
    [JsonPropertyName("resultValue")] public string? ResultValue { get; init; }
    [JsonPropertyName("resultUnit")] public string? ResultUnit { get; init; }
    [JsonPropertyName("referenceRange")] public string? ReferenceRange { get; init; }
    [JsonPropertyName("interpretation")] public string? Interpretation { get; init; }
    [JsonPropertyName("resultStatus")] public string ResultStatus { get; init; } = "final";
    [JsonPropertyName("releasedAt")] public DateTimeOffset ReleasedAt { get; init; } = DateTimeOffset.UtcNow;
}

/// <summary>Order lifecycle signals emitted by the bridge.</summary>
public sealed record OrderLifecycleMessage
{
    [JsonPropertyName("eventId")] public string? EventId { get; init; }
    [JsonPropertyName("correlationId")] public string? CorrelationId { get; init; }
    [JsonPropertyName("orderId")] public Guid OrderId { get; init; }
    [JsonPropertyName("orderNumber")] public string OrderNumber { get; init; } = "";
    [JsonPropertyName("status")] public string Status { get; init; } = "";
    [JsonPropertyName("detail")] public string? Detail { get; init; }
}

// --- Outbound view models ---------------------------------------------------

/// <summary>
/// Everything the bridge needs to build a FHIR order, in one call. Keeps the
/// bridge from having to fan out across several HIS endpoints per event.
/// </summary>
public sealed record BridgeOrderPayload(
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
    Patient Patient);
