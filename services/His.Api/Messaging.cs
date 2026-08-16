using System.Text;
using System.Text.Json;
using Confluent.Kafka;

namespace His.Api;

public sealed class KafkaOptions
{
    public string Bootstrap { get; init; } = "kafka:9092";
    public string OrderCreated { get; init; } = "lab.order.created";
    public string OrderSent { get; init; } = "lab.order.sent";
    public string OrderFailed { get; init; } = "lab.order.failed";
    public string ResultReleased { get; init; } = "lab.result.released";
    public string ResultFailed { get; init; } = "lab.result.failed";
    public string ConsumerGroup { get; init; } = "his-api";

    public static KafkaOptions FromEnvironment() => new()
    {
        Bootstrap = Env("KAFKA_BOOTSTRAP", "kafka:9092"),
        OrderCreated = Env("TOPIC_ORDER_CREATED", "lab.order.created"),
        OrderSent = Env("TOPIC_ORDER_SENT", "lab.order.sent"),
        OrderFailed = Env("TOPIC_ORDER_FAILED", "lab.order.failed"),
        ResultReleased = Env("TOPIC_RESULT_RELEASED", "lab.result.released"),
        ResultFailed = Env("TOPIC_RESULT_FAILED", "lab.result.failed")
    };

    internal static string Env(string key, string fallback) =>
        Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : fallback;
}

/// <summary>Publishes domain events. Correlation id travels as a Kafka header.</summary>
public sealed class EventPublisher : IDisposable
{
    private readonly IProducer<string, string> _producer;
    private readonly KafkaOptions _options;
    private readonly ILogger<EventPublisher> _log;

    public EventPublisher(KafkaOptions options, ILogger<EventPublisher> log)
    {
        _options = options;
        _log = log;
        _producer = new ProducerBuilder<string, string>(new ProducerConfig
        {
            BootstrapServers = options.Bootstrap,
            Acks = Acks.All,
            EnableIdempotence = true,
            MessageSendMaxRetries = 5,
            LingerMs = 5,
            // Default is 5 minutes. A request that cannot reach the broker
            // should fail the caller in seconds, not hang the HTTP thread.
            MessageTimeoutMs = 8000,
            SocketTimeoutMs = 6000
        }).Build();
    }

    public async Task PublishAsync<T>(string topic, string key, T payload, string correlationId, CancellationToken ct)
    {
        var message = new Message<string, string>
        {
            Key = key,
            Value = JsonSerializer.Serialize(payload),
            Headers = [new Header("X-Correlation-ID", Encoding.UTF8.GetBytes(correlationId))]
        };

        var result = await _producer.ProduceAsync(topic, message, ct);
        _log.LogInformation("Published {Topic} key={Key} partition={Partition} offset={Offset} correlation={CorrelationId}",
            topic, key, result.Partition.Value, result.Offset.Value, correlationId);
    }

    public KafkaOptions Options => _options;

    public void Dispose()
    {
        _producer.Flush(TimeSpan.FromSeconds(5));
        _producer.Dispose();
    }
}

/// <summary>
/// Consumes the events the bridge emits: order transmission outcomes and
/// released results. Offsets are committed only after the database write
/// succeeds, so a crash mid-handler replays rather than loses the message —
/// the writes are idempotent, which is what makes that safe.
/// </summary>
public sealed class BridgeEventConsumer(
    KafkaOptions options,
    IServiceScopeFactory scopeFactory,
    ILogger<BridgeEventConsumer> log) : BackgroundService
{
    protected override Task ExecuteAsync(CancellationToken stoppingToken) =>
        Task.Run(() => ConsumeLoop(stoppingToken), stoppingToken);

    private async Task ConsumeLoop(CancellationToken ct)
    {
        var config = new ConsumerConfig
        {
            BootstrapServers = options.Bootstrap,
            GroupId = options.ConsumerGroup,
            AutoOffsetReset = AutoOffsetReset.Earliest,
            EnableAutoCommit = false,
            SessionTimeoutMs = 30000
        };

        using var consumer = new ConsumerBuilder<string, string>(config)
            .SetErrorHandler((_, e) => log.LogWarning("Kafka error: {Reason}", e.Reason))
            .Build();

        var topics = new[] { options.ResultReleased, options.OrderSent, options.OrderFailed };
        consumer.Subscribe(topics);
        log.LogInformation("Subscribed to {Topics}", string.Join(", ", topics));

        while (!ct.IsCancellationRequested)
        {
            ConsumeResult<string, string>? cr = null;
            try
            {
                cr = consumer.Consume(TimeSpan.FromSeconds(1));
                if (cr is null) continue;

                var correlationId = CorrelationOf(cr);
                await HandleAsync(cr.Topic, cr.Message.Value, correlationId, ct);
                consumer.Commit(cr);
            }
            catch (OperationCanceledException) { break; }
            catch (PoisonMessageException ex) when (cr is not null)
            {
                // A message that cannot be parsed will never parse. Retrying it
                // forever would block the partition and stall every well-formed
                // message behind it, so route it to the dead-letter topic and
                // commit past it.
                log.LogError(ex, "Poison message on {Topic} at offset {Offset}; dead-lettering",
                    cr.Topic, cr.Offset.Value);
                await DeadLetterAsync(cr, ex, ct);
                consumer.Commit(cr);
            }
            catch (Exception ex)
            {
                // Transient (database down, broker hiccup): left uncommitted on
                // purpose so the message is redelivered.
                log.LogError(ex, "Failed handling message; offset not committed");
                await Task.Delay(TimeSpan.FromSeconds(2), ct);
            }
        }

        consumer.Close();
    }

    private async Task HandleAsync(string topic, string value, string correlationId, CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var repo = scope.ServiceProvider.GetRequiredService<Repository>();

        if (topic == options.ResultReleased)
        {
            var msg = Parse<ReleasedResultMessage>(value, topic);
            await repo.UpsertResultAsync(msg with { CorrelationId = msg.CorrelationId ?? correlationId }, ct);
            return;
        }

        var lifecycle = Parse<OrderLifecycleMessage>(value, topic);

        var status = topic == options.OrderSent ? "SENT_TO_LIS" : "FAILED";
        // The bridge reports the LIS's own verdict on lab.order.sent once the
        // Task comes back accepted or rejected.
        if (lifecycle.Status is "ACCEPTED_BY_LIS" or "REJECTED_BY_LIS" or "SENT_TO_LIS" or "FAILED")
            status = lifecycle.Status;

        await repo.UpdateOrderStatusAsync(lifecycle.OrderNumber, status, lifecycle.Detail,
            lifecycle.CorrelationId ?? correlationId, ct);
    }

    private static T Parse<T>(string value, string topic)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(value)
                ?? throw new PoisonMessageException($"Empty payload on {topic}");
        }
        catch (JsonException ex)
        {
            throw new PoisonMessageException($"Unparseable payload on {topic}", ex);
        }
    }

    private async Task DeadLetterAsync(
        ConsumeResult<string, string> cr, Exception cause, CancellationToken ct)
    {
        try
        {
            using var scope = scopeFactory.CreateScope();
            var publisher = scope.ServiceProvider.GetRequiredService<EventPublisher>();
            await publisher.PublishAsync($"{cr.Topic}.dlq", cr.Message.Key ?? "unkeyed", new
            {
                deadLetteredAt = DateTimeOffset.UtcNow,
                sourceTopic = cr.Topic,
                partition = cr.Partition.Value,
                offset = cr.Offset.Value,
                reason = cause.Message,
                payload = cr.Message.Value
            }, CorrelationOf(cr), ct);
        }
        catch (Exception ex)
        {
            // Never let a DLQ failure stop the consumer: the alternative is a
            // stalled partition, which is strictly worse than a logged loss.
            log.LogError(ex, "Could not write to {Topic}.dlq", cr.Topic);
        }
    }

    private static string CorrelationOf(ConsumeResult<string, string> cr)
    {
        if (cr.Message.Headers is not null &&
            cr.Message.Headers.TryGetLastBytes("X-Correlation-ID", out var bytes))
            return Encoding.UTF8.GetString(bytes);
        return Guid.NewGuid().ToString();
    }
}

/// <summary>A message that can never succeed, however many times it is retried.</summary>
public sealed class PoisonMessageException(string message, Exception? inner = null)
    : Exception(message, inner);
