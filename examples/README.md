# Примеры расширения образа (`examples/`)

В этой папке собраны готовые дочерние `Dockerfile` для добавления языков и тулчейнов поверх базового образа `vscode-devbox` (в котором уже настроены `SSH`, `SmartDNS`, `redsocks`, `iptables`, `.NET 10`, `Node.js LTS` и `pnpm`).

## Доступные конфигурации

| Файл | Тулчейн | Что устанавливается |
| :--- | :--- | :--- |
| [Dockerfile.python](Dockerfile.python) | **Python** | `python3`, `pip`, `venv`, `python3-dev`, `pipx`, `uv` / `uvx`, `build-essential` |
| [Dockerfile.rust](Dockerfile.rust) | **Rust** | `rustup`, `cargo`, `rustc`, `clippy`, `rustfmt`, `rust-analyzer`, `libssl-dev`, `cmake` |
| [Dockerfile.go](Dockerfile.go) | **Go** | `go` (`1.27.4` по умолчанию, `amd64`/`arm64`), `gofmt`, `gopls`, `dlv` |
| [Dockerfile.cpp](Dockerfile.cpp) | **C / C++** | `gcc`, `g++`, `gdb`, `clang`, `clangd`, `clang-format`, `clang-tidy`, `lldb`, `cmake`, `ninja-build`, `pkg-config`, `ccache`, `valgrind` |

---

## Как подключить к `docker-compose.yml`

Самый удобный способ — создать в корне репозитория файл `docker-compose.override.yml` (он уже добавлен в `.gitignore` и не мешает обновлениям из Git).

### Вариант 1: поверх локально собранного образа `vscode-devbox`

1. Соберите базовый образ один раз (если ещё не собран):
   ```bash
   docker compose build
   ```
2. Создайте `docker-compose.override.yml` (например, для Rust):
   ```yaml
   services:
     devbox:
       build:
         context: .
         dockerfile: examples/Dockerfile.rust
       image: vscode-devbox-rust:local
   ```
3. Запустите контейнер:
   ```bash
   docker compose up -d --build
   ```

### Вариант 2: поверх готового образа из GHCR (без локальной сборки базы)

```yaml
services:
  devbox:
    build:
      context: .
      dockerfile: examples/Dockerfile.python
      args:
        BASE_IMAGE: ghcr.io/brickstealer/vscode-devbox:v1.3.0
    image: vscode-devbox-python:local
```

### Вариант 3: ручная сборка через `docker build` + `.env`

```bash
docker build \
  -f examples/Dockerfile.go \
  --build-arg BASE_IMAGE=ghcr.io/brickstealer/vscode-devbox:v1.3.0 \
  --build-arg GO_VERSION=1.27.4 \
  -t vscode-devbox-go:local .
```

Затем укажите `DEVBOX_IMAGE=vscode-devbox-go:local` в `.env` и запустите `docker compose up -d`.

---

## Комбинирование нескольких тулчейнов

Можно либо скопировать нужные `RUN`-блоки в свой `Dockerfile.custom`, либо собирать образы цепочкой через `BASE_IMAGE`:

```bash
docker build -f examples/Dockerfile.python -t devbox-py:local .
docker build -f examples/Dockerfile.rust --build-arg BASE_IMAGE=devbox-py:local -t devbox-py-rust:local .
```

---

## Важные особенности базового образа

1. **Не переключайте `USER dev` в конце дочернего `Dockerfile`:**
   базовый `entrypoint.sh` запускается от `root`, чтобы настроить `iptables`, `redsocks`, `SmartDNS` и поднять `sshd`, а пользовательские сессии уже открываются под `dev`.
2. **`PATH` и `/etc/environment` для VS Code / SSH:**
   при старте `entrypoint.sh` перезаписывает `/etc/environment`, поэтому `ENV PATH=...` из дочернего `Dockerfile` не попадёт в неинтерактивные SSH-сессии и расширения VS Code. Пробрасывайте нужные CLI-бинарники (или симлинки) в `/usr/local/bin`, как сделано в примерах выше.
3. **Монтирование дополнительных томов кэша:**
   если хотите вынести кэш зависимостей в `./volumes/...` через `docker-compose.override.yml`, монтируйте только папки **кэша**, чтобы пустой том не перекрыл бинарники внутри образа:
   - Python (`uv` / `pip`): `/home/dev/.cache/uv`, `/home/dev/.cache/pip`
   - Rust (`cargo` — **не** монтируйте весь `/home/dev/.cargo`, иначе скроете `/home/dev/.cargo/bin`): `/home/dev/.cargo/registry`, `/home/dev/.cargo/git`
   - Go: `/home/dev/go/pkg/mod`, `/home/dev/.cache/go-build`

---

## Домены для `PROXY_EXTRA_DOMAINS` в `.env`

По умолчанию через SOCKS проксируются домены GitHub, Microsoft и Google. Если для установки пакетов или тулчейнов нужен прокси и к языковым реестрам, добавьте нужные домены в `.env`:

- **Python:** `PROXY_EXTRA_DOMAINS=pypi.org,files.pythonhosted.org,astral.sh`
- **Rust:** `PROXY_EXTRA_DOMAINS=crates.io,static.crates.io,rust-lang.org,rustup.rs`
- **Go:** `PROXY_EXTRA_DOMAINS=proxy.golang.org,sum.golang.org,storage.googleapis.com`

*(Для нескольких языков объедините домены через запятую в одну строку `PROXY_EXTRA_DOMAINS`.)*

---

## Полезные расширения VS Code

- **Python:** `ms-python.python`, `charliermarsh.ruff`
- **Rust:** `rust-lang.rust-analyzer`, `tamasfe.even-better-toml`
- **Go:** `golang.go`
- **C / C++:** `llvm-vs-code-extensions.vscode-clangd`, `ms-vscode.cmake-tools`, `vadimcn.vscode-lldb`
