using System.Text.Json;
using Bridge;
using Dapper;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);

var options = BridgeOptions.FromEnvironment();

DefaultTypeMap.MatchNamesWithUnderscores = true;
SqlMapper.AddTypeHandler(new DateOnlyTypeHandler());
SqlMapper.AddTypeHandler(new DateTimeOffsetTypeHandler());

builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(o =>
{
    o.IncludeScopes = true;
    o.JsonWriterOptions = new JsonWriterOptions { Indented = false };
});

builder.Services.AddSingleton(options);
builder.Services.AddSingleton(_ => new NpgsqlDataSourceBuilder(options.ConnectionString).Build());
builder.Services.AddScoped<BridgeStore>();
builder.Services.AddSingleton<EventPublisher>();
builder.Services.AddHostedService<OrderConsumer>();
builder.Services.AddHostedService<ResultCorrelator>();

builder.Services.AddHttpClient("his-api", client =>
{
    client.BaseAddress = new Uri(options.HisApiBaseUrl);
    client.Timeout = TimeSpan.FromSeconds(15);
});

var app = builder.Build();

await WaitForDatabaseAsync(app);

// --- Operational surface ----------------------------------------------------

app.MapGet("/healthz", async (NpgsqlDataSource ds, CancellationToken ct) =>
{
    await using var conn = await ds.OpenConnectionAsync(ct);
    await conn.ExecuteScalarAsync<int>("SELECT 1");
    return Results.Ok(new
    {
        status = "ok",
        component = "bridge",
        fhirEndpoint = "/fhir",
        labOwner = options.LabOwnerReference
    });
});

// Useful during testing: shows exactly what the bridge is publishing for
// OpenELIS to poll, and what it could not correlate.
app.MapGet("/ops/orders", async (BridgeStore store, CancellationToken ct) =>
{
    var tasks = await store.SearchTasksAsync(null, null, null, ct);
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

app.MapGet("/ops/dead-letters", async (BridgeStore store, CancellationToken ct) =>
    Results.Ok(await store.GetDeadLettersAsync(ct)));

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
