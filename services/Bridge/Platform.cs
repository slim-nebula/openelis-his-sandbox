using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Confluent.Kafka;
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// The hooks the HIS platform expects every service to expose.
///
/// The bridge was a well-tested service that the platform could not see: Kong
/// could not discover it, Prometheus scraped nothing, and its logs went to a
/// container's stdout rather than the estate's log topic. None of that is
/// visible from inside the sandbox, where everything is addressed by compose
/// service name and read with `docker logs`. All of it matters the moment this
/// is deployed beside the real services.
///
/// These are deliberately the SAME shapes the Node services use — /health with
/// the same fields, the same Consul tags and check timings, the same log
/// envelope — so the bridge is indistinguishable from its neighbours to
/// anything that inspects it. That it happens to be written in C# is then a
/// detail of its implementation rather than a fact the platform has to know.
/// </summary>
public sealed record PlatformOptions(
    string ServiceName,
    string ServiceVersion,
    string ConsulHost,
    int ConsulPort,
    string? AdvertisedIp,
    int Port,
    string LogsTopic,
    bool ConsulEnabled)
{
    public static PlatformOptions FromEnvironment(string defaultServiceName) => new(
        ServiceName: BridgeOptions.Env("SERVICE_NAME", defaultServiceName),
        ServiceVersion: BridgeOptions.Env("SERVICE_VERSION", "1.0.0"),
        ConsulHost: BridgeOptions.Env("CONSUL_HOST", ""),
        ConsulPort: int.Parse(BridgeOptions.Env("CONSUL_PORT", "8500")),
        // Their ConsulRegistration allows SERVICE_IP to override the detected
        // address, for hosts where the container's own view is not routable.
        AdvertisedIp: BridgeOptions.Env("SERVICE_IP", "") is { Length: > 0 } ip ? ip : null,
        Port: int.Parse(BridgeOptions.Env("SERVICE_PORT", "8080")),
        LogsTopic: BridgeOptions.Env("TOPIC_LOGS", "logs"),
        ConsulEnabled: BridgeOptions.Env("CONSUL_HOST", "").Length > 0);
}

/// <summary>
/// Registers with Consul on start and deregisters on shutdown.
///
/// Mirrors the Node services' ConsulRegistration exactly: same tag set, same
/// 10s/3s check, same 30s critical deregistration. Matching those numbers is
/// not pedantry — Kong's upstream health depends on them, and a service that
/// deregisters on a different schedule from its neighbours produces routing
/// behaviour nobody can reason about.
/// </summary>
public sealed class ConsulRegistration(
    PlatformOptions options,
    IHttpClientFactory httpClientFactory,
    ILogger<ConsulRegistration> log) : IHostedService
{
    private readonly string _serviceId =
        $"{options.ServiceName}-{Environment.GetEnvironmentVariable("HOSTNAME") ?? Guid.NewGuid().ToString("N")[..8]}";

    public async Task StartAsync(CancellationToken ct)
    {
        if (!options.ConsulEnabled)
        {
            log.LogInformation("Consul registration is off: CONSUL_HOST is not set");
            return;
        }

        var address = options.AdvertisedIp ?? AdvertisableAddress(options);

        var payload = new
        {
            ID = _serviceId,
            Name = options.ServiceName,
            Address = address,
            options.Port,
            Tags = new[] { "hospital", "microservice", "load-balanced", $"version-{options.ServiceVersion}" },
            Check = new
            {
                Name = $"{options.ServiceName}-health",
                HTTP = $"http://{address}:{options.Port}/health",
                Interval = "10s",
                Timeout = "3s",
                DeregisterCriticalServiceAfter = "30s"
            }
        };

        try
        {
            using var client = httpClientFactory.CreateClient();
            using var response = await client.PutAsJsonAsync(
                $"http://{options.ConsulHost}:{options.ConsulPort}/v1/agent/service/register", payload, ct);
            response.EnsureSuccessStatusCode();

            log.LogInformation("Registered {Service} with Consul as {Id} at {Address}:{Port}",
                options.ServiceName, _serviceId, address, options.Port);
        }
        catch (Exception ex)
        {
            // The Node services call process.exit(1) here. This does not: the
            // bridge's job is moving patient results, and it can do that
            // perfectly well while unregistered — OpenELIS polls it by name and
            // Kafka does not care. Refusing to start over a registry outage
            // would convert a discovery problem into a laboratory outage.
            log.LogError(ex, "Could not register {Service} with Consul; continuing unregistered",
                options.ServiceName);
        }
    }

    public async Task StopAsync(CancellationToken ct)
    {
        if (!options.ConsulEnabled) return;

        try
        {
            using var client = httpClientFactory.CreateClient();
            using var response = await client.PutAsync(
                $"http://{options.ConsulHost}:{options.ConsulPort}/v1/agent/service/deregister/{_serviceId}",
                null, ct);
            response.EnsureSuccessStatusCode();
            log.LogInformation("Deregistered {Id} from Consul", _serviceId);
        }
        catch (Exception ex)
        {
            // Consul's own DeregisterCriticalServiceAfter cleans this up in 30s.
            log.LogWarning("Could not deregister {Id}: {Message}", _serviceId, ex.Message);
        }
    }

    /// <summary>
    /// The address Consul can actually reach this container on.
    ///
    /// The Node services take eth0, which is right for them: each sits on a
    /// single Docker network, so it has one address and eth0 is it. Copying that
    /// logic here registered the bridge at its DATA-network address while Consul
    /// watches the sandbox network, and every health check failed — the service
    /// appeared in the catalogue and was permanently critical.
    ///
    /// The bridge is on three networks on purpose; multi-homing is the boundary
    /// this whole architecture rests on. So the question is not "what is my
    /// address" but "what is my address FROM CONSUL'S SIDE", and only the
    /// routing table can answer that. Connecting a UDP socket sends no packets;
    /// it just asks the kernel which local address it would use to reach that
    /// destination, which is exactly the address to advertise.
    ///
    /// Worth knowing for the real HIS too: the moment any service there joins a
    /// second network, its eth0 registration becomes a coin flip.
    /// </summary>
    private static string AdvertisableAddress(PlatformOptions options)
    {
        try
        {
            using var probe = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            probe.Connect(options.ConsulHost, options.ConsulPort);
            if (probe.LocalEndPoint is IPEndPoint { Address: var local } && !IPAddress.IsLoopback(local))
                return local.ToString();
        }
        catch
        {
            // Consul's hostname may not resolve yet. Fall through to the
            // interface scan, which is at least deterministic.
        }

        return ContainerAddress(options.ServiceName);
    }

    /// <summary>eth0, then any non-loopback IPv4, then the service name — the Node services' order.</summary>
    private static string ContainerAddress(string fallback)
    {
        var interfaces = NetworkInterface.GetAllNetworkInterfaces();

        var eth0 = interfaces.FirstOrDefault(n => n.Name == "eth0");
        if (eth0 is not null && FirstIPv4(eth0) is { } primary) return primary;

        foreach (var candidate in interfaces.Where(n => n.OperationalStatus == OperationalStatus.Up))
            if (FirstIPv4(candidate) is { } address) return address;

        return fallback;

        static string? FirstIPv4(NetworkInterface nic) => nic
            .GetIPProperties().UnicastAddresses
            .FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork
                                 && !IPAddress.IsLoopback(a.Address))
            ?.Address.ToString();
    }
}

/// <summary>
/// Ships log lines to the estate's shared Kafka `logs` topic, in the same
/// envelope the Node services' Winston transport uses.
///
/// Two properties this must have, and neither is optional:
///
///   * It must never block a request. Logging is on the hot path of everything;
///     a slow broker must not become a slow API. Lines go onto a bounded
///     channel and a background pump drains it.
///   * It must never log. The obvious implementation publishes through the
///     bridge's EventPublisher, which logs every publish — which publishes,
///     which logs. This holds its own producer and is silent by construction.
///
/// When the channel is full, lines are DROPPED rather than queued without
/// limit. A logging subsystem that consumes memory until the process dies has
/// turned an observability problem into an outage.
/// </summary>
public sealed class KafkaLogProvider : ILoggerProvider
{
    private readonly Channel<LogLine> _queue = Channel.CreateBounded<LogLine>(
        new BoundedChannelOptions(2_000) { FullMode = BoundedChannelFullMode.DropWrite });

    private readonly IProducer<string, string>? _producer;
    private readonly PlatformOptions _options;
    private readonly CancellationTokenSource _stopping = new();
    private readonly HashSet<string> _reported = [];

    public KafkaLogProvider(PlatformOptions options, string kafkaBootstrap)
    {
        _options = options;

        try
        {
            _producer = new ProducerBuilder<string, string>(new ProducerConfig
            {
                BootstrapServers = kafkaBootstrap,
                // Fire and forget, explicitly. Log delivery is worth far less
                // than the request it describes, so this must not retry hard,
                // must not block, and must not be idempotent-with-ordering at
                // the cost of throughput.
                Acks = Acks.None,
                LingerMs = 200,
                MessageTimeoutMs = 5_000,
                EnableDeliveryReports = false
            }).Build();
        }
        catch (Exception ex)
        {
            // No broker, no log shipping. Console logging is registered
            // separately and keeps working.
            Console.Error.WriteLine($"[KafkaLogProvider] disabled: {ex.Message}");
            _producer = null;
        }

        _ = Task.Run(PumpAsync);
    }

    public ILogger CreateLogger(string categoryName) => new KafkaLogger(this, categoryName);

    private void Enqueue(LogLine line) => _queue.Writer.TryWrite(line);

    private async Task PumpAsync()
    {
        if (_producer is null) return;

        try
        {
            await foreach (var line in _queue.Reader.ReadAllAsync(_stopping.Token))
            {
                try
                {
                    _producer.Produce(_options.LogsTopic, new Message<string, string>
                    {
                        Key = _options.ServiceName,
                        Value = JsonSerializer.Serialize(new
                        {
                            service = _options.ServiceName,
                            level = line.Level,
                            message = line.Message,
                            timestamp = line.Timestamp.ToString("o")
                        })
                    });
                }
                catch (Exception ex)
                {
                    // Cannot log this through ILogger — that would recurse. But
                    // failing in complete silence is how a log pipeline ends up
                    // dead for months without anyone noticing, so it goes to
                    // stderr, once per distinct reason.
                    if (_reported.Add(ex.Message))
                        Console.Error.WriteLine($"[KafkaLogProvider] send failed: {ex.Message}");
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    public void Dispose()
    {
        _stopping.Cancel();
        _queue.Writer.TryComplete();
        _producer?.Flush(TimeSpan.FromSeconds(2));
        _producer?.Dispose();
        _stopping.Dispose();
    }

    private readonly record struct LogLine(string Level, string Message, DateTimeOffset Timestamp);

    private sealed class KafkaLogger(KafkaLogProvider provider, string category) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        // The topic is SHARED with every other service in the estate, so the
        // question is not "is this worth logging" but "is this worth putting on
        // everyone's bus".
        //
        // Framework categories are not. ASP.NET emits four Information lines per
        // request — starting, executing, executed, finished — and with a Consul
        // check every 10s and a Docker healthcheck alongside it, an idle bridge
        // produced ~2,800 messages in five minutes, none of them about a
        // patient. The Node services ship Winston output, which is application
        // logging only; this matches that.
        //
        // Framework WARNINGS still ship. "Failed to bind", "connection reset",
        // "request rejected" are exactly the lines worth having centrally.
        private readonly bool _framework =
            category.StartsWith("Microsoft.", StringComparison.Ordinal) ||
            category.StartsWith("System.", StringComparison.Ordinal);

        public bool IsEnabled(LogLevel logLevel) =>
            logLevel >= (_framework ? LogLevel.Warning : LogLevel.Information);

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel)) return;

            var message = formatter(state, exception);
            if (exception is not null) message += $" | {exception.GetType().Name}: {exception.Message}";

            provider.Enqueue(new LogLine(
                Level: logLevel switch
                {
                    LogLevel.Critical or LogLevel.Error => "error",
                    LogLevel.Warning => "warn",
                    _ => "info"
                },
                Message: $"[{category}] {message}",
                Timestamp: DateTimeOffset.UtcNow));
        }
    }
}

public static class PlatformExtensions
{
    /// <summary>
    /// The health document the platform reads. Same field names as the Node
    /// services so one dashboard, one Consul check and one alert rule cover
    /// every service in the estate.
    /// </summary>
    public static object HealthDocument(PlatformOptions options, string status = "healthy") => new
    {
        service = options.ServiceName,
        instance = Environment.GetEnvironmentVariable("HOSTNAME") ?? "localhost",
        status,
        timestamp = DateTimeOffset.UtcNow.ToString("o"),
        uptime = Math.Round((DateTimeOffset.UtcNow - StartedAt).TotalSeconds, 3),
        version = options.ServiceVersion
    };

    private static readonly DateTimeOffset StartedAt = DateTimeOffset.UtcNow;
}
