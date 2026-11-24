ARG BASE_IMAGE=vscode-devbox
FROM ${BASE_IMAGE}

ARG GO_VERSION=1.27.4
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in \
        amd64|arm64) GO_ARCH="$ARCH" ;; \
        *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz \
    && rm -rf /usr/local/go \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm -f /tmp/go.tar.gz \
    && ln -sf /usr/local/go/bin/go /usr/local/bin/go \
    && ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# Ставим gopls и dlv в /usr/local/bin (доступны в неинтерактивном SSH/VS Code)
RUN GOBIN=/usr/local/bin /usr/local/go/bin/go install golang.org/x/tools/gopls@latest \
    && GOBIN=/usr/local/bin /usr/local/go/bin/go install github.com/go-delve/delve/cmd/dlv@latest \
    && /usr/local/go/bin/go clean -modcache -cache

RUN printf '\nexport PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"\n' >> /home/dev/.bashrc
