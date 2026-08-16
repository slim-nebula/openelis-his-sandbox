using System.Security.Cryptography;
using System.Text;
using Hl7.Fhir.Model;
using FhirTask = Hl7.Fhir.Model.Task;
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// Turns a HIS lab order into the FHIR R4 resources OpenELIS expects to find
/// when it polls. The shape is dictated by OpenELIS's importer:
///
///   Task.status   = requested       (the poll filters on this)
///   Task.owner    = the configured lab identity (the poll filters on this too)
///   Task.for      -> Patient
///   Task.basedOn  -> ServiceRequest
///   ServiceRequest.code carries a http://loinc.org coding, which is the ONLY
///                 thing OpenELIS matches a test on
///   ServiceRequest.identifier[0].value becomes the LIS-side external order id
///
/// Every resource id is a UUID because OpenELIS calls UUID.fromString() on the
/// Practitioner (and stores the others as uuid columns).
/// </summary>
public static class OrderMapper
{
    public const string OeSystem = "http://openelis-global.org";
    public const string LoincSystem = "http://loinc.org";
    public const string OrderNumberSystem = "http://his-sandbox.local/lab-order";

    public static MappedOrder Map(HisOrder order, string labOwnerReference)
    {
        var patientId = order.Patient.PatientId.ToString();
        var practitionerId = DeterministicGuid($"provider|{order.OrderingProvider}").ToString();
        var serviceRequestId = order.OrderId.ToString();
        var specimenId = DeterministicGuid($"specimen|{order.OrderId}").ToString();
        var taskId = DeterministicGuid($"task|{order.OrderId}").ToString();
        var labPractitionerId = labOwnerReference.Split('/')[^1];

        var patient = new Patient
        {
            Id = patientId,
            Active = true,
            Identifier =
            [
                // OpenELIS looks for this exact type coding to pick up the MRN.
                new Identifier
                {
                    Type = new CodeableConcept
                    {
                        Coding = [new Coding($"{OeSystem}/genIdType", "externalId")]
                    },
                    Value = order.Patient.ExternalPatientId
                },
                new Identifier($"{OeSystem}/pat_guid", patientId)
            ],
            Name = [new HumanName { Family = order.Patient.LastName, Given = [order.Patient.FirstName] }],
            Gender = order.Patient.Sex switch
            {
                "M" => AdministrativeGender.Male,
                "F" => AdministrativeGender.Female,
                _ => AdministrativeGender.Unknown
            },
            BirthDate = order.Patient.DateOfBirth.ToString("yyyy-MM-dd")
        };

        if (!string.IsNullOrWhiteSpace(order.Patient.NationalId))
            patient.Identifier.Add(new Identifier($"{OeSystem}/pat_nationalId", order.Patient.NationalId));

        if (!string.IsNullOrWhiteSpace(order.Patient.Phone))
            patient.Telecom =
            [
                new ContactPoint(ContactPoint.ContactPointSystem.Phone, ContactPoint.ContactPointUse.Mobile,
                    order.Patient.Phone)
            ];

        var (family, given) = SplitProviderName(order.OrderingProvider);
        var practitioner = new Practitioner
        {
            Id = practitionerId,
            Active = true,
            Identifier = [new Identifier($"{OeSystem}/provider", order.OrderingProvider)],
            Name = [new HumanName { Family = family, Given = [given] }]
        };

        // Represents the receiving laboratory. Published so that OpenELIS can
        // resolve Task.owner if it ever dereferences it.
        var labPractitioner = new Practitioner
        {
            Id = labPractitionerId,
            Active = true,
            Identifier = [new Identifier($"{OeSystem}/lab", "openelis-sandbox")],
            Name = [new HumanName { Family = "Laboratory", Given = ["OpenELIS"] }]
        };

        var specimen = new Specimen
        {
            Id = specimenId,
            Status = Specimen.SpecimenStatus.Available,
            Subject = new ResourceReference($"Patient/{patientId}"),
            // FhirDateTime-backed: the POCO property is a string, not a DateTime.
            ReceivedTime = order.CreatedAt.ToString("o"),
            Type = new CodeableConcept
            {
                Coding = string.IsNullOrWhiteSpace(order.SpecimenSnomed)
                    ? []
                    : [new Coding("http://snomed.info/sct", order.SpecimenSnomed, order.SpecimenType)],
                Text = order.SpecimenType
            }
        };

        var serviceRequest = new ServiceRequest
        {
            Id = serviceRequestId,
            Status = RequestStatus.Active,
            Intent = RequestIntent.Order,
            Priority = MapPriority(order.Priority),
            // OpenELIS reads identifier[0].value as electronic_order.external_id.
            Identifier = [new Identifier(OrderNumberSystem, order.OrderNumber)],
            Code = new CodeableConcept
            {
                Coding = [new Coding(LoincSystem, order.LoincCode, order.TestName)],
                Text = order.TestName
            },
            Subject = new ResourceReference($"Patient/{patientId}"),
            Requester = new ResourceReference($"Practitioner/{practitionerId}"),
            Specimen = [new ResourceReference($"Specimen/{specimenId}")],
            AuthoredOn = order.CreatedAt.ToString("o")
        };

        var task = new FhirTask
        {
            Id = taskId,
            Status = FhirTask.TaskStatus.Requested,
            Intent = FhirTask.TaskIntent.Order,
            Priority = MapPriority(order.Priority),
            Identifier = [new Identifier(OrderNumberSystem, order.OrderNumber)],
            For = new ResourceReference($"Patient/{patientId}"),
            BasedOn = [new ResourceReference($"ServiceRequest/{serviceRequestId}")],
            Owner = new ResourceReference(labOwnerReference),
            Requester = new ResourceReference($"Practitioner/{practitionerId}"),
            AuthoredOn = order.CreatedAt.ToString("o"),
            Description = $"{order.TestName} ({order.TestCode}) for {order.Patient.ExternalPatientId}"
        };

        return new MappedOrder(task, serviceRequest, patient, specimen, practitioner, labPractitioner);
    }

    private static RequestPriority MapPriority(string priority) => priority?.ToLowerInvariant() switch
    {
        "stat" or "urgent" => RequestPriority.Stat,
        "asap" => RequestPriority.Asap,
        _ => RequestPriority.Routine
    };

    private static (string Family, string Given) SplitProviderName(string provider)
    {
        var cleaned = provider.Replace("Dr.", "", StringComparison.OrdinalIgnoreCase).Trim();
        var parts = cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length switch
        {
            0 => ("Unknown", "Provider"),
            1 => (parts[0], "Provider"),
            _ => (parts[^1], string.Join(' ', parts[..^1]))
        };
    }

    /// <summary>
    /// Name-based UUID (RFC 4122 v5, SHA-1) so that reprocessing the same order
    /// produces the same resource ids and OpenELIS sees an update, not a
    /// duplicate order.
    /// </summary>
    public static Guid DeterministicGuid(string name)
    {
        // Fixed namespace for this sandbox.
        var ns = new Guid("6ba7b810-9dad-11d1-80b4-00c04fd430c8").ToByteArray();
        SwapByteOrder(ns);

        var bytes = SHA1.HashData([.. ns, .. Encoding.UTF8.GetBytes(name)]);
        var guid = new byte[16];
        Array.Copy(bytes, guid, 16);

        guid[6] = (byte)((guid[6] & 0x0F) | 0x50);   // version 5
        guid[8] = (byte)((guid[8] & 0x3F) | 0x80);   // RFC 4122 variant

        SwapByteOrder(guid);
        return new Guid(guid);
    }

    private static void SwapByteOrder(byte[] guid)
    {
        (guid[0], guid[3]) = (guid[3], guid[0]);
        (guid[1], guid[2]) = (guid[2], guid[1]);
        (guid[4], guid[5]) = (guid[5], guid[4]);
        (guid[6], guid[7]) = (guid[7], guid[6]);
    }
}

public sealed record MappedOrder(
    FhirTask Task,
    ServiceRequest ServiceRequest,
    Patient Patient,
    Specimen Specimen,
    Practitioner Requester,
    Practitioner LabOwner)
{
    public IReadOnlyList<Resource> All =>
        [Patient, Requester, LabOwner, Specimen, ServiceRequest, Task];
}
