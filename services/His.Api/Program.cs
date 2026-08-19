using System.Text.Json;
using System.Text.Json.Serialization;
using Dapper;
using His.Api;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);

// --- Configuration: everything from the environment -------------------------
var connectionString = KafkaOptions.Env("HIS_DB_CONNECTION", "");
if (string.IsNullOrWhiteSpace(connectionString))
    throw new InvalidOperationException("HIS_DB_CONNECTION is required.");

var kafkaOptions = KafkaOptions.FromEnvironment();

// --- Dapper conventions -----------------------------------------------------
DefaultTypeMap.MatchNamesWithUnderscores = true;   // order_number -> OrderNumber
SqlMapper.AddTypeHandler(new DateOnlyTypeHandler());
SqlMapper.AddTypeHandler(new DateTimeOffsetTypeHandler());

builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(o =>
{
    o.IncludeScopes = true;
    o.JsonWriterOptions = new JsonWriterOptions { Indented = false };
});

builder.Services.AddSingleton(kafkaOptions);
builder.Services.AddSingleton(_ => new NpgsqlDataSourceBuilder(connectionString).Build());
builder.Services.AddScoped<Repository>();
builder.Services.AddScoped<CatalogueMirror>();
builder.Services.AddHttpClient();
builder.Services.AddSingleton<EventPublisher>();
builder.Services.AddHostedService<BridgeEventConsumer>();
builder.Services.AddHostedService<OutboxRelay>();
builder.Services.ConfigureHttpJsonOptions(o =>
{
    o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    o.SerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
});

var app = builder.Build();

// --- Correlation id ---------------------------------------------------------
// Kong stamps X-Correlation-ID at the edge. Anything arriving without one
// (the bridge calling /internal/*, or curl) gets one here so every log line and
// every event this request produces can be tied together.
app.Use(async (ctx, next) =>
{
    var correlationId = ctx.Request.Headers["X-Correlation-ID"].FirstOrDefault();
    if (string.IsNullOrWhiteSpace(correlationId)) correlationId = Guid.NewGuid().ToString();
    ctx.Items["CorrelationId"] = correlationId;
    ctx.Response.Headers["X-Correlation-ID"] = correlationId;

    using (app.Logger.BeginScope(new Dictionary<string, object> { ["correlationId"] = correlationId }))
        await next();
});

app.UseExceptionHandler(handler => handler.Run(async ctx =>
{
    var feature = ctx.Features.Get<Microsoft.AspNetCore.Diagnostics.IExceptionHandlerFeature>();
    var (status, message) = feature?.Error switch
    {
        DomainException de => (StatusCodes.Status400BadRequest, de.Message),
        _ => (StatusCodes.Status500InternalServerError, "Internal error")
    };
    if (status == StatusCodes.Status500InternalServerError)
        app.Logger.LogError(feature?.Error, "Unhandled exception");

    ctx.Response.StatusCode = status;
    await ctx.Response.WriteAsJsonAsync(new { error = message });
}));

await WaitForDatabaseAsync(app);

static string Correlation(HttpContext ctx) => (string)ctx.Items["CorrelationId"]!;

// =============================================================================
// Client-facing API — routed through the reverse proxy and Kong
// =============================================================================

app.MapGet("/healthz", async (NpgsqlDataSource ds, CancellationToken ct) =>
{
    await using var conn = await ds.OpenConnectionAsync(ct);
    await conn.ExecuteScalarAsync<int>("SELECT 1");
    return Results.Ok(new { status = "ok", component = "his-api" });
});

// Served from the local mirror, never live from the bridge: the ordering screen
// must keep working while the bridge restarts, and a menu one sync out of date
// beats an empty one.
app.MapGet("/test-catalogue", async (Repository repo, CancellationToken ct) =>
    Results.Ok(await repo.GetCatalogueAsync(ct)));

// Pulls the menu the bridge discovered in OpenELIS. Manual, like the sync
// behind it: the technician who enabled a test in the LIS is the person who
// presses this, and is there to read what changed.
app.MapPost("/admin/catalogue/refresh", async (
    CatalogueMirror mirror, CancellationToken ct) =>
{
    var bridgeUrl = KafkaOptions.Env("BRIDGE_INTERNAL_URL", "http://bridge:8080");
    var result = await mirror.RefreshAsync(bridgeUrl, ct);
    return result.Applied ? Results.Ok(result) : Results.Json(result, statusCode: StatusCodes.Status409Conflict);
});

app.MapPost("/patients", async (CreatePatientRequest req, Repository repo, CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(req.FirstName) || string.IsNullOrWhiteSpace(req.LastName))
        throw new DomainException("firstName and lastName are required.");

    var patient = await repo.CreatePatientAsync(req, ct);
    return Results.Created($"/patients/{patient.PatientId}", patient);
});

app.MapGet("/patients/search", async (string? q, int? limit, Repository repo, CancellationToken ct) =>
    Results.Ok(await repo.SearchPatientsAsync(q, Math.Clamp(limit ?? 25, 1, 200), ct)));

app.MapGet("/patients/{id:guid}", async (Guid id, Repository repo, CancellationToken ct) =>
    await repo.GetPatientAsync(id, ct) is { } p ? Results.Ok(p) : Results.NotFound());

app.MapGet("/patients/{id:guid}/lab-orders", async (Guid id, Repository repo, CancellationToken ct) =>
    Results.Ok(await repo.GetOrdersForPatientAsync(id, ct)));

app.MapGet("/patients/{id:guid}/results", async (Guid id, Repository repo, CancellationToken ct) =>
    Results.Ok(await repo.GetResultsForPatientAsync(id, ct)));

app.MapPost("/lab-orders", async (
    CreateLabOrderRequest req, Repository repo, HttpContext ctx, CancellationToken ct) =>
{
    var correlationId = Correlation(ctx);

    // Order row, audit row and the lab.order.created event all commit together;
    // the outbox relay puts the event on Kafka. Nothing here talks to the
    // broker, so a broker outage cannot fail an order or leave one undispatched.
    var (order, _) = await repo.CreateOrderAsync(req, correlationId, ct);
    return Results.Created($"/lab-orders/{order.OrderId}", order);
});

app.MapGet("/lab-orders/{id:guid}", async (Guid id, Repository repo, CancellationToken ct) =>
{
    var order = await repo.GetOrderAsync(id, ct);
    if (order is null) return Results.NotFound();
    var results = await repo.GetResultsForOrderAsync(id, ct);
    return Results.Ok(new { order, results });
});

// =============================================================================
// Internal API — bridge-facing only.
// Not routed by Kong: the bridge reaches this service directly over the sandbox
// network, so integration traffic never transits the public edge.
// =============================================================================

app.MapGet("/internal/patients/{id:guid}", async (Guid id, Repository repo, CancellationToken ct) =>
    await repo.GetPatientAsync(id, ct) is { } p ? Results.Ok(p) : Results.NotFound());

app.MapGet("/internal/lab-orders/{id:guid}", async (Guid id, Repository repo, CancellationToken ct) =>
    await repo.GetBridgePayloadAsync(id, ct) is { } payload ? Results.Ok(payload) : Results.NotFound());

app.MapPost("/internal/lab-results", async (
    ReleasedResultMessage msg, Repository repo, HttpContext ctx, CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(msg.OrderNumber) || string.IsNullOrWhiteSpace(msg.OpenelisResultRef))
        throw new DomainException("orderNumber and openelisResultRef are required.");

    var stored = await repo.UpsertResultAsync(
        msg with { CorrelationId = msg.CorrelationId ?? Correlation(ctx) }, ct);

    return stored ? Results.Accepted() : Results.NotFound(new { error = "Unknown order number." });
});

app.Run();
return;

// --- Startup ----------------------------------------------------------------
static async Task WaitForDatabaseAsync(WebApplication app)
{
    var ds = app.Services.GetRequiredService<NpgsqlDataSource>();
    for (var attempt = 1; attempt <= 60; attempt++)
    {
        try
        {
            await using var conn = await ds.OpenConnectionAsync();
            await conn.ExecuteScalarAsync<int>("SELECT 1");
            app.Logger.LogInformation("HIS database reachable after {Attempt} attempt(s)", attempt);
            return;
        }
        catch (Exception ex) when (attempt < 60)
        {
            app.Logger.LogWarning("HIS database not ready ({Message}); retrying in 2s", ex.Message);
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
    }
    throw new InvalidOperationException("HIS database unreachable after 60 attempts.");
}
