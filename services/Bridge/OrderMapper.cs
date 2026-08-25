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

        // The ServiceRequest id must be the ORDER NUMBER, not the order UUID.
        // OpenELIS's Incoming Orders view reads
        //     ServiceRequest/{electronic_order.external_id}
        // straight out of its local FHIR store (RestElectronicOrdersController),
        // and external_id is whatever we put in ServiceRequest.identifier[0].
        // With a UUID id that read 404s, and the lab user sees
        // "error in data collection - FHIR resource not found" with no test
        // name on every order we send. Order import still worked, because that
        // path follows Task.basedOn references instead — which is exactly why
        // this stayed invisible from the integration's side.
        //
        // Order numbers are unique, <= 60 chars, and match the FHIR id
        // grammar [A-Za-z0-9-.]{1,64}.
        var serviceRequestId = order.OrderNumber;
        var specimenId = DeterministicGuid($"specimen|{order.OrderId}").ToString();
        var taskId = DeterministicGuid($"task|{order.OrderId}").ToString();
        var labPractitionerId = labOwnerReference.Split('/')[^1];

        var patient = new Patient
        {
            Id = patientId,
            Active = true,
            // The HIS patient id, and the national id when there is one. The
            // file number is deliberately NOT sent: the HIS owns the patient
            // record and resolves it from this id, and OpenELIS discards it
            // anyway — its inbound mapper matches identifiers by `system`, and
            // the file number's only carrier was a type coding with no system.
            Identifier = [new Identifier($"{OeSystem}/pat_guid", patientId)],
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

        // The ordering clinician is NOT published.
        //
        // The HIS records who ordered every test — lab_orders.ordering_provider
        // and ordering_provider_id, taken from the verified token — and that is
        // where accountability lives. It simply does not travel to the
        // laboratory, because the laboratory does not act on it: the analysis is
        // driven by the test and the specimen, and a critical value is phoned
        // back to the HIS, which knows the doctor.
        //
        // Not sending it also removes any dependence on upstream defect 2, where
        // OpenELIS reads the requester from Task.owner — the routing address —
        // and so can never show the ordering doctor anyway.

        // Represents the receiving laboratory, and this one DOES have to exist:
        // Task.owner is how OpenELIS finds orders addressed to it
        // (Task.OWNER.hasAnyOfIds(remoteStoreIdentifier)), so it is a routing
        // address, not a person.
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
            // Populates "referring lab number" in the Incoming Orders view.
            Requisition = new Identifier(OrderNumberSystem, order.OrderNumber),
            Code = new CodeableConcept
            {
                Coding = [new Coding(LoincSystem, order.LoincCode, order.TestName)],
                Text = order.TestName
            },
            Subject = new ResourceReference($"Patient/{patientId}"),
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
            AuthoredOn = order.CreatedAt.ToString("o"),
            Description = $"{order.TestName} ({order.TestCode}) — order {order.OrderNumber}"
        };

        return new MappedOrder(task, serviceRequest, patient, specimen, labPractitioner);
    }

    private static RequestPriority MapPriority(string priority) => priority?.ToLowerInvariant() switch
    {
        "stat" or "urgent" => RequestPriority.Stat,
        "asap" => RequestPriority.Asap,
        _ => RequestPriority.Routine
    };

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
    Practitioner LabOwner)
{
    public IReadOnlyList<Resource> All =>
        [Patient, LabOwner, Specimen, ServiceRequest, Task];
}
