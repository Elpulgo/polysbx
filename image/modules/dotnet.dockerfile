# .NET 8 + 10 SDKs side by side. Both install into one dir; the `dotnet` muxer
# resolves by global.json or latest. libicu covers globalization.
RUN apt-get update && apt-get install -y --no-install-recommends libicu72 \
    && rm -rf /var/lib/apt/lists/* \
    && wget https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel 8.0  --install-dir /usr/share/dotnet \
    && /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet \
    && rm /tmp/dotnet-install.sh \
    && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet
ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1
# EF Core CLI on a fixed system tool-path (the default ~/.dotnet/tools is a tmpfs
# at runtime and would be wiped). A 10.x dotnet-ef manages EF Core 8 and 10.
RUN dotnet tool install dotnet-ef --version "10.*" --tool-path /usr/local/dotnet-tools
ENV PATH="/usr/local/dotnet-tools:$PATH"
