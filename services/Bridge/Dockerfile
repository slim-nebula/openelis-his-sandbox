FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY Bridge.csproj .
# --disable-parallel, and more patience than the defaults.
#
# NuGet fetches packages concurrently and abandons a download that receives no
# data for 60 seconds. On a slow or contended link — which includes this image
# building under emulation on Apple Silicon — the parallel streams starve each
# other, every large package trips that timeout at once, and the restore fails
# with what looks like "the feed is invalid". Serial downloads are slower on a
# fast link and are the difference between building and not building on a slow
# one.
ENV NUGET_ENABLE_ENHANCED_HTTP_RETRY=true \
    NUGET_ENHANCED_MAX_NETWORK_TRY_COUNT=10 \
    NUGET_ENHANCED_NETWORK_RETRY_DELAY_MILLISECONDS=2000
RUN dotnet restore --disable-parallel
COPY . .
RUN dotnet publish -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
# curl is the container's healthcheck and the sandbox test scripts' way in;
# the aspnet image ships no HTTP client at all.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app .
# No ASPNETCORE_URLS: the listeners are configured in code (MutualTls.Configure),
# because one of them needs a certificate and a client-certificate requirement
# that a URL string cannot express. Setting both would make Kestrel ignore one
# of them and say so only in a startup warning.
# The aspnet base image sets ASPNETCORE_HTTP_PORTS=8080, which Kestrel then
# reports it is overriding on every start. Cleared, because a warning printed
# at every boot is how people learn to stop reading warnings.
ENV ASPNETCORE_HTTP_PORTS= \
    DOTNET_gcServer=0
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "Bridge.dll"]
