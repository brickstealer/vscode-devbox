ARG BASE_IMAGE=vscode-devbox
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    g++ \
    gdb \
    clang \
    clangd \
    clang-format \
    clang-tidy \
    lldb \
    cmake \
    ninja-build \
    pkg-config \
    ccache \
    valgrind \
    && rm -rf /var/lib/apt/lists/*
