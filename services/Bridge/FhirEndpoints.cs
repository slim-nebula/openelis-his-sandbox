using System.Text;
using Hl7.Fhir.Model;
using FhirTask = Hl7.Fhir.Model.Task;
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// The bridge's FHIR R4 surface. This is the whole contract with OpenELIS:
///
///   GET  /fhir/metadata                      HAPI validates the version here first
///   GET  /fhir/Task?status=&amp;owner=           the order poll
///   GET  /fhir/{type}/{id}                   dereferencing Task.for / basedOn / requester
///   GET  /fhir/{type}?...                    QuestionnaireResponse lookups (empty is fine)
///   PUT  /fhir/Task/{id}                     OpenELIS writing back accepted / rejected
///   POST /fhir  |  POST/PUT /fhir/{type}     released results pushed back to us
/// </summary>
public static class FhirEndpoints
{
    private const string FhirJson = "application/fhir+json";

    /// <summary>
    /// What we will accept a push of, and what the capability statement declares.
    ///
    /// This list must stay a SUPERSET of
    /// org.openelisglobal.fhir.subscriber.resources in common.properties.
    /// OpenELIS registers one Subscription per name there and pushes to us
    /// unconditionally; a type missing here is refused at the door, which shows
    /// up as a permanently failing export on the laboratory's side rather than
    /// as anything visible on ours. Adding a name to that property without
    /// adding it here is strictly worse than not subscribing at all.
    ///
    /// Organization is here for referral (send-out) testing: it names the
    /// laboratory a specimen was sent to. Nothing reads it yet - no referral has
    /// ever run in this system - but it must be subscribed and accepted BEFORE
    /// the first send-out, because resources are pushed when they change and a
    /// reference laboratory configured earlier is not re-pushed just because we
    /// started listening.
    /// </summary>
    private static readonly string[] SupportedTypes =
    [
        "Task", "ServiceRequest", "Patient", "Specimen", "Practitioner",
        "Observation", "DiagnosticReport", "QuestionnaireResponse", "Location", "Encounter",
        "Organization"
    ];

    public static void MapFhirEndpoints(this WebApplication app)
    {
        // --- Capability statement ------------------------------------------
        app.MapGet("/fhir/metadata", (HttpContext ctx) =>
        {
            var capability = new CapabilityStatement
            {
                Id = "bridge-fhir",
                Status = PublicationStatus.Active,
                Date = DateTimeOffset.UtcNow.ToString("o"),
                Kind = CapabilityStatementKind.Instance,
                FhirVersion = FHIRVersion.N4_0_1,
                Format = ["application/fhir+json", "json"],
                Publisher = "HIS Sandbox Bridge",
                Software = new CapabilityStatement.SoftwareComponent
                {
                    Name = "his-openelis-bridge",
                    Version = "1.0.0"
                },
                Rest =
                [
                    new CapabilityStatement.RestComponent
                    {
                        Mode = CapabilityStatement.RestfulCapabilityMode.Server,
                        Resource = [.. SupportedTypes.Select(type =>
                            new CapabilityStatement.ResourceComponent
                            {
                                Type = type,
                                Interaction =
                                [
                                    new CapabilityStatement.ResourceInteractionComponent
                                        { Code = CapabilityStatement.TypeRestfulInteraction.Read },
                                    new CapabilityStatement.ResourceInteractionComponent
                                        { Code = CapabilityStatement.TypeRestfulInteraction.SearchType },
                                    new CapabilityStatement.ResourceInteractionComponent
                                        { Code = CapabilityStatement.TypeRestfulInteraction.Update },
                                    new CapabilityStatement.ResourceInteractionComponent
                                        { Code = CapabilityStatement.TypeRestfulInteraction.Create }
                                ]
                            })
                        ]
                    }
                ]
            };

            return FhirResult(capability);
        });

        // --- Search ---------------------------------------------------------
        app.MapGet("/fhir/{type}", async (
            string type, HttpContext ctx, BridgeStore store, BridgeOptions options,
            ILoggerFactory loggerFactory, CancellationToken ct) =>
        {
            var log = loggerFactory.CreateLogger("FhirSearch");
            var baseUrl = BaseUrl(ctx);

            // _count is honoured but never trusted: a client asking for more
            // than the server is willing to serialise gets the server's answer.
            var limit = int.TryParse(ctx.Request.Query["_count"].FirstOrDefault(), out var requested)
                ? Math.Clamp(requested, 1, options.MaxSearchResults)
                : options.MaxSearchResults;

            if (type == "Task")
            {
                var status = ctx.Request.Query["status"].FirstOrDefault();
                var owner = ctx.Request.Query["owner"].FirstOrDefault();
                var id = ctx.Request.Query["_id"].FirstOrDefault();

                var tasks = await store.SearchTasksAsync(status, owner, id, limit, ct);
                var total = tasks.Count < limit
                    ? tasks.Count                                      // a short page is the whole set
                    : await store.CountTasksAsync(status, owner, id, ct);

                if (total > tasks.Count)
                    log.LogInformation(
                        "Task search truncated to {Returned} of {Total}; the rest follow on later polls",
                        tasks.Count, total);

                log.LogInformation("Task search status={Status} owner={Owner} -> {Count} match(es)",
                    status, owner, tasks.Count);
                return FhirResult(SearchBundle(tasks, baseUrl, total));
            }

            // Everything else: OpenELIS only ever searches QuestionnaireResponse
            // by based-on, and the sandbox never produces any. An empty
            // searchset is the correct answer, not an error.
            if (ctx.Request.Query.Count > 0 && type != "Patient")
                return FhirResult(SearchBundle([], baseUrl));

            var all = await store.SearchByTypeAsync(type, limit, ct);
            return FhirResult(SearchBundle(all, baseUrl));
        });

        // --- Read -----------------------------------------------------------
        app.MapGet("/fhir/{type}/{id}", async (
            string type, string id, BridgeStore store, CancellationToken ct) =>
        {
            var resource = await store.GetResourceAsync(type, id, ct);
            if (resource is not null) return FhirResult(resource);

            // Fall back to the inbound mirror so OpenELIS can re-read anything
            // it previously pushed to us.
            var received = await store.GetReceivedAsync<Resource>(type, id, ct);
            return received is not null
                ? FhirResult(received)
                : FhirResult(NotFoundOutcome($"{type}/{id}"), StatusCodes.Status404NotFound);
        });

        // --- Update ---------------------------------------------------------
        // Two very different callers land here:
        //   * OpenELIS accepting or rejecting an order we published
        //   * OpenELIS delivering a changed resource via its rest-hook subscription
        // The task-tracking table tells them apart.
        app.MapPut("/fhir/{type}/{id}", async (
            string type, string id, HttpContext ctx, BridgeStore store, BridgeOptions options,
            EventPublisher publisher, ILoggerFactory loggerFactory, CancellationToken ct) =>
        {
            var log = loggerFactory.CreateLogger("FhirUpdate");
            var resource = await ReadResourceAsync(ctx, store, log);
            if (resource is null)
                return FhirResult(ErrorOutcome("Unparseable resource"), StatusCodes.Status400BadRequest);

            resource.Id ??= id;

            if (type == "Task" && await store.GetTrackedByTaskAsync(id, ct) is { } tracked)
            {
                var task = (FhirTask)resource;
                var status = task.Status?.ToString().ToLowerInvariant() ?? "unknown";

                await store.PutResourceAsync(resource, ct);
                await store.SetTaskStatusAsync(id, status, ct);

                // The LIS has given its verdict, so the delivery is over. The
                // Task leaves `requested` at the same moment and the poll would
                // stop matching it anyway — this keeps the lease table to live
                // orders rather than every order ever placed.
                await store.ReleaseDeliveryLeaseAsync(id, ct);

                // The reason is read off the Task when OpenELIS supplies one, and
                // is otherwise left unstated.
                //
                // This used to say "most often no test matches the LOINC code",
                // which was a guess presented to a clinician as a fact — and the
                // first clean rebuild of this stack proved it a wrong one. That
                // rejection came from a Hibernate Search indexing failure inside
                // OpenELIS (docs/catalogue-discovery-plan.md, defect 0). The
                // laboratory had not declined anything, and the LOINC was fine.
                //
                // A rejection with no reason is worth surfacing AS having no
                // reason. It sends whoever reads it to the laboratory, which is
                // where the answer is; the old wording sent them to the catalogue,
                // which is where it was not.
                var reason = task.StatusReason?.Text
                             ?? task.StatusReason?.Coding?.FirstOrDefault()?.Display;

                var (hisStatus, detail) = status switch
                {
                    "accepted" => ("ACCEPTED_BY_LIS", "OpenELIS accepted the electronic order"),
                    "rejected" => ("REJECTED_BY_LIS", string.IsNullOrWhiteSpace(reason)
                        ? "OpenELIS rejected the order and gave no reason. Check the order in " +
                          "OpenELIS and its log before assuming a catalogue mismatch."
                        : $"OpenELIS rejected the order: {reason}"),
                    "received" => ("SENT_TO_LIS", "OpenELIS received the order"),
                    _ => ("SENT_TO_LIS", $"OpenELIS set task status to {status}")
                };

                log.LogInformation("OpenELIS set Task {TaskId} to {Status} for order {OrderNumber}",
                    id, status, tracked.OrderNumber);

                var topic = hisStatus == "REJECTED_BY_LIS" ? options.TopicOrderFailed : options.TopicOrderSent;
                await publisher.PublishAsync(topic, tracked.OrderNumber, new
                {
                    eventId = Guid.NewGuid().ToString(),
                    correlationId = tracked.CorrelationId,
                    orderId = tracked.OrderId,
                    orderNumber = tracked.OrderNumber,
                    status = hisStatus,
                    detail
                }, tracked.CorrelationId ?? Guid.NewGuid().ToString(), ct);

                return FhirResult(resource);
            }

            await store.StoreReceivedAsync(resource, ct);
            log.LogInformation("Received {Type}/{Id} from OpenELIS (update)", type, resource.Id);
            return FhirResult(resource);
        });

        // --- Create ---------------------------------------------------------
        app.MapPost("/fhir/{type}", async (
            string type, HttpContext ctx, BridgeStore store,
            ILoggerFactory loggerFactory, CancellationToken ct) =>
        {
            var log = loggerFactory.CreateLogger("FhirCreate");
            var resource = await ReadResourceAsync(ctx, store, log);
            if (resource is null)
                return FhirResult(ErrorOutcome("Unparseable resource"), StatusCodes.Status400BadRequest);

            resource.Id ??= Guid.NewGuid().ToString();
            await store.StoreReceivedAsync(resource, ct);
            log.LogInformation("Received {Type}/{Id} from OpenELIS (create)", type, resource.Id);
            return FhirResult(resource, StatusCodes.Status201Created);
        });

        // --- Transaction / batch bundle ------------------------------------
        // This is how the periodic data export pushes a batch of released
        // results in one call.
        app.MapPost("/fhir", async (
            HttpContext ctx, BridgeStore store, ILoggerFactory loggerFactory, CancellationToken ct) =>
        {
            var log = loggerFactory.CreateLogger("FhirTransaction");
            var resource = await ReadResourceAsync(ctx, store, log);
            if (resource is null)
                return FhirResult(ErrorOutcome("Unparseable payload"), StatusCodes.Status400BadRequest);

            if (resource is not Bundle bundle)
            {
                resource.Id ??= Guid.NewGuid().ToString();
                await store.StoreReceivedAsync(resource, ct);
                return FhirResult(resource);
            }

            var response = new Bundle { Type = Bundle.BundleType.TransactionResponse };
            var stored = 0;

            foreach (var entry in bundle.Entry.Where(e => e.Resource is not null))
            {
                var item = entry.Resource;
                item.Id ??= Guid.NewGuid().ToString();
                await store.StoreReceivedAsync(item, ct);
                stored++;

                response.Entry.Add(new Bundle.EntryComponent
                {
                    Response = new Bundle.ResponseComponent
                    {
                        Status = "200 OK",
                        Location = $"{item.TypeName}/{item.Id}"
                    }
                });
            }

            log.LogInformation("Received bundle from OpenELIS with {Count} resource(s)", stored);
            return FhirResult(response);
        });
    }

    // --- Helpers ------------------------------------------------------------

    private static async Task<Resource?> ReadResourceAsync(HttpContext ctx, BridgeStore store, ILogger log)
    {
        using var reader = new StreamReader(ctx.Request.Body, Encoding.UTF8);
        var body = await reader.ReadToEndAsync();
        if (string.IsNullOrWhiteSpace(body)) return null;

        try { return BridgeStore.ParseResource(body); }
        catch (Exception ex)
        {
            log.LogWarning(ex, "Could not parse FHIR payload: {Snippet}",
                body[..Math.Min(400, body.Length)]);
            return null;
        }
    }

    /// <summary>
    /// <paramref name="total"/> is the number of matches, which is not the same
    /// as the number of entries once a page is capped. Reporting the page size
    /// as the total would tell a truncated caller it had seen everything.
    /// </summary>
    private static Bundle SearchBundle(IReadOnlyList<Resource> resources, string baseUrl, int? total = null)
    {
        var bundle = new Bundle
        {
            Id = Guid.NewGuid().ToString(),
            Type = Bundle.BundleType.Searchset,
            Total = total ?? resources.Count,
            Meta = new Meta { LastUpdated = DateTimeOffset.UtcNow }
        };

        foreach (var resource in resources)
        {
            bundle.Entry.Add(new Bundle.EntryComponent
            {
                FullUrl = $"{baseUrl}/{resource.TypeName}/{resource.Id}",
                Resource = resource,
                Search = new Bundle.SearchComponent { Mode = Bundle.SearchEntryMode.Match }
            });
        }

        return bundle;
    }

    private static string BaseUrl(HttpContext ctx) =>
        $"{ctx.Request.Scheme}://{ctx.Request.Host}/fhir";

    private static OperationOutcome NotFoundOutcome(string what) => new()
    {
        Issue =
        [
            new OperationOutcome.IssueComponent
            {
                Severity = OperationOutcome.IssueSeverity.Error,
                Code = OperationOutcome.IssueType.NotFound,
                Diagnostics = $"{what} not found"
            }
        ]
    };

    private static OperationOutcome ErrorOutcome(string message) => new()
    {
        Issue =
        [
            new OperationOutcome.IssueComponent
            {
                Severity = OperationOutcome.IssueSeverity.Error,
                Code = OperationOutcome.IssueType.Invalid,
                Diagnostics = message
            }
        ]
    };

    private static IResult FhirResult(Resource resource, int statusCode = StatusCodes.Status200OK) =>
        Results.Text(BridgeStore.ToJson(resource), FhirJson, Encoding.UTF8, statusCode);
}
