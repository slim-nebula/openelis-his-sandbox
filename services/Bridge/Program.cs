using System.Text.Json;
using Bridge;
using Dapper;
using Npgsql;
using Prometheus;

var builder = WebApplication.CreateBuilder(args);

var options = BridgeOptions.FromEnvironment();
var platform = PlatformOptions.FromEnvironment("bridge-service");

DefaultTypeMap.MatchNamesWithUnderscores = true;
SqlMapper.AddTypeHandler(new DateOnlyTypeHandler());
SqlMapper.AddTypeHandler(new DateTimeOffsetTypeHandler());

builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(o =>
{
    o.IncludeScopes = true;
    o.JsonWriterOptions = new JsonWriterOptions { Indented = false };
});
// Console stays: `docker logs bridge` must keep working during an incident,
// which is exactly when the log topic is least trustworthy.
builder.Logging.AddProvider(new KafkaLogProvider(platform, options.KafkaBootstrap));

builder.Services.AddSingleton(options);
builder.Services.AddSingleton(platform);
builder.Services.AddHostedService<ConsulRegistration>();
builder.Services.AddSingleton(_ => new NpgsqlDataSourceBuilder(options.ConnectionString).Build());
builder.Services.AddScoped<BridgeStore>();
builder.Services.AddScoped<ExportHealthProbe>();
builder.Services.AddScoped<RetentionSweeper>();
builder.Services.AddSingleton<EventPublisher>();
// Singleton: it caches resolved peer addresses, which is only worth doing once
// for the process rather than once per request.
builder.Services.AddSingleton<FhirPeerGuard>();
builder.Services.AddHostedService<OrderConsumer>();
builder.Services.AddHostedService<ResultCorrelator>();
builder.Services.AddHostedService<ExportMonitor>();
builder.Services.AddHostedService<RetentionService>();

// Singleton: it holds one Redis multiplexer and one signing key, neither of
// which is worth rebuilding per request.
builder.Services.AddSingleton<HisTokenValidator>();

builder.Services.AddHttpClient("his-api", client =>
{
    client.BaseAddress = new Uri(options.HisApiBaseUrl);
    client.Timeout = TimeSpan.FromSeconds(15);

    // The estate's service-to-service credential, on every call to /internal/*.
    // Set once here rather than at each call site, so a request added later
    // cannot be the one that forgets it.
    if (options.InternalApiKey.Length > 0)
        client.DefaultRequestHeaders.Add("x-internal-api-key", options.InternalApiKey);
});

var app = builder.Build();

await WaitForDatabaseAsync(app);

// Records http_requests_total / http_request_duration_seconds against the route
// template, the same series the Node services expose through prom-client.
app.UseHttpMetrics();

// Before routing, so it covers every /fhir handler including the bare POST for
// the result bundle - and any added later without remembering to guard them.
app.UseFhirPeerGuard();

// --- Platform surface -------------------------------------------------------
// What the estate reads: Consul's check, Prometheus's scrape. Both must answer
// without a credential — a health check that can fail authentication reports
// an outage that is not happening.

app.MapMetrics();   // GET /metrics

app.MapGet("/health", async (NpgsqlDataSource ds, CancellationToken ct) =>
{
    // Reaching the database is the honest test. A service that answers "healthy"
    // while unable to read its own state gets left in Kong's rotation, and every
    // request routed to it fails.
    try
    {
        await using var conn = await ds.OpenConnectionAsync(ct);
        await conn.ExecuteScalarAsync<int>("SELECT 1");
    }
    catch (Exception ex)
    {
        return Results.Json(new
        {
            service = platform.ServiceName,
            status = "unhealthy",
            detail = ex.Message
        }, statusCode: StatusCodes.Status503ServiceUnavailable);
    }

    return Results.Ok(PlatformExtensions.HealthDocument(platform));
});

// What this service is, for a human who has just found it in the Consul UI.
app.MapGet("/", () => Results.Ok(new
{
    message = "bridge service",
    fhirEndpoint = "/fhir",
    labOwner = options.LabOwnerReference
}));

// --- Public surface ---------------------------------------------------------
// Read-only and internal: the cached menu the HIS service mirrors. Changes
// nothing, and is already behind network membership.

// Served from the cache, never live: the ordering screen must not go blank
// because OpenELIS is restarting, and syncedAt lets the caller show how old the
// menu is rather than pretend it cannot age.
app.MapGet("/catalogue", async (BridgeStore store, CancellationToken ct) =>
{
    var entries = await store.GetCatalogueAsync(ct);
    return Results.Ok(new
    {
        syncedAt = await store.GetCatalogueSyncedAtAsync(ct),
        count = entries.Count,
        tests = entries
    });
});

// --- Operational and administrative surface ---------------------------------
// Everything past this point either changes something or describes the health
// of the integration in detail. Both are worth a bearer token: the first
// because an unauthenticated caller could empty the doctor's test menu, the
// second because "which orders are outstanding and which failed" is a
// description of real patients' care.
//
// Two credentials open these: the shared operator token for scripts and the
// deployment, and an estate user token for a person. See OpsAccessFilter.

var ops = app.MapGroup("/ops").AddEndpointFilter<OpsAccessFilter>();
var catalogue = app.MapGroup("/catalogue").AddEndpointFilter<OpsAccessFilter>();

// Useful during testing: shows exactly what the bridge is publishing for
// OpenELIS to poll, and what it could not correlate.
ops.MapGet("/orders", async (BridgeStore store, BridgeOptions opts, CancellationToken ct) =>
{
    var tasks = await store.SearchTasksAsync(null, null, null, opts.MaxSearchResults, ct);
    var summary = tasks.Select(t => new
    {
        taskId = t.Id,
        status = ((Hl7.Fhir.Model.Task)t).Status?.ToString(),
        owner = ((Hl7.Fhir.Model.Task)t).Owner?.Reference,
        basedOn = ((Hl7.Fhir.Model.Task)t).BasedOn.Select(b => b.Reference),
        description = ((Hl7.Fhir.Model.Task)t).Description
    });
    return Results.Ok(summary);
});

ops.MapGet("/dead-letters", async (BridgeStore store, CancellationToken ct) =>
    Results.Ok(await store.GetDeadLettersAsync(ct)));

// --- Health of the channel results arrive on -------------------------------

// Answers "is OpenELIS still pushing results to us", which nothing else could
// tell you: a bridge receiving nothing looks the same as a quiet laboratory.
ops.MapGet("/export-status", async (BridgeStore store, CancellationToken ct) =>
    await store.GetLatestExportCheckAsync(ct) is { } latest
        ? Results.Ok(latest)
        : Results.Ok(new { verdict = "UNKNOWN", detail = "no check has run yet" }));

ops.MapGet("/export-status/history", async (BridgeStore store, CancellationToken ct) =>
    Results.Ok(await store.GetExportChecksAsync(ct)));

// Runs the check now rather than waiting for the next cycle. An operator asking
// "is it working right now" should not have to wait five minutes for an answer.
ops.MapPost("/export-status/check", async (
    BridgeOptions opts, ExportHealthProbe probe, CancellationToken ct) =>
{
    if (!opts.CatalogueDiscoveryConfigured)
        return Results.Problem("No OpenELIS REST credentials configured.",
            statusCode: StatusCodes.Status501NotImplemented);

    var (verdict, detail) = await probe.RunAsync(ct);
    return Results.Ok(new { verdict, detail });
});

// Runs the retention sweep now. The timer is the normal path; this exists so
// the windows can be verified against real data rather than trusted, and so a
// database filling up can be dealt with at the time rather than at 03:00.
ops.MapPost("/retention/sweep", async (RetentionSweeper sweeper, CancellationToken ct) =>
    Results.Ok(await sweeper.RunAsync(ct)));

// --- The test menu, discovered from OpenELIS -------------------------------

catalogue.MapGet("/syncs", async (BridgeStore store, CancellationToken ct) =>
    Results.Ok(await store.GetCatalogueSyncsAsync(ct)));

// Manual, because a clinic changes its menu when it commissions an analyser -
// a few times a year - and a human pressing this is a human who can read the
// diff. force=true overrides the shrink guard for a genuine large withdrawal.
catalogue.MapPost("/sync", async (
    bool? force, BridgeOptions opts, BridgeStore store, ILoggerFactory loggers, CancellationToken ct) =>
{
    if (!opts.CatalogueDiscoveryConfigured)
        return Results.Problem(
            "Catalogue discovery is not configured. Set OE_REST_BASE_URL, OE_SERVICE_USER and OE_SERVICE_PASSWORD.",
            statusCode: StatusCodes.Status501NotImplemented);

    var sync = new CatalogueSync(opts, store, loggers.CreateLogger<CatalogueSync>());
    var result = await sync.RunAsync(force ?? false, ct);

    // A rejected sync is not an error in the caller: the request was valid and
    // the guard did its job. 409 says "I did not apply this", and the body says
    // why, which is what the operator needs to decide whether to force it.
    return result.Applied
        ? Results.Ok(result)
        : Results.Json(result, statusCode: StatusCodes.Status409Conflict);
});

// --- The FHIR R4 endpoint OpenELIS integrates with -------------------------
app.MapFhirEndpoints();

app.Run();
return;

static async Task WaitForDatabaseAsync(WebApplication app)
{
    var ds = app.Services.GetRequiredService<NpgsqlDataSource>();
    for (var attempt = 1; attempt <= 60; attempt++)
    {
        try
        {
            await using var conn = await ds.OpenConnectionAsync();
            await conn.ExecuteScalarAsync<int>("SELECT 1");
            app.Logger.LogInformation("Bridge database reachable after {Attempt} attempt(s)", attempt);
            return;
        }
        catch (Exception ex) when (attempt < 60)
        {
            app.Logger.LogWarning("Bridge database not ready ({Message}); retrying in 2s", ex.Message);
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
    }
    throw new InvalidOperationException("Bridge database unreachable after 60 attempts.");
}

namespace Bridge
{
    /// <summary>Npgsql returns DateTime for `date`; the HIS payload uses DateOnly.</summary>
    public sealed class DateOnlyTypeHandler : SqlMapper.TypeHandler<DateOnly>
    {
        public override DateOnly Parse(object value) => value switch
        {
            DateOnly d => d,
            DateTime dt => DateOnly.FromDateTime(dt),
            string s => DateOnly.Parse(s),
            _ => throw new InvalidCastException($"Cannot convert {value?.GetType().Name} to DateOnly")
        };

        public override void SetValue(System.Data.IDbDataParameter parameter, DateOnly value)
        {
            parameter.DbType = System.Data.DbType.Date;
            parameter.Value = value.ToDateTime(TimeOnly.MinValue);
        }
    }

    /// <summary>Npgsql returns a UTC DateTime for `timestamptz`.</summary>
    public sealed class DateTimeOffsetTypeHandler : SqlMapper.TypeHandler<DateTimeOffset>
    {
        public override DateTimeOffset Parse(object value) => value switch
        {
            DateTimeOffset dto => dto,
            DateTime dt => new DateTimeOffset(DateTime.SpecifyKind(dt, DateTimeKind.Utc)),
            string s => DateTimeOffset.Parse(s),
            _ => throw new InvalidCastException($"Cannot convert {value?.GetType().Name} to DateTimeOffset")
        };

        public override void SetValue(System.Data.IDbDataParameter parameter, DateTimeOffset value) =>
            parameter.Value = value.UtcDateTime;
    }
}
