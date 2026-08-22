using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using StackExchange.Redis;
using Task = System.Threading.Tasks.Task;

namespace Bridge;

/// <summary>
/// Validates the estate's user tokens, so an operator signed into the HIS can
/// read the bridge's operational views without a second, shared password being
/// handed around.
///
/// Same three steps the Node services take, in the same order:
///   1. verify the HS256 signature with the secret IAM signs with
///   2. confirm the session still exists in Redis at user:{usr_id}, field token
///   3. if Redis cannot be reached, continue without step 2 and say so
///
/// WHY A .NET SERVICE VALIDATES A NODE ESTATE'S TOKENS
/// The token is a signed statement, not a session handle - anything holding the
/// secret can check it, in any language. This class exists mostly to show that:
/// a service written outside the estate's stack joins its authentication by
/// verifying, not by calling IAM on every request.
/// </summary>
public sealed record HisPrincipal(string UserId, string UserName, string[] Groups, bool Degraded);

public sealed class HisTokenValidator
{
    private readonly ILogger<HisTokenValidator> _log;
    private readonly JsonWebTokenHandler _handler = new();
    private readonly TokenValidationParameters? _parameters;
    private readonly Lazy<IConnectionMultiplexer?> _redis;

    private bool _revocationReachable = true;

    public HisTokenValidator(BridgeOptions options, ILogger<HisTokenValidator> log)
    {
        _log = log;

        if (options.JwtSecret.Length > 0)
        {
            _parameters = new TokenValidationParameters
            {
                ValidateIssuerSigningKey = true,
                IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(options.JwtSecret)),

                // Pinned. Without this the handler accepts any algorithm the key
                // can verify, which is a question not worth leaving open.
                ValidAlgorithms = [SecurityAlgorithms.HmacSha256],

                // IAM's tokens carry neither `iss` nor `aud` - its payload is
                // user identity and group membership only. So there is nothing
                // to validate here, and, more importantly, nothing that scopes a
                // token to one audience: a token minted for the appointment
                // service is equally valid at this one. Recorded in
                // docs/security.md rather than worked around, because the fix
                // belongs in IAM.
                ValidateIssuer = false,
                ValidateAudience = false,

                ValidateLifetime = true,
                ClockSkew = TimeSpan.FromSeconds(30)
            };
        }

        _redis = new Lazy<IConnectionMultiplexer?>(() => Connect(options, log));
    }

    public bool Configured => _parameters is not null;

    /// <summary>Null when the token is absent, unsigned, expired or revoked.</summary>
    public async Task<HisPrincipal?> ValidateAsync(string token, CancellationToken ct)
    {
        if (_parameters is null) return null;

        var result = await _handler.ValidateTokenAsync(token, _parameters);
        if (!result.IsValid) return null;

        // Read through ClaimsIdentity rather than the Claims dictionary. A JSON
        // array claim - which group_names is - becomes one claim PER VALUE here,
        // so the dictionary holds only the last of them, and its type depends on
        // the JSON type. FindAll gives every value, always as a string.
        var identity = result.ClaimsIdentity;
        if (identity is null) return null;

        var userId = identity.FindFirst("usr_id")?.Value ?? "";
        if (userId.Length == 0) return null;

        var (revoked, degraded) = await CheckRevocationAsync(userId, token, ct);
        if (revoked) return null;

        return new HisPrincipal(
            userId,
            identity.FindFirst("usr_name")?.Value ?? "",
            identity.FindAll("group_names").Select(c => c.Value).ToArray(),
            degraded);
    }

    private async Task<(bool Revoked, bool Degraded)> CheckRevocationAsync(
        string userId, string token, CancellationToken ct)
    {
        var multiplexer = _redis.Value;
        if (multiplexer is null) return (false, true);

        try
        {
            var stored = await multiplexer.GetDatabase()
                .HashGetAsync($"user:{userId}", "token")
                .WaitAsync(ct);

            if (!_revocationReachable)
            {
                _log.LogInformation("Redis reachable again - token revocation is being enforced");
                _revocationReachable = true;
            }

            // Redis answered and the session is gone: logged out, password
            // changed, or the session TTL ran out.
            return (!stored.HasValue || stored.ToString() != token, false);
        }
        catch (Exception ex)
        {
            // Logged at the edges of the outage, not once per request: an outage
            // is exactly when request volume does not fall, and this topic is
            // shared with every service in the estate.
            if (_revocationReachable)
            {
                _revocationReachable = false;
                _log.LogWarning(
                    "Redis unreachable ({Message}) - continuing in degraded authentication mode: " +
                    "signatures are still verified, revocation is not enforced", ex.Message);
            }

            return (false, true);
        }
    }

    private static IConnectionMultiplexer? Connect(BridgeOptions options, ILogger log)
    {
        if (options.RedisConfiguration.Length == 0)
        {
            log.LogWarning(
                "REDIS_HOST is not set: HIS tokens will be accepted on signature alone, " +
                "and a logout will not revoke access to this service");
            return null;
        }

        try
        {
            var config = ConfigurationOptions.Parse(options.RedisConfiguration);

            // The .NET counterpart of ioredis's enableOfflineQueue: false. Left
            // at its default of true, Connect() throws when Redis is down at
            // startup and the multiplexer is never created - which turns a cache
            // outage into a service that cannot start. False makes it connect in
            // the background and fail individual commands fast, which is what
            // the degraded path is written to handle.
            config.AbortOnConnectFail = false;
            config.ConnectTimeout = 1000;
            config.SyncTimeout = 250;
            config.ConnectRetry = 3;

            return ConnectionMultiplexer.Connect(config);
        }
        catch (Exception ex)
        {
            log.LogError("Could not create the Redis connection: {Message}", ex.Message);
            return null;
        }
    }
}
