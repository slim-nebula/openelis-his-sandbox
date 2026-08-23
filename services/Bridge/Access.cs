using System.Net;
using System.Security.Cryptography;
using System.Text;
using Prometheus;
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// Who may call what. The bridge serves three populations, and each is
/// answered differently because each can prove a different amount:
///
///   /fhir        OpenELIS, on a separate mutually authenticated port. It
///                proves who it is with a client certificate (MutualTls.cs).
///   /ops, sync   operators and `make` targets. The shared operator token, or
///                a signed-in user's token from IAM.
///   /health      nothing. A health check that can fail authentication reports
///   /metrics     an outage that is not happening.
///
/// GET /catalogue is open as well: it is the laboratory's list of orderable
/// tests, read service-to-service by the HIS, and holds no patient data.
/// </summary>
/// <summary>
/// Guards /ops and the catalogue sync. Two credentials are accepted on the same
/// header, and which one a caller uses says what kind of caller it is:
///
///   the shared operator token   scripts, `make` targets, the deployment. No
///                               person is signed in, so there is no user to be.
///   an estate user token        a human. Issued by IAM at login, checked here
///                               exactly as the Node services check it.
///
/// The shared token stays because removing it would mean the deployment needs a
/// user account and a password that never expires, which is worse than a secret
/// held by the deployment alone. The user token is what stops that secret being
/// pasted into a chat window every time someone wants to look at the queue.
/// </summary>
public sealed class OpsAccessFilter(
    BridgeOptions options,
    HisTokenValidator tokens,
    ILogger<OpsAccessFilter> log) : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext ctx, EndpointFilterDelegate next)
    {
        var request = ctx.HttpContext.Request;
        var peer = ctx.HttpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown";

        // Fail closed. An endpoint that changes the doctor's test menu must not
        // become world-writable because a deployment forgot a variable - that
        // is precisely the mistake that only shows up once it has been made.
        if (options.AdminToken.Length == 0 && !tokens.Configured)
        {
            log.LogError("Refused {Method} {Path}: neither BRIDGE_ADMIN_TOKEN nor JWT_SECRET is set",
                request.Method, request.Path);
            return Results.Problem(
                "Administrative access is not configured on this bridge.",
                statusCode: StatusCodes.Status503ServiceUnavailable);
        }

        var presented = Bearer(request);
        if (presented is null)
        {
            log.LogWarning("Refused {Method} {Path} from {Peer}: no bearer token",
                request.Method, request.Path, peer);
            return Results.Problem(
                "A valid bearer token is required for this endpoint.",
                statusCode: StatusCodes.Status401Unauthorized);
        }

        if (options.AdminToken.Length > 0 && Matches(presented, options.AdminToken))
            return await next(ctx);

        // Not the shared token, so the only remaining possibility is a user.
        var principal = tokens.Configured
            ? await tokens.ValidateAsync(presented, ctx.HttpContext.RequestAborted)
            : null;

        if (principal is null)
        {
            // The token itself is never logged, at any level. A rejected
            // credential is often a correct credential for somewhere else.
            log.LogWarning("Refused {Method} {Path} from {Peer}: bad, expired or revoked token",
                request.Method, request.Path, peer);
            return Results.Problem(
                "A valid bearer token is required for this endpoint.",
                statusCode: StatusCodes.Status401Unauthorized);
        }

        if (options.OpsGroup.Length > 0 && !principal.Groups.Contains(options.OpsGroup))
        {
            log.LogWarning("Refused {Method} {Path} for user {User}: not in group {Group}",
                request.Method, request.Path, principal.UserId, options.OpsGroup);
            return Results.Problem(
                $"This endpoint requires membership of {options.OpsGroup}.",
                statusCode: StatusCodes.Status403Forbidden);
        }

        // Who did it, on every operational action. The shared token cannot
        // answer this question, which is the other reason for accepting user
        // tokens at all.
        log.LogInformation("{Method} {Path} by user {User}{Degraded}",
            request.Method, request.Path, principal.UserId,
            principal.Degraded ? " (session unverified: Redis unreachable)" : "");

        ctx.HttpContext.Items["his-principal"] = principal;
        return await next(ctx);
    }

    private static string? Bearer(HttpRequest request)
    {
        var header = request.Headers.Authorization.FirstOrDefault();
        if (header is null || !header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return null;

        var value = header["Bearer ".Length..].Trim();
        return value.Length > 0 ? value : null;
    }

    private static bool Matches(string presented, string expected) =>
        // Fixed-time comparison: a plain string compare returns sooner the
        // earlier it finds a difference, which leaks the token a character at
        // a time to anyone patient enough to measure.
        CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(presented),
            Encoding.UTF8.GetBytes(expected));
}

/// <summary>
/// Restricts /fhir to the OpenELIS containers by source address.
///
/// SUPERSEDED, AND KEPT ON PURPOSE
/// With BRIDGE_MTLS_ENABLED this is no longer the control on the live path: the
/// mutually authenticated port proves identity with a certificate, and does not
/// consult this guard at all. What it still governs is the plaintext port,
/// which mutual TLS restricts to loopback anyway - so it is now a second lock
/// on a door that is already shut, and the fallback if mutual TLS is turned off
/// to bisect a problem.
///
/// WHY THIS WAS EVER THE ANSWER, AND WHY IT IS NOT A TOKEN
/// OpenELIS 3.2.1.11 has no way to authenticate to a remote FHIR source. Two
/// independent facts in the shipped webapp establish it:
///
///   * FhirConfig declares property placeholders for fhirstore.username /
///     .password and crserver.username / .password, but for the remote source
///     only remote.source.uri. There is no key to put a credential in.
///   * The one BasicAuthInterceptor it registers is guarded by a comparison of
///     the target URL against getLocalFhirStorePath(). The bridge is not the
///     local store, so the header is never attached.
///
/// The result push arrives through a FHIR Subscription, whose channel supports
/// headers in the R4 model - but RegisterFhirHooksTask exposes no property to
/// populate them either.
///
/// So a bearer token on /fhir would not secure the integration, it would end
/// it. That much is still true, and is why the answer is a certificate at the
/// transport layer rather than a credential in a header.
///
/// The claim once made here - that origin restriction was the strongest control
/// available without modifying OpenELIS - was wrong, and worth recording as
/// wrong. Mutual TLS was also available without modifying OpenELIS, because its
/// shared HTTP client already presents a client certificate; nothing had ever
/// asked it for one. An address allowlist authenticates a network location, not
/// a node, and IHE ATNA requires the latter.
/// </summary>
public sealed class FhirPeerGuard
{
    private static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(60);

    private readonly string[] _peers;
    private readonly ILogger<FhirPeerGuard> _log;
    private readonly SemaphoreSlim _lock = new(1, 1);

    private HashSet<IPAddress> _allowed = [];
    private DateTimeOffset _resolvedAt = DateTimeOffset.MinValue;

    public FhirPeerGuard(BridgeOptions options, ILogger<FhirPeerGuard> log)
    {
        _log = log;
        _peers = options.FhirAllowedPeers;

        if (_peers.Length == 0)
            _log.LogWarning(
                "BRIDGE_FHIR_ALLOWED_PEERS is empty: the FHIR endpoint accepts a result " +
                "or an order poll from anything that can reach this container");
        else
            _log.LogInformation("FHIR endpoint restricted to {Peers}", string.Join(", ", _peers));
    }

    public bool Enabled => _peers.Length > 0;

    public async Task<bool> IsAllowedAsync(IPAddress? remote, CancellationToken ct)
    {
        if (!Enabled) return true;
        if (remote is null) return false;

        // Kestrel reports an IPv4 peer as ::ffff:172.20.0.5 on a dual-stack
        // socket, which never equals the IPv4 address DNS returned.
        if (remote.IsIPv4MappedToIPv6) remote = remote.MapToIPv4();

        // A request from inside this container is already past every boundary
        // this guard defends; anything able to make one could edit the
        // allowlist instead. The test suite reaches /fhir this way.
        if (IPAddress.IsLoopback(remote)) return true;

        if (await MatchesAsync(remote, forceRefresh: false, ct)) return true;

        // A container that was recreated has a new address, and the old one is
        // cached for up to a minute. Re-resolve once before refusing, so a
        // restart of OpenELIS does not silently stop orders for that minute.
        return await MatchesAsync(remote, forceRefresh: true, ct);
    }

    private async Task<bool> MatchesAsync(IPAddress remote, bool forceRefresh, CancellationToken ct)
    {
        var stale = DateTimeOffset.UtcNow - _resolvedAt > CacheFor;
        if (forceRefresh || stale) await ResolveAsync(ct);
        return _allowed.Contains(remote);
    }

    private async Task ResolveAsync(CancellationToken ct)
    {
        await _lock.WaitAsync(ct);
        try
        {
            var resolved = new HashSet<IPAddress>();
            foreach (var peer in _peers)
            {
                try
                {
                    foreach (var address in await Dns.GetHostAddressesAsync(peer, ct))
                        resolved.Add(address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address);
                }
                catch (Exception ex)
                {
                    // One unresolvable peer must not empty the allowlist and
                    // lock out the others: OpenELIS's FHIR store and its webapp
                    // do not restart together.
                    _log.LogWarning("Could not resolve FHIR peer {Peer}: {Message}", peer, ex.Message);
                }
            }

            if (resolved.Count > 0)
            {
                _allowed = resolved;
                _resolvedAt = DateTimeOffset.UtcNow;
            }
            else
            {
                _log.LogError("No FHIR peer resolved; keeping the previous allowlist of {Count}", _allowed.Count);
            }
        }
        finally { _lock.Release(); }
    }
}

public static class AccessExtensions
{
    // A refusal on a FHIR endpoint answers in FHIR. A client that only knows
    // how to parse OperationOutcome should be told why it was refused in a
    // form it can read, rather than being handed a problem+json body it will
    // log as "unparseable response".
    private const string ForbiddenOutcome = """
        {"resourceType":"OperationOutcome","issue":[{"severity":"error","code":"forbidden","diagnostics":"Caller is not a permitted FHIR peer."}]}
        """;

    private const string PlaintextRefusedOutcome = """
        {"resourceType":"OperationOutcome","issue":[{"severity":"error","code":"security","diagnostics":"This endpoint requires a mutually authenticated TLS connection."}]}
        """;

    /// <summary>
    /// How each FHIR request arrived. Worth a metric rather than a log line:
    /// "is the laboratory link actually mutually authenticated, right now"
    /// is a question worth alerting on, and a configuration file cannot answer
    /// it - a setting can be true while nothing is using the port.
    ///
    /// transport="plaintext" above zero, on a deployment that believes it has
    /// mutual TLS, means something is still coming in the other way.
    /// </summary>
    private static readonly Counter FhirRequests = Metrics.CreateCounter(
        "bridge_fhir_requests_total",
        "FHIR requests by how the connection was authenticated",
        "transport");

    /// <summary>
    /// Guards /fhir at the pipeline rather than per-route: the FHIR surface is
    /// mapped across several handlers plus a bare POST /fhir for the result
    /// bundle, and a path prefix cannot be forgotten when one more is added.
    /// </summary>
    public static void UseFhirPeerGuard(this WebApplication app)
    {
        app.Use(async (ctx, next) =>
        {
            if (!ctx.Request.Path.StartsWithSegments("/fhir"))
            {
                await next();
                return;
            }

            // With mutual TLS on, the plaintext port stops being a way in.
            //
            // Without this the whole exercise is decorative: a caller that did
            // not want to present a certificate could simply use the other port
            // and be back to an address check. Loopback is still allowed, since
            // a request from inside this container is already past every
            // boundary here - it is how the test suites reach /fhir, and
            // anything able to make one could edit the configuration instead.
            var mtls = ctx.RequestServices.GetRequiredService<MutualTlsOptions>();
            var remote = ctx.Connection.RemoteIpAddress;
            var loopback = remote is not null &&
                IPAddress.IsLoopback(remote.IsIPv4MappedToIPv6 ? remote.MapToIPv4() : remote);
            var onMtlsPort = mtls.Enabled && ctx.Connection.LocalPort == mtls.Port;

            // Counted here, before any decision, so a REFUSED plaintext attempt
            // is counted too. Those are the interesting ones: they are how a
            // caller still using the old address announces itself.
            FhirRequests.WithLabels(onMtlsPort ? "mtls" : loopback ? "loopback" : "plaintext").Inc();

            if (mtls.Enabled && !onMtlsPort && !loopback)
            {
                app.Logger.LogWarning(
                    "Refused {Method} {Path} from {Peer}: /fhir requires the mutually " +
                    "authenticated port {Port}",
                    ctx.Request.Method, ctx.Request.Path, remote?.ToString() ?? "unknown", mtls.Port);

                ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
                ctx.Response.ContentType = "application/fhir+json";
                await ctx.Response.WriteAsync(PlaintextRefusedOutcome, ctx.RequestAborted);
                return;
            }

            // On the mutually authenticated port the certificate IS the control,
            // and the address allowlist is not consulted.
            //
            // This was not the first design. Both checks were kept at first, on
            // the reasoning that two controls are better than one. Turning it on
            // showed why that is wrong here: the handshake succeeded, the
            // certificate was accepted, and the allowlist then refused the
            // request anyway — because Docker's DNS answers `openelis-webapp`
            // with its address on ONE of the networks the two containers share,
            // and the connection arrives from a different one.
            //
            // A weaker check that can veto a stronger one is not defence in
            // depth. It is a second thing that can fail, guarding a door that is
            // already locked better. The certificate proves identity
            // cryptographically; an address does not, and cannot.
            if (onMtlsPort)
            {
                await next();
                return;
            }

            var guard = ctx.RequestServices.GetRequiredService<FhirPeerGuard>();
            if (await guard.IsAllowedAsync(remote, ctx.RequestAborted))
            {
                await next();
                return;
            }

            app.Logger.LogWarning("Refused {Method} {Path} from {Peer}: not an allowed FHIR peer",
                ctx.Request.Method, ctx.Request.Path, ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown");

            ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
            ctx.Response.ContentType = "application/fhir+json";
            await ctx.Response.WriteAsync(ForbiddenOutcome, ctx.RequestAborted);
        });
    }
}
