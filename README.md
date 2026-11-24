# VS Code Devbox

Docker-окружение на базе `Ubuntu 24.04` для удалённой разработки по SSH (VS Code Remote-SSH / Antigravity) с преднастроенным стеком разработки и опциональным селективным проксированием отдельных доменов через `redsocks`.

## Что внутри

- **ОС и доступ:** `ubuntu:24.04`, `openssh-server`, пользователь `dev` (`UID/GID 1000`) с беспарольным `sudo`.
- **Стек разработки:**
  - `.NET SDK 10.0` (`DOTNET_ROOT=/usr/share/dotnet`)
  - `nvm v0.40.3`, Node.js LTS и `pnpm` (шаблон в `/opt/nvm-seed`, разворачивается в volume `/home/dev/.nvm` при первом старте; симлинки прокидываются в `/usr/local/bin`)
  - `git`, `curl`, `wget`, `unzip`, `procps` и базовые утилиты
- **Селективный прокси (`PROXY_ENABLED=true` и задан `SOCKS_PROXY_HOST`):** `dnsmasq` + `ipset` + `redsocks` + `iptables`.
  - `dnsmasq` (`127.0.0.1`) использует `UPSTREAM_DNS`, фильтрует `AAAA`-записи и добавляет IP для доменов из `dnsmasq.conf` (и `PROXY_EXTRA_DOMAINS`) в `ipset` `special_proxy` (`timeout 300`).
  - `iptables` заворачивает TCP-трафик для IP из `special_proxy` в `redsocks` (`127.0.0.1:12345`) в обход локальных подсетей и блокирует QUIC (`UDP/443`).
  - `redsocks` перенаправляет этот трафик на прокси `SOCKS_PROXY_HOST:SOCKS_PROXY_PORT` (`SOCKS_PROXY_TYPE`).
  - Если `PROXY_ENABLED=false` или `SOCKS_PROXY_HOST` не задан, настройка прокси пропускается и используется прямое подключение.

## Структура

- `Dockerfile` — сборка образа `vscode-devbox`.
- `docker-compose.yml` — запуск контейнера, проброс SSH-порта, `cap_add: [NET_ADMIN]`, `environment` и volume.
- `.env.example` — шаблон локальных настроек окружения, сети, SSH и Git.
- `entrypoint.sh` — инициализация `nvm`, симлинков Node.js, SSH-ключа, `/home/dev/.gitconfig`, конфигов `dnsmasq`/`redsocks`, правил `ipset`/`iptables` и запуск `sshd`.
- `dnsmasq.conf` — базовый конфиг `dnsmasq` и список проксируемых доменов.
- `redsocks.conf` — базовый конфиг `redsocks`.
- `authorized_keys` — шаблон файла публичных SSH-ключей (ключи также можно передавать через `SSH_PUBLIC_KEY` в `.env`).

## Переменные `.env`

| Переменная | По умолчанию | Описание |
| :--- | :--- | :--- |
| `CONTAINER_NAME` | `vscode-devbox` | Имя контейнера Docker |
| `WORKSPACE_PATH` | `./workspace` | Путь к каталогу проектов на хосте, монтируемому в `/workspace` |
| `TZ` | `UTC` | Часовой пояс внутри контейнера |
| `SSH_BIND_IP` | `127.0.0.1` | Адрес на хосте для публикации SSH-порта |
| `SSH_PORT` | `2222` | Порт на хосте для подключения по SSH |
| `SSH_PUBLIC_KEY` | *(пусто)* | Публичный SSH-ключ, автоматически добавляемый в `/home/dev/.ssh/authorized_keys` |
| `GIT_USER_NAME` | *(пусто)* | `user.name` для `/home/dev/.gitconfig` |
| `GIT_USER_EMAIL` | *(пусто)* | `user.email` для `/home/dev/.gitconfig` |
| `UPSTREAM_DNS` | `1.1.1.1` | DNS-сервер контейнера и upstream для `dnsmasq` |
| `PROXY_ENABLED` | `true` | Включение селективного проксирования (`true` / `false`) |
| `SOCKS_PROXY_HOST` | *(пусто)* | IP или хостнейм прокси-сервера для `redsocks` |
| `SOCKS_PROXY_PORT` | `10808` | Порт прокси-сервера для `redsocks` |
| `SOCKS_PROXY_TYPE` | `socks5` | Тип прокси в `redsocks` (`socks5`, `socks4`, `http-connect`) |
| `PROXY_EXTRA_DOMAINS` | *(пусто)* | Дополнительные домены для `special_proxy` через запятую |

## Быстрый старт

1. Создайте `.env` из шаблона и укажите свои настройки (как минимум `SSH_PUBLIC_KEY` либо ключ в `authorized_keys`, `GIT_USER_NAME`, `GIT_USER_EMAIL`, а при использовании прокси — `UPSTREAM_DNS` и `SOCKS_PROXY_HOST`):
   ```bash
   cp .env.example .env
   ```
2. Соберите и запустите контейнер:
   ```bash
   docker compose up -d --build
   ```
3. Подключитесь по SSH:
   ```bash
   ssh -p 2222 dev@127.0.0.1
   ```

## Тома (volumes)

- `/workspace` — рабочий каталог с проектами (`WORKSPACE_PATH`).
- `./volumes/vscode-server` -> `/home/dev/.vscode-server` — кэш и расширения редактора.
- `./volumes/nvm` -> `/home/dev/.nvm` — версии Node.js и глобальные пакеты.
- `./volumes/nuget` -> `/home/dev/.nuget` — кэш пакетов NuGet.
