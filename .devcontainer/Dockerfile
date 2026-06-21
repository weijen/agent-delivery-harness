FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

USER root

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git gnupg jq lsb-release pipx shellcheck software-properties-common unzip wget && rm -rf /var/lib/apt/lists/*

# GitHub CLI from the official apt repository.
RUN mkdir -p -m 755 /etc/apt/keyrings && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && apt-get update && apt-get install -y --no-install-recommends gh && rm -rf /var/lib/apt/lists/*

# Azure CLI from the official Microsoft apt repository.
RUN mkdir -p -m 755 /etc/apt/keyrings && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg && chmod go+r /etc/apt/keyrings/microsoft.gpg && AZ_DIST=$(lsb_release -cs) && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${AZ_DIST} main" > /etc/apt/sources.list.d/azure-cli.list && apt-get update && apt-get install -y --no-install-recommends azure-cli && rm -rf /var/lib/apt/lists/*

# Terraform from the official HashiCorp apt repository.
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg && chmod go+r /etc/apt/keyrings/hashicorp.gpg && HASHI_DIST=$(lsb_release -cs) && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${HASHI_DIST} main" > /etc/apt/sources.list.d/hashicorp.list && apt-get update && apt-get install -y --no-install-recommends terraform && rm -rf /var/lib/apt/lists/*

# Astral uv (includes Python installer support).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && mv /root/.local/bin/uv /usr/local/bin/uv && rm -rf /root/.local

# TFLint binary installer and Checkov via pipx.
RUN curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash && pipx install checkov && ln -sf /root/.local/bin/checkov /usr/local/bin/checkov && rm -rf /root/.cache/pipx

USER vscode
