# Azure CLI via pip (cross-arch; Microsoft's apt repo is amd64-only) + the
# azure-devops extension. Auto-included when ADO integration is enabled.
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir --break-system-packages azure-cli \
    && az extension add --name azure-devops --system 2>/dev/null || true
