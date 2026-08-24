using System.Security.Cryptography.X509Certificates;
using Microsoft.AspNetCore.Server.Kestrel.Https;

namespace Bridge;

/// <summary>
/// The mutually-authenticated listener OpenELIS talks to.
///
/// WHAT THIS REPLACES
/// The FHIR hop used to be plain HTTP, guarded only by an allowlist of source
/// addresses. That authenticates a network location, not a node: it produces no
/// cryptographic identity, no audit evidence, and no protection from anything
/// already inside the segment. IHE ATNA requires node authentication to be
/// bidirectional and certificate-based, and prohibits PHI crossing a link that
/// is not - which is exactly the link a laboratory result travels on.
///
/// WHY OPENELIS NEEDED NO CHANGE
/// It was already willing to prove who it is. HttpClientConfig in the deployed
/// webapp builds its shared HTTP client with loadKeyMaterial from the keystore
/// this repository already points it at, and FhirConfig gives that client to
/// every FHIR client it makes - the order poll and the result push included.
/// Nothing had ever asked it for a certificate. This asks.
///
/// The peer is pinned to one certificate rather than to a CA. A CA says "signed
/// by someone we trust"; here exactly one machine may ever connect, so "is this
/// that machine" is the question worth asking, and pinning is the direct answer
/// to it. It also means the bridge holds OpenELIS's public certificate and
/// nothing else: it can recognise OpenELIS, and cannot impersonate it.
///
/// CERTIFICATES ARE READ PER HANDSHAKE, NOT AT STARTUP
/// The first version of this loaded both certificates while the host was being
/// built and threw if either was missing. That turned an absent file into a
/// crashloop, which is how a fresh clone of this repository came up with no
/// bridge at all - the process died before it could say why, and the only
/// symptom was a restart counter.
///
/// Reading them per handshake costs one stat() on a path that OpenELIS touches
/// every few seconds, and buys two things. A bridge with no certificates still
/// starts, still serves /health and /ops, and says plainly in its log what is
/// missing. And a certificate replaced underneath a running process is picked
/// up on the next connection, so rotation does not need a restart.
///
/// It stays fail-CLOSED: no server certificate or no pinned peer means the
/// handshake does not complete. Nothing is admitted that could not prove itself.
/// </summary>
public sealed class MutualTlsOptions
{
    public bool Enabled { get; init; }
    public int Port { get; init; } = 8443;
    public string ServerCertificatePath { get; init; } = "";
    public string ServerKeyPath { get; init; } = "";
    public string PeerCertificatePath { get; init; } = "";

    public static MutualTlsOptions FromEnvironment() => new()
    {
        Enabled = BridgeOptions.Env("BRIDGE_MTLS_ENABLED", "false") == "true",
        Port = int.Parse(BridgeOptions.Env("BRIDGE_MTLS_PORT", "8443")),
        ServerCertificatePath = BridgeOptions.Env("BRIDGE_MTLS_CERT", "/certs/bridge.crt"),
        ServerKeyPath = BridgeOptions.Env("BRIDGE_MTLS_KEY", "/certs/bridge.key"),
        PeerCertificatePath = BridgeOptions.Env("BRIDGE_MTLS_PEER_CERT", "/certs/openelis-client.crt")
    };
}

public static class MutualTls
{
    private static readonly object Gate = new();

    private static X509Certificate2? _server;
    private static DateTime _serverStamp;

    private static string[] _pinned = [];
    private static DateTime _peerStamp;

    /// <summary>
    /// Attached after the host is built. Listeners are configured before
    /// logging exists, but nothing here runs until a connection arrives, and by
    /// then it does.
    /// </summary>
    private static ILogger? _log;

    public static void AttachLogger(ILogger log) => _log = log;

    public static void Configure(WebApplicationBuilder builder, MutualTlsOptions options)
    {
        builder.WebHost.ConfigureKestrel(kestrel =>
        {
            // The estate-facing port. Everything that is not OpenELIS arrives
            // here: Consul's health check, Prometheus, the HIS service reading
            // the cached catalogue, operators on /ops.
            kestrel.ListenAnyIP(int.Parse(BridgeOptions.Env("SERVICE_PORT", "8080")));

            if (!options.Enabled) return;

            kestrel.ListenAnyIP(options.Port, listen => listen.UseHttps(https =>
            {
                // A selector rather than a fixed certificate, so the port binds
                // whether or not the file is there yet. Returning null aborts
                // the connection - the strict outcome, without the crashloop.
                https.ServerCertificateSelector = (_, _) => ServerCertificate(options);

                // RequireCertificate, not AllowCertificate. A handshake that
                // completes without one must fail at the handshake, not later
                // in a handler somebody forgot to guard.
                https.ClientCertificateMode = ClientCertificateMode.RequireCertificate;

                // No revocation check: these are certificates from a two-member
                // private CA with no CRL and no OCSP responder. Asking would
                // fail every handshake, and asking loudly-but-optionally would
                // be worse - a check that always passes teaches everyone that a
                // revocation failure is normal.
                https.CheckCertificateRevocation = false;

                https.ClientCertificateValidation = (certificate, _, _) =>
                {
                    var pinned = PinnedThumbprints(options);

                    if (pinned.Contains(certificate.Thumbprint, StringComparer.OrdinalIgnoreCase))
                        return true;

                    // Worth a log line either way: an unknown certificate is
                    // either a misconfiguration or something that should not be
                    // on this network, and both want investigating.
                    Say(LogLevel.Warning,
                        "mtls-peer-rejected",
                        "Refused a client certificate on the FHIR port: subject {Subject}, thumbprint {Thumbprint}",
                        certificate.Subject, certificate.Thumbprint);
                    return false;
                };
            }));
        });
    }

    // --- certificate loading -------------------------------------------------

    private static X509Certificate2? ServerCertificate(MutualTlsOptions options)
    {
        lock (Gate)
        {
            var stamp = StampOf(options.ServerCertificatePath, options.ServerKeyPath);

            if (stamp is null)
            {
                Say(LogLevel.Error,
                    "mtls-no-server-cert",
                    "BRIDGE_MTLS_ENABLED is true but {Cert} or {Key} is missing, so no handshake on " +
                    "the FHIR port can complete. Run `make certs`.",
                    options.ServerCertificatePath, options.ServerKeyPath);
                return null;
            }

            if (_server is not null && stamp == _serverStamp) return _server;

            var pem = X509Certificate2.CreateFromPemFile(
                options.ServerCertificatePath, options.ServerKeyPath);

            // Kestrel needs the private key to survive being handed to the TLS
            // stack. On Linux a PEM-loaded certificate carries an ephemeral key
            // that does not, so it is round-tripped through PKCS#12 first.
            _server = X509CertificateLoader.LoadPkcs12(pem.Export(X509ContentType.Pkcs12), null);
            _serverStamp = stamp.Value;

            Say(LogLevel.Information,
                "mtls-server-cert",
                "Serving the FHIR port as {Subject}, expiring {NotAfter:yyyy-MM-dd}",
                _server.Subject, _server.NotAfter);

            return _server;
        }
    }

    private static string[] PinnedThumbprints(MutualTlsOptions options)
    {
        lock (Gate)
        {
            var stamp = StampOf(options.PeerCertificatePath);

            if (stamp is null)
            {
                Say(LogLevel.Error,
                    "mtls-no-peer-cert",
                    "{Path} is missing, so every client certificate will be refused. It is exported " +
                    "from OpenELIS's own truststore - `make certs` with OpenELIS running.",
                    options.PeerCertificatePath);
                return [];
            }

            if (_pinned.Length > 0 && stamp == _peerStamp) return _pinned;

            var certificate = X509CertificateLoader.LoadCertificateFromFile(options.PeerCertificatePath);
            _pinned = [certificate.Thumbprint];
            _peerStamp = stamp.Value;

            Say(LogLevel.Information,
                "mtls-peer-cert",
                "Pinned the FHIR peer to {Subject} ({Thumbprint})",
                certificate.Subject, certificate.Thumbprint);

            return _pinned;
        }
    }

    /// <summary>
    /// The newest modification time across the given files, or null if any of
    /// them is absent. Cheap enough to run per handshake, and it is what makes
    /// a replaced certificate take effect without a restart.
    /// </summary>
    private static DateTime? StampOf(params string[] paths)
    {
        var newest = DateTime.MinValue;
        foreach (var path in paths)
        {
            if (!File.Exists(path)) return null;
            var written = File.GetLastWriteTimeUtc(path);
            if (written > newest) newest = written;
        }
        return newest;
    }

    // --- logging -------------------------------------------------------------

    private static readonly Dictionary<string, DateTimeOffset> LastSaid = [];

    /// <summary>
    /// Once a minute per distinct message. OpenELIS polls this port every few
    /// seconds, so an unthrottled "certificate missing" would produce thousands
    /// of identical lines an hour and bury whatever else went wrong - including
    /// on the shared log topic, where it would be everyone's problem.
    /// </summary>
    private static void Say(LogLevel level, string key, string template, params object?[] args)
    {
        lock (LastSaid)
        {
            var now = DateTimeOffset.UtcNow;
            if (LastSaid.TryGetValue(key, out var last) && now - last < TimeSpan.FromMinutes(1)) return;
            LastSaid[key] = now;
        }

        if (_log is not null)
            _log.Log(level, template, args);
        else
            Console.Error.WriteLine($"[{level}] {template} {string.Join(" ", args)}");
    }
}
