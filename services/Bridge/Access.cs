using System.Net;
using System.Security.Cryptography;
using System.Text;
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// Who may call what.
///
/// The bridge serves two populations on one port, and they need opposite
/// treatment:
///
///   /fhir        OpenELIS. Cannot present a credential (see FhirPeerGuard),
///                so it is restricted by WHERE the request comes from.
///   /ops, sync   operators and `make` targets. Fully under our control, so
///                they are restricted by WHAT the caller knows.
///
/// Everything else - /healthz and the cached /catalogue the HIS reads - is
/// read-only and internal, governed by the same network membership that has
/// always protected /internal/* on the HIS service.
/// </summary>
public sealed class AdminTokenFilter(BridgeOptions options, ILogger<AdminTokenFilter> log) : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext ctx, EndpointFilterDelegate next)
    {
        var request = ctx.HttpContext.Request;

        // Fail closed. An endpoint that changes the doctor's test menu must not
        // become world-writable because a deployment forgot a variable - that
        // is precisely the mistake that only shows up once it has been made.
        if (options.AdminToken.Length == 0)
        {
            log.LogError("Refused {Method} {Path}: BRIDGE_ADMIN_TOKEN is not set",
                request.Method, request.Path);
            return Results.Problem(
                "Administrative access is not configured on this bridge.",
                statusCode: StatusCodes.Status503ServiceUnavailable);
        }

        if (!Presented(request, options.AdminToken))
        {
            // The token itself is never logged, at any level. A rejected
            // credential is often a correct credential for somewhere else.
            log.LogWarning("Refused {Method} {Path} from {Peer}: bad or missing bearer token",
                request.Method, request.Path,
                ctx.HttpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown");
            return Results.Problem(
                "A valid bearer token is required for this endpoint.",
                statusCode: StatusCodes.Status401Unauthorized);
        }

        return await next(ctx);
    }

    private static bool Presented(HttpRequest request, string expected)
    {
        var header = request.Headers.Authorization.FirstOrDefault();
        if (header is null || !header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return false;

        // Fixed-time comparison: a plain string compare returns sooner the
        // earlier it finds a difference, which leaks the token a character at
        // a time to anyone patient enough to measure.
        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(header["Bearer ".Length..].Trim()),
            Encoding.UTF8.GetBytes(expected));
    }
}

/// <summary>
/// Restricts /fhir to the OpenELIS containers.
///
/// WHY THIS IS NOT A TOKEN
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
/// it. Restricting the origin is the strongest control available without
/// modifying OpenELIS, which is out of scope by standing constraint: it is the
/// accredited component.
///
/// This is weaker than authentication and should be read that way. What it
/// removes is the ability of anything else on the sandbox network - the HIS
/// service, the frontend, Kong, Redis - to inject a result or read the order
/// stream. What it does not survive is an attacker who can spoof a source
/// address or take over an OpenELIS container.
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

            var guard = ctx.RequestServices.GetRequiredService<FhirPeerGuard>();
            if (await guard.IsAllowedAsync(ctx.Connection.RemoteIpAddress, ctx.RequestAborted))
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
