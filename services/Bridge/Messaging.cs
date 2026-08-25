using System.Text;
using System.Text.Json;
using Confluent.Kafka;

namespace Bridge;

/// <summary>Publishes the bridge's lifecycle and result events.</summary>
public sealed class EventPublisher : IDisposable
{
    private readonly IProducer<string, string> _producer;
    private readonly ILogger<EventPublisher> _log;

    public EventPublisher(BridgeOptions options, ILogger<EventPublisher> log)
    {
        _log = log;
        _producer = new ProducerBuilder<string, string>(new ProducerConfig
        {
            BootstrapServers = options.KafkaBootstrap,
            Acks = Acks.All,
            EnableIdempotence = true,
            MessageSendMaxRetries = 5,
            LingerMs = 5,
            MessageTimeoutMs = 8000,
            SocketTimeoutMs = 6000
        }).Build();
    }

    public async Task PublishAsync<T>(string topic, string key, T payload, string correlationId, CancellationToken ct)
    {
        var result = await _producer.ProduceAsync(topic, new Message<string, string>
        {
            Key = key,
            Value = JsonSerializer.Serialize(payload),
            Headers = [new Header("X-Correlation-ID", Encoding.UTF8.GetBytes(correlationId))]
        }, ct);

        _log.LogInformation("Published {Topic} key={Key} offset={Offset} correlation={CorrelationId}",
            topic, key, result.Offset.Value, correlationId);
    }

    public void Dispose()
    {
        _producer.Flush(TimeSpan.FromSeconds(5));
        _producer.Dispose();
    }
}

/// <summary>
/// Consumes lab.order.created, fetches the full order from the HIS service,
/// maps it to FHIR and publishes it for OpenELIS to poll.
///
/// Duplicate deliveries are absorbed by a claim on the event key, and the
/// resource ids are derived deterministically from the order id, so even a
/// replayed event produces an update rather than a second order.
/// </summary>
public sealed class OrderConsumer(
    BridgeOptions options,
    IServiceScopeFactory scopeFactory,
    IHttpClientFactory httpClientFactory,
    EventPublisher publisher,
    ILogger<OrderConsumer> log) : BackgroundService
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    protected override Task ExecuteAsync(CancellationToken stoppingToken) =>
        Task.Run(() => ConsumeLoop(stoppingToken), stoppingToken);

    private async Task ConsumeLoop(CancellationToken ct)
    {
        using var consumer = new ConsumerBuilder<string, string>(new ConsumerConfig
        {
            BootstrapServers = options.KafkaBootstrap,
            GroupId = options.ConsumerGroup,
            AutoOffsetReset = AutoOffsetReset.Earliest,
            EnableAutoCommit = false,
            SessionTimeoutMs = 30000
        })
        .SetErrorHandler((_, e) => log.LogWarning("Kafka error: {Reason}", e.Reason))
        .Build();

        consumer.Subscribe(options.TopicOrderCreated);
        log.LogInformation("Bridge consuming {Topic} from {Bootstrap}",
            options.TopicOrderCreated, options.KafkaBootstrap);

        while (!ct.IsCancellationRequested)
        {
            ConsumeResult<string, string>? cr = null;
            try
            {
                cr = consumer.Consume(TimeSpan.FromSeconds(1));
                if (cr is null) continue;

                await HandleAsync(cr, ct);
                consumer.Commit(cr);
            }
            catch (OperationCanceledException) { break; }
            catch (JsonException ex) when (cr is not null)
            {
                // Unparseable now means unparseable forever. Record it and
                // commit past it, or it blocks every order behind it on this
                // partition.
                log.LogError(ex, "Poison message on {Topic} at offset {Offset}; dead-lettering",
                    cr.Topic, cr.Offset.Value);
                using (var scope = scopeFactory.CreateScope())
                {
                    var store = scope.ServiceProvider.GetRequiredService<BridgeStore>();
                    await store.DeadLetterAsync(cr.Topic,
                        $"Unparseable lab.order.created payload at offset {cr.Offset.Value}: {ex.Message}",
                        null, null, ct);
                }
                consumer.Commit(cr);
            }
            catch (Exception ex)
            {
                log.LogError(ex, "Order event handling failed; offset left uncommitted for redelivery");
                if (cr is not null) await Task.Delay(TimeSpan.FromSeconds(options.RetryBaseDelaySeconds), ct);
            }
        }

        consumer.Close();
    }

    private async Task HandleAsync(ConsumeResult<string, string> cr, CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var store = scope.ServiceProvider.GetRequiredService<BridgeStore>();

        var evt = JsonSerializer.Deserialize<OrderCreatedEvent>(cr.Message.Value, Json)
            ?? throw new JsonException("Empty lab.order.created payload");

        var correlationId = evt.CorrelationId
            ?? (cr.Message.Headers.TryGetLastBytes("X-Correlation-ID", out var b)
                ? Encoding.UTF8.GetString(b)
                : Guid.NewGuid().ToString());

        var eventKey = evt.EventId ?? $"{cr.Topic}:{cr.Partition.Value}:{cr.Offset.Value}";
        if (!await store.TryClaimEventAsync(eventKey, "lab.order.created", ct))
        {
            log.LogInformation("Duplicate lab.order.created {EventKey} ignored", eventKey);
            return;
        }

        try
        {
            await ProcessOrderAsync(store, evt, correlationId, ct);
        }
        catch (Exception)
        {
            // Release the claim so redelivery can genuinely retry rather than
            // being swallowed as a duplicate.
            await store.ReleaseEventClaimAsync(eventKey, ct);
            throw;
        }
    }

    private async Task ProcessOrderAsync(
        BridgeStore store, OrderCreatedEvent evt, string correlationId, CancellationToken ct)
    {
        HisOrder order;
        try
        {
            order = await FetchOrderWithRetryAsync(evt.OrderId, correlationId, ct);
        }
        catch (Exception ex)
        {
            await store.DeadLetterAsync(options.TopicOrderCreated,
                $"Could not fetch order {evt.OrderId} from HIS: {ex.Message}",
                JsonSerializer.Serialize(evt), correlationId, ct);
            await publisher.PublishAsync(options.TopicOrderFailed, evt.OrderNumber, new
            {
                eventId = Guid.NewGuid().ToString(),
                correlationId,
                orderId = evt.OrderId,
                orderNumber = evt.OrderNumber,
                status = "FAILED",
                detail = $"Bridge could not load order context: {ex.Message}"
            }, correlationId, ct);
            return;
        }

        if (string.IsNullOrWhiteSpace(order.LoincCode))
        {
            const string reason = "Order has no LOINC mapping; OpenELIS cannot resolve a test.";
            await store.DeadLetterAsync(options.TopicOrderCreated, reason,
                JsonSerializer.Serialize(evt), correlationId, ct);
            await publisher.PublishAsync(options.TopicOrderFailed, order.OrderNumber, new
            {
                eventId = Guid.NewGuid().ToString(),
                correlationId,
                orderId = order.OrderId,
                orderNumber = order.OrderNumber,
                status = "FAILED",
                detail = reason
            }, correlationId, ct);
            return;
        }

        // Resolve the specimen the way OpenELIS will, before sending anything.
        //
        // Two different situations, and collapsing them is a mistake worth
        // spelling out, because the first version of this did:
        //
        //   on the menu, no abbreviation  -> REFUSE. We would send a specimen
        //       OpenELIS cannot resolve, and it does not error: it binds the
        //       first test matching the LOINC. A plasma order goes to the serum
        //       bench with nothing logged on either side. This is a stale
        //       catalogue and the fix is a re-sync, so say so.
        //
        //   not on the menu at all        -> SEND IT. The bridge never
        //       discovered this test, so it has no opinion about it, and the
        //       laboratory is the authority on what it accepts. OpenELIS will
        //       reject a LOINC it does not carry, and that rejection travelling
        //       back is the drift signal the integration is built on. Refusing
        //       here would substitute our judgement for the lab's and silently
        //       delete the whole rejection path.
        var catalogue = await store.GetCatalogueAsync(ct);
        var offering = catalogue.FirstOrDefault(
            e => e.Loinc == order.LoincCode
                 && string.Equals(e.SpecimenName, order.SpecimenType, StringComparison.Ordinal));

        if (offering is not null && string.IsNullOrWhiteSpace(offering.SpecimenAbbreviation))
        {
            var reason = $"Catalogue offers LOINC {order.LoincCode} on specimen "
                       + $"'{order.SpecimenType}' but holds no sample-type abbreviation for it. "
                       + "OpenELIS would bind the first test matching the code rather than the "
                       + "one ordered. Re-run the catalogue sync.";
            await store.DeadLetterAsync(options.TopicOrderCreated, reason,
                JsonSerializer.Serialize(evt), correlationId, ct);
            await publisher.PublishAsync(options.TopicOrderFailed, order.OrderNumber, new
            {
                eventId = Guid.NewGuid().ToString(),
                correlationId,
                orderId = order.OrderId,
                orderNumber = order.OrderNumber,
                status = "FAILED",
                detail = reason
            }, correlationId, ct);
            return;
        }

        if (offering is null)
        {
            log.LogWarning(
                "Order {OrderNumber} is for LOINC {Loinc} on '{Specimen}', which is not in the "
                + "discovered catalogue. Sending without a sample-type coding and letting the "
                + "laboratory decide.",
                order.OrderNumber, order.LoincCode, order.SpecimenType);
        }

        var mapped = OrderMapper.Map(order, options.LabOwnerReference, offering?.SpecimenAbbreviation);

        await store.SaveOrderAsync(new TrackedOrder(
            order.OrderId, order.OrderNumber, order.Patient.PatientId, order.TestCode, order.LoincCode,
            mapped.Task.Id!, mapped.ServiceRequest.Id!, mapped.Patient.Id!, mapped.Specimen.Id!,
            "requested", 0, correlationId), mapped.All, ct);

        log.LogInformation(
            "Published FHIR Task {TaskId} for order {OrderNumber} (LOINC {Loinc}); awaiting OpenELIS poll",
            mapped.Task.Id, order.OrderNumber, order.LoincCode);

        await publisher.PublishAsync(options.TopicOrderSent, order.OrderNumber, new
        {
            eventId = Guid.NewGuid().ToString(),
            correlationId,
            orderId = order.OrderId,
            orderNumber = order.OrderNumber,
            status = "SENT_TO_LIS",
            detail = $"FHIR Task {mapped.Task.Id} published for OpenELIS"
        }, correlationId, ct);
    }

    private async Task<HisOrder> FetchOrderWithRetryAsync(Guid orderId, string correlationId, CancellationToken ct)
    {
        var client = httpClientFactory.CreateClient("his-api");
        Exception? last = null;

        for (var attempt = 1; attempt <= options.MaxRetries; attempt++)
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, $"/internal/lab-orders/{orderId}");
                request.Headers.Add("X-Correlation-ID", correlationId);

                using var response = await client.SendAsync(request, ct);
                response.EnsureSuccessStatusCode();

                return await response.Content.ReadFromJsonAsync<HisOrder>(Json, ct)
                    ?? throw new InvalidOperationException("Empty order payload");
            }
            catch (Exception ex) when (attempt < options.MaxRetries)
            {
                last = ex;
                // Exponential backoff: the HIS service may still be starting.
                var delay = TimeSpan.FromSeconds(options.RetryBaseDelaySeconds * Math.Pow(2, attempt - 1));
                log.LogWarning("Fetch of order {OrderId} failed (attempt {Attempt}): {Message}; retrying in {Delay}s",
                    orderId, attempt, ex.Message, delay.TotalSeconds);
                await Task.Delay(delay, ct);
            }
        }

        throw last ?? new InvalidOperationException($"Could not fetch order {orderId}");
    }
}
