using System.Security.Cryptography;
using System.Text;

namespace His.Api;

/// <summary>
/// Bearer-token check for the HIS service's administrative endpoints.
///
/// One endpoint needs it today: /admin/catalogue/refresh replaces the test menu
/// every doctor orders from. Unauthenticated, a single POST at the wrong moment
/// - while the bridge holds a partial read, say - changes what the hospital can
/// order. It is routed through Kong precisely because a technician presses it
/// from a browser, which is also what makes it reachable from the edge.
///
/// The client-facing API is not behind this. Patients and orders are the
/// service's actual job, and putting a shared operator token in front of them
/// would be authentication in the wrong place: those need per-user identity,
/// which is a larger piece of work than this one and is recorded as such in
/// docs/security.md.
/// </summary>
public sealed class AdminTokenFilter(ILogger<AdminTokenFilter> log) : IEndpointFilter
{
    private static readonly string Expected = KafkaOptions.Env("HIS_ADMIN_TOKEN", "");

    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext ctx, EndpointFilterDelegate next)
    {
        var request = ctx.HttpContext.Request;

        // Fail closed: a missing variable must not be what makes an endpoint
        // public.
        if (Expected.Length == 0)
        {
            log.LogError("Refused {Method} {Path}: HIS_ADMIN_TOKEN is not set", request.Method, request.Path);
            return Results.Problem(
                "Administrative access is not configured on this service.",
                statusCode: StatusCodes.Status503ServiceUnavailable);
        }

        if (!Presented(request))
        {
            log.LogWarning("Refused {Method} {Path}: bad or missing bearer token", request.Method, request.Path);
            return Results.Problem(
                "A valid bearer token is required for this endpoint.",
                statusCode: StatusCodes.Status401Unauthorized);
        }

        return await next(ctx);
    }

    private static bool Presented(HttpRequest request)
    {
        var header = request.Headers.Authorization.FirstOrDefault();
        if (header is null || !header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return false;

        // Fixed-time: a plain comparison returns sooner the earlier it finds a
        // difference, which hands the token over a character at a time.
        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(header["Bearer ".Length..].Trim()),
            Encoding.UTF8.GetBytes(Expected));
    }
}
