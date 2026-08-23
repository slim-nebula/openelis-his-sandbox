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
    /// <summary>
    /// Thumbprints the listener will accept. Read once at startup: a file read
    /// per handshake would put disk I/O on the path of every order poll.
    /// </summary>
    private static string[] _pinned = [];

    public static void Configure(WebApplicationBuilder builder, MutualTlsOptions options)
    {
        builder.WebHost.ConfigureKestrel(kestrel =>
        {
            // The estate-facing port. Everything that is not OpenELIS arrives
            // here: Consul's health check, Prometheus, the HIS service reading
            // the cached catalogue, operators on /ops.
            kestrel.ListenAnyIP(int.Parse(BridgeOptions.Env("SERVICE_PORT", "8080")));

            if (!options.Enabled) return;

            var server = LoadServerCertificate(options);
            _pinned = LoadPinnedThumbprints(options);

            kestrel.ListenAnyIP(options.Port, listen => listen.UseHttps(https =>
            {
                https.ServerCertificate = server;

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
                    _pinned.Contains(certificate.Thumbprint, StringComparer.OrdinalIgnoreCase);
            }));
        });
    }

    private static X509Certificate2 LoadServerCertificate(MutualTlsOptions options)
    {
        if (!File.Exists(options.ServerCertificatePath) || !File.Exists(options.ServerKeyPath))
            throw new InvalidOperationException(
                $"BRIDGE_MTLS_ENABLED is true but {options.ServerCertificatePath} or " +
                $"{options.ServerKeyPath} is missing. Run scripts/init-mtls.sh.");

        var pem = X509Certificate2.CreateFromPemFile(
            options.ServerCertificatePath, options.ServerKeyPath);

        // Kestrel needs the private key to survive being handed to the TLS
        // stack. On Linux a PEM-loaded certificate carries an ephemeral key that
        // does not, so it is round-tripped through PKCS#12 first.
        return X509CertificateLoader.LoadPkcs12(pem.Export(X509ContentType.Pkcs12), null);
    }

    private static string[] LoadPinnedThumbprints(MutualTlsOptions options)
    {
        if (!File.Exists(options.PeerCertificatePath))
            throw new InvalidOperationException(
                $"BRIDGE_MTLS_ENABLED is true but {options.PeerCertificatePath} is missing. " +
                "It is exported from OpenELIS's own truststore by scripts/init-mtls.sh.");

        var certificate = X509CertificateLoader.LoadCertificateFromFile(options.PeerCertificatePath);
        return [certificate.Thumbprint];
    }
}
