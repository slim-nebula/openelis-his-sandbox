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
///   Task.owner    = the configured lab identity, as an ORGANIZATION (the poll
///                 filters on this too; the type is load-bearing — see below)
///   Task.for      -> Patient
///   Task.basedOn  -> ServiceRequest
///   ServiceRequest.code carries a http://loinc.org coding, which is the ONLY
///                 thing OpenELIS matches a test on
///   ServiceRequest.identifier[0].value becomes the LIS-side external order id
///   ServiceRequest.requester -> Practitioner, the ordering clinician
///
/// Every resource id is a UUID because OpenELIS calls UUID.fromString() on the
/// Practitioner (and stores the others as uuid columns).
/// </summary>
public static class OrderMapper
{
    public const string OeSystem = "http://openelis-global.org";
    public const string LoincSystem = "http://loinc.org";
    public const string OrderNumberSystem = "http://his-sandbox.local/lab-order";

    /// <param name="specimenAbbreviation">
    /// The sample type's local abbreviation in OpenELIS, resolved from the
    /// catalogue, or null when the bridge has never discovered this test.
    ///
    /// Null is NOT the same as wrong. The caller refuses outright when the test
    /// IS on the menu but the abbreviation is missing, because that would bind
    /// the wrong test silently. An undiscovered test reaches here with null and
    /// is sent without the coding, so the LABORATORY decides whether it accepts
    /// it — which is the drift signal the integration is built around, and not
    /// the bridge's call to make.
    /// </param>
    /// <param name="labOwnerName">
    /// What the receiving laboratory is called — normally the hospital's own
    /// name, because the laboratory is a department inside it. See
    /// Options.LabOwnerName.
    /// </param>
    public static MappedOrder Map(HisOrder order, string labOwnerReference, string labOwnerName,
        string? specimenAbbreviation)
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
        var labOwnerId = labOwnerReference.Split('/')[^1];

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

        // The ordering clinician. Who is accountable for the order, and who a
        // critical value is telephoned to — CLIA 42 CFR 493.1291(a) and
        // ISO 15189:2022 7.4.1.6.c both put the name on the LABORATORY's report,
        // so it is not enough for the HIS alone to know it.
        //
        // Reaching the accessioner's screen depends entirely on the resource
        // TYPE of the owner below. LabOrderSearchProvider looks for the
        // requester in two places, in order:
        //
        //   1. task.owner       — but ONLY if the reference contains
        //                         "Practitioner"
        //   2. serviceRequest.requester, and only when 1 found nothing
        //
        // With a Practitioner-typed owner, step 1 always matches the routing
        // identity and step 2 is never reached: every order in the laboratory
        // is attributed to "OpenELIS Laboratory". An Organization-typed owner
        // fails the string test in step 1, which is what lets step 2 run and
        // the real clinician appear. Nothing is patched — this is the upstream
        // code path working as written, and it is why the owner is an
        // Organization and not a Practitioner.
        var orderingClinician = BuildOrderingClinician(order);

        // Represents the receiving laboratory, and this one DOES have to exist:
        // Task.owner is how OpenELIS finds orders addressed to it
        // (Task.OWNER.hasAnyOfIds(remoteStoreIdentifier)), so it is a routing
        // address, not a person — which is the substantive reason to type it as
        // an Organization quite apart from the requester it unblocks.
        //
        // FhirConfig.getRemoteStoreIdentifier() passes the value through
        // verbatim unless it is the literal "Practitioner/*", and the importer
        // never dereferences the owner, so no lookup depends on the type. The
        // uuid must be a real row in OpenELIS's own `organization` table
        // (organization.fhir_uuid), so that the one place OpenELIS DOES emit
        // this reference — FhirReferralServiceImpl putting it on
        // Task.restriction.recipient for an outbound referral — names something
        // that exists.
        //
        // The NAME comes from configuration because it is different at every
        // site: a laboratory is normally a department inside a hospital, so it
        // is called after the hospital. OpenELIS holds the authoritative copy in
        // that same organization row; this one is ours, and the two are meant to
        // agree.
        var labOwner = new Organization
        {
            Id = labOwnerId,
            Active = true,
            Identifier = [new Identifier($"{OeSystem}/lab", labOwnerId)],
            Name = labOwnerName
        };

        var specimen = new Specimen
        {
            Id = specimenId,
            Status = Specimen.SpecimenStatus.Available,
            Subject = new ResourceReference($"Patient/{patientId}"),
            // ReceivedTime is NOT set.
            //
            // It used to carry order.CreatedAt, which told the laboratory it had
            // received a specimen at the moment the doctor clicked "order" —
            // before anyone had drawn blood. Receipt is an event the LABORATORY
            // observes, in its own building, and asserting it from here was a
            // false statement in a clinical record about someone else's premises.
            //
            // The collection time below is different: for an inpatient the ward
            // genuinely observed the draw, and is the only party that could.
            // THE CODING OPENELIS ACTUALLY READS comes first.
            //
            // LabOrderSearchProvider walks Specimen.type.coding looking for one
            // whose system is exactly "<oeFhirSystem>/sampleType", takes its
            // CODE, and resolves it with getTypeOfSampleIdForLocalAbbreviation -
            // an exact match on type_of_sample.local_abbrev. Nothing else in the
            // resource is consulted: not Text, not the SNOMED coding, not the id.
            //
            // Miss it and OpenELIS logs a warning, then binds alltests.get(0) -
            // the first active test for the LOINC. For a multi-specimen code that
            // is the wrong bench, with no error surfaced to either system.
            //
            // SNOMED stays for everyone else. It is the interoperable statement
            // of what the specimen is; the abbreviation is a local key that means
            // nothing outside this installation, which is why it cannot replace it.
            Type = new CodeableConcept
            {
                Coding = BuildSpecimenCodings(order, specimenAbbreviation),
                Text = order.SpecimenType
            },
            Collection = BuildCollection(order)
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
            AuthoredOn = order.CreatedAt.ToString("o"),
            // Null when the HIS did not record an identified clinician. Absent
            // is the honest statement there; a reference to a Practitioner we
            // invented would read as a verified attribution.
            Requester = orderingClinician is null
                ? null
                : new ResourceReference($"Practitioner/{orderingClinician.Id}")
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

        return new MappedOrder(task, serviceRequest, patient, specimen, labOwner, orderingClinician);
    }

    /// <summary>
    /// The doctor who placed the order, as a Practitioner OpenELIS can resolve.
    ///
    /// Keyed on lab_orders.ordering_provider_id — the usr_id from the verified
    /// token — and never on the name. A name-derived identity makes "Dr Konate",
    /// "Dr Konaté" and "dr konate" three different clinicians in the
    /// laboratory's own provider records, which is the defect db/his/008 exists
    /// to close; deriving the FHIR id from the name here would reopen it one
    /// layer further out.
    ///
    /// The id MUST be a uuid. LabOrderSearchProvider.addRequester calls
    /// UUID.fromString() on it unguarded, so a raw usr_id like "42" throws
    /// IllegalArgumentException inside the accessioning wizard - a 500 on the
    /// laboratory's screen, not a missing field. DeterministicGuid gives the
    /// same uuid for the same clinician on every order, which is also what lets
    /// OpenELIS match an existing local Practitioner instead of accumulating a
    /// duplicate per order.
    ///
    /// Returns null when the HIS has no identified clinician: historical rows
    /// predating db/his/008 carry a NULL ordering_provider_id, and an order with
    /// no verified orderer must not acquire one in transit.
    /// </summary>
    private static Practitioner? BuildOrderingClinician(HisOrder order)
    {
        if (string.IsNullOrWhiteSpace(order.OrderingProviderId)) return null;
        if (string.IsNullOrWhiteSpace(order.OrderingProvider)) return null;

        var (given, family) = SplitName(order.OrderingProvider);
        var name = new HumanName { Family = family };
        if (given is not null) name.Given = [given];

        return new Practitioner
        {
            Id = DeterministicGuid($"practitioner|{order.OrderingProviderId}").ToString(),
            Active = true,
            // The stable key, carried so the laboratory can reconcile against
            // the HIS by something better than a spelling.
            Identifier = [new Identifier($"{OeSystem}/provider_id", order.OrderingProviderId)],
            Name = [name]
        };
    }

    /// <summary>
    /// Splits a display name into given and family for a system that reads them
    /// separately (getGivenAsSingleString / getFamily).
    ///
    /// Last whitespace-separated token is the family name, the rest is given.
    /// Crude, and deliberately so: the HIS stores one display string, and any
    /// cleverer rule would be a guess about naming conventions this sandbox has
    /// no business making. A single-token name becomes the family name alone,
    /// because that is the field OpenELIS requires and shows.
    ///
    /// NOT sanitised. OpenELIS validates provider names against the site's
    /// configured lastNameCharset - by default letters, space, apostrophe, dot
    /// and hyphen, with NO DIGITS - and rejects anything else when the
    /// accessioner saves. Stripping characters here to slip past that would
    /// alter a clinician's identity in a clinical record to avoid an error
    /// message; the laboratory refusing a malformed name is the correct
    /// outcome, and the fix belongs in the HIS that holds it.
    /// </summary>
    private static (string? Given, string Family) SplitName(string displayName)
    {
        var parts = displayName.Split(' ', StringSplitOptions.RemoveEmptyEntries
                                          | StringSplitOptions.TrimEntries);

        return parts.Length <= 1
            ? (null, parts.Length == 1 ? parts[0] : displayName.Trim())
            : (string.Join(' ', parts[..^1]), parts[^1]);
    }

    /// <summary>
    /// Specimen.type.coding, most specific first.
    ///
    /// The OpenELIS coding carries the sample type's LOCAL ABBREVIATION and is
    /// the only one OpenELIS reads (LabOrderSearchProvider walks the codings for
    /// system "<OeSystem>/sampleType" and resolves its code against
    /// type_of_sample.local_abbrev). SNOMED is for every other reader; it is
    /// interoperable where the abbreviation is meaningless outside this
    /// installation, so neither substitutes for the other.
    ///
    /// With no abbreviation we emit no OpenELIS coding at all rather than guess.
    /// A wrong code binds the wrong test confidently; an absent one leaves the
    /// decision with the laboratory.
    /// </summary>
    private static List<Coding> BuildSpecimenCodings(HisOrder order, string? specimenAbbreviation)
    {
        var codings = new List<Coding>();

        if (!string.IsNullOrWhiteSpace(specimenAbbreviation))
        {
            codings.Add(new Coding($"{OeSystem}/sampleType", specimenAbbreviation, order.SpecimenType));
        }

        if (!string.IsNullOrWhiteSpace(order.SpecimenSnomed))
        {
            codings.Add(new Coding("http://snomed.info/sct", order.SpecimenSnomed, order.SpecimenType));
        }

        return codings;
    }

    /// <summary>
    /// The bedside draw, when the ward observed one.
    ///
    /// OpenELIS reads this on import - LabOrderSearchProvider.addCollection
    /// takes Specimen.collection.collectedDateTime through to the accessioner's
    /// screen, pre-filled, and on to sample_item.collection_date. Unlike
    /// ServiceRequest.encounter, which is dropped, this one genuinely survives.
    ///
    /// Returns null rather than an empty Collection when there is no time. An
    /// outpatient specimen is drawn in the laboratory and its collection is the
    /// laboratory's to record; sending an empty element would suggest we had
    /// something to say about it and lost it.
    /// </summary>
    private static Specimen.CollectionComponent? BuildCollection(HisOrder order)
    {
        if (order.CollectedAt is not { } collected) return null;

        return new Specimen.CollectionComponent
        {
            Collected = new FhirDateTime(collected)
        };
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
    Organization LabOwner,
    Practitioner? OrderingClinician)
{
    /// <summary>
    /// Publication order matters: OpenELIS dereferences ServiceRequest.requester
    /// while importing, so the Practitioner has to be readable before the
    /// ServiceRequest that points at it is visible to a poll.
    /// </summary>
    public IReadOnlyList<Resource> All => OrderingClinician is null
        ? [Patient, LabOwner, Specimen, ServiceRequest, Task]
        : [Patient, LabOwner, OrderingClinician, Specimen, ServiceRequest, Task];
}
