FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    NVM_DIR=/home/dev/.nvm

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    openssh-client \
    sudo \
    git \
    curl \
    wget \
    tar \
    unzip \
    procps \
    ca-certificates \
    gnupg \
    libicu74 \
    libatomic1 \
    && wget -q https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm -f /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends dotnet-sdk-10.0 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd

# Переименовываем и юзера, и группу с UID/GID 1000 в dev
RUN if id -u 1000 >/dev/null 2>&1; then \
        OLD_USER=$(id -un 1000); \
        OLD_GROUP=$(id -gn 1000); \
        [ "$OLD_GROUP" != "dev" ] && groupmod -n dev "$OLD_GROUP"; \
        [ "$OLD_USER" != "dev" ] && usermod -l dev -g dev -d /home/dev -m "$OLD_USER"; \
    else \
        useradd -m -u 1000 -s /bin/bash dev; \
    fi \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev \
    && mkdir -p /home/dev/.ssh /home/dev/.vscode-server /home/dev/.nvm /home/dev/.nuget /workspace \
    && chown -R dev:dev /home/dev /workspace \
    && chmod 700 /home/dev/.ssh

# Ставим nvm, свежий Node LTS и pnpm в эталонную папку
ENV NVM_VERSION=v0.40.3
RUN mkdir -p /opt/nvm-seed \
    && NVM_DIR=/opt/nvm-seed bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash \
       && . /opt/nvm-seed/nvm.sh \
       && nvm install --lts \
       && nvm alias default 'lts/*' \
       && npm install -g pnpm" \
    && chown -R dev:dev /opt/nvm-seed

# Прописываем nvm и dotnet в .bashrc для интерактивных терминалов
RUN cat <<'EOF' >> /home/dev/.bashrc

export DOTNET_ROOT=/usr/share/dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF

# Сетевой стек отдельным слоем, чтобы не инвалидировать кэш .NET и nvm
RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq \
    ipset \
    redsocks \
    iptables \
    iproute2 \
    dnsutils \
    && rm -rf /var/lib/apt/lists/*

COPY authorized_keys /home/dev/.ssh/authorized_keys
COPY dnsmasq.conf /etc/dnsmasq.conf
COPY redsocks.conf /etc/redsocks.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN sed -i 's/\r$//' \
        /usr/local/bin/entrypoint.sh \
        /etc/dnsmasq.conf \
        /etc/redsocks.conf \
    && chown dev:dev /home/dev/.ssh/authorized_keys /home/dev/.bashrc \
    && chmod 600 /home/dev/.ssh/authorized_keys \
    && chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace
EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
