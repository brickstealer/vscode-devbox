# VS Code Devbox

Docker-окружение на базе `Ubuntu 24.04` для удалённой разработки по SSH (VS Code Remote-SSH / Antigravity) с преднастроенным стеком разработки, `SmartDNS` (с поддержкой DoH/DoT) и опциональным селективным проксированием отдельных доменов через `redsocks`.

## Что внутри

- **ОС и доступ:** `ubuntu:24.04`, `openssh-server`, пользователь `dev` (`UID/GID 1000`) с беспарольным `sudo`.
- **Стек разработки:**
  - `.NET SDK 10.0` (`DOTNET_ROOT=/usr/share/dotnet`)
  - `nvm v0.40.3`, Node.js LTS и `pnpm` (шаблон в `/opt/nvm-seed`, разворачивается в volume `/home/dev/.nvm` при первом старте; симлинки прокидываются в `/usr/local/bin`)
  - `git`, `curl`, `wget`, `unzip`, `procps` и базовые утилиты
- **DNS (`SmartDNS`):**
  - Слушает `127.0.0.1:53` (UDP/TCP), отключает IPv6 (`force-AAAA-SOA yes`) и записи `SVCB`/`HTTPS` (`force-qtype-SOA 64 65`), работает с `speed-check-mode none` (чтобы не конфликтовать с проксированием).
  - Раздельно управляет временем жизни DNS-кэша и ответов клиентам (`DNS_CACHE_TTL`, по умолчанию `300` сек; отключается через `DNS_CACHE_ENABLED=false`) и сроком жизни IP в `ipset special_proxy` (`IPSET_TTL`, по умолчанию `3600` сек = 1 час), чтобы исключить гонки на границе TTL и протухание `ipset` при долгом кэше в приложениях.
  - При `DNS_FORCE_REDIRECT=true` (по умолчанию) запускается с отдельной группой `smartdns`: `iptables` заворачивает любые сторонние запросы `UDP/TCP 53` в локальный `SmartDNS` и блокирует обход через внешний `DoT/DoQ (853)` и известные публичные `DoH (443)`, оставляя самому `SmartDNS` полный доступ к апстримам и DoH/DoT.
  - Поддерживает обычный DNS (`server`), **DoH** (`https://...`), **DoT** (`tls://...`) и при необходимости маршрутизацию DoH/DoT через SOCKS5 (`DNS_ENCRYPTED_VIA_SOCKS=true`).
  - Если `UPSTREAM_DNS` и `DNS_ENCRYPTED_SERVERS` в `.env` не заданы, `SmartDNS` просто читает конфигурацию апстримов напрямую из `smartdns.conf`.
- **Селективный прокси (`redsocks` + `iptables` + `ipset`):**
  - `SmartDNS` добавляет IP для доменов из `smartdns.conf` (и `PROXY_EXTRA_DOMAINS`) в `ipset` `special_proxy`.
  - `iptables` заворачивает TCP-трафик для IP из `special_proxy` в `redsocks` (`127.0.0.1:12345`) в обход локальных подсетей и блокирует (`REJECT`) весь исходящий `UDP` (QUIC, WebRTC и др.) к этим IP, исключая утечки мимо SOCKS.
  - IPv6 полностью блокируется в контейнере через `sysctls` и `ip6tables` (`IPV6_BLOCK`), чтобы трафик не обходил правила IPv4.
  - Работает в режиме **fail-closed**: если `PROXY_ENABLED=true`, но `SOCKS_PROXY_HOST` (или `ip` в `redsocks.conf`) не настроен либо `redsocks` не запустился, контейнер завершается с ошибкой вместо тихого пропуска трафика напрямую.
- **Логирование (`VERBOSE_LOGS`):**
  - По умолчанию (`VERBOSE_LOGS=true`) в `docker logs` выводятся подробные шаги инициализации контейнера, входы/отключения `sshd` (`-e`), запросы и ответы `SmartDNS` (`log-console yes`, `log-level info`) и проксируемые соединения `redsocks`. При `VERBOSE_LOGS=false` подробный вывод полностью отключается.

## Структура

- `Dockerfile` — сборка образа `vscode-devbox` (включая установку `SmartDNS` с проверкой SHA-256).
- `docker-compose.yml` — запуск контейнера, проброс SSH-порта, `cap_add: [NET_ADMIN]`, `environment` и volume.
- `.env.example` — шаблон локальных настроек окружения, сети, DoH/DoT, SSH и Git.
- `entrypoint.sh` — инициализация `nvm`, симлинков Node.js, SSH-ключа, `/home/dev/.gitconfig`, применение параметров `.env` (если заданы), настройка `iptables`/`redsocks` и запуск `smartdns` + `sshd`.
- `smartdns.conf` — конфиг `SmartDNS`, правила `ipset` и секция апстримов по умолчанию.
- `redsocks.conf` — базовый конфиг `redsocks`.
- `authorized_keys` — шаблон файла публичных SSH-ключей (ключи также можно передавать через `SSH_PUBLIC_KEY` в `.env`).
- [`examples/`](examples/README.md) — готовые примеры дочерних `Dockerfile` для добавления тулчейнов **Python**, **Rust**, **Go** и **C/C++** поверх базового образа.

## Переменные `.env`

Если параметры DNS или прокси оставить пустыми, контейнер использует настройки напрямую из `smartdns.conf` и `redsocks.conf`.

| Переменная | По умолчанию | Описание |
| :--- | :--- | :--- |
| `DEVBOX_IMAGE` | `vscode-devbox` | Docker-образ (по умолчанию локальный; можно указать образ из GHCR) |
| `CONTAINER_NAME` | `vscode-devbox` | Имя контейнера Docker |
| `WORKSPACE_PATH` | `./workspace` | Путь к каталогу проектов на хосте, монтируемому в `/workspace` |
| `TZ` | `UTC` | Часовой пояс внутри контейнера |
| `VERBOSE_LOGS` | `true` | Подробные логи старта, `sshd`, `SmartDNS` и `redsocks` в `docker logs` (`true` / `false`) |
| `SSH_BIND_IP` | `127.0.0.1` | Адрес на хосте для публикации SSH-порта |
| `SSH_PORT` | `2222` | Порт на хосте для подключения по SSH |
| `SSH_PUBLIC_KEY` | *(пусто)* | Публичный SSH-ключ, автоматически добавляемый в `/home/dev/.ssh/authorized_keys` |
| `GIT_USER_NAME` | *(пусто)* | `user.name` для `/home/dev/.gitconfig` |
| `GIT_USER_EMAIL` | *(пусто)* | `user.email` для `/home/dev/.gitconfig` |
| `UPSTREAM_DNS` | *(пусто; в compose `1.1.1.1`)* | Обычный DNS-сервер (IP); при использовании `DNS_ENCRYPTED_SERVERS` служит `-bootstrap-dns` |
| `DNS_ENCRYPTED_SERVERS` | *(пусто)* | DoH/DoT серверы через запятую (`https://...`, `tls://...`) |
| `DNS_ENCRYPTED_VIA_SOCKS` | `false` | Проксировать DoH/DoT-запросы `SmartDNS` через SOCKS5 (`true` / `false`) |
| `DNS_CACHE_ENABLED` | `true` | Включить локальный DNS-кэш `SmartDNS` (`true` / `false`; при `false` каждый запрос идёт на апстрим) |
| `DNS_CACHE_TTL` | `300` | Время жизни (в секундах) записей DNS-кэша `SmartDNS` и TTL в ответах клиентам |
| `IPSET_TTL` | `3600` | Время жизни (в секундах) IP-адресов в `ipset special_proxy` (независимо от `DNS_CACHE_TTL`) |
| `DNS_FORCE_REDIRECT` | `true` | Принудительный заворот `UDP/TCP 53` в `SmartDNS` и блокировка обхода через внешний `DoT (853)` / публичные `DoH` |
| `PROXY_EXTRA_DOMAINS` | *(пусто)* | Дополнительные домены для `special_proxy` через запятую |
| `PROXY_ENABLED` | `true` | Включение селективного проксирования (`true` / `false`; при `true` требует валидный прокси — *fail-closed*) |
| `SOCKS_PROXY_HOST` | *(пусто)* | IP или хостнейм прокси-сервера для `redsocks` (обязателен при `PROXY_ENABLED=true`, если не задан в `redsocks.conf`) |
| `SOCKS_PROXY_PORT` | `10808` | Порт прокси-сервера для `redsocks` |
| `SOCKS_PROXY_TYPE` | `socks5` | Тип прокси в `redsocks` (`socks5`, `socks4`, `http-connect`) |

## Быстрый старт

1. Создайте `.env` из шаблона и укажите свои настройки (включая `SSH_PUBLIC_KEY` либо ключ в `authorized_keys`; если контейнер запускается на удалённом сервере, а не локально — задайте `SSH_BIND_IP=0.0.0.0`):
   ```bash
   cp .env.example .env
   ```
2. Соберите и запустите контейнер:
   ```bash
   docker compose up -d --build
   ```
3. Подключитесь по SSH или через VS Code (подробная инструкция ниже):
   ```bash
   ssh -p 2222 dev@127.0.0.1
   ```

## Подключение из VS Code (Windows и Linux)

### 1. Генерация SSH-ключа

Если у вас уже есть ключ (например, `~/.ssh/id_ed25519`), можно использовать его публичную часть (`.pub`). Чтобы создать отдельный ключ под devbox:

**Linux (терминал):**
```bash
ssh-keygen -t ed25519 -C "dev@vscode-devbox" -f ~/.ssh/id_ed25519_devbox
cat ~/.ssh/id_ed25519_devbox.pub
```

**Windows (PowerShell):**
```powershell
mkdir -Force "$env:USERPROFILE\.ssh"
ssh-keygen -t ed25519 -C "dev@vscode-devbox" -f "$env:USERPROFILE\.ssh\id_ed25519_devbox"
Get-Content "$env:USERPROFILE\.ssh\id_ed25519_devbox.pub"
```

Скопируйте выведенную строку `ssh-ed25519 AAAA...` в переменную `SSH_PUBLIC_KEY="..."` внутри `.env` на хосте с Docker (либо в файл `authorized_keys` до сборки) и запустите/пересоздайте контейнер (`docker compose up -d`).

> Если ключ создан с парольной фразой (passphrase), добавьте его в `ssh-agent`, чтобы VS Code не запрашивал её при каждом переподключении:
> - **Linux:** `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519_devbox`
> - **Windows (PowerShell от администратора — один раз для включения службы):**
>   `Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent`
>   затем в обычном PowerShell: `ssh-add "$env:USERPROFILE\.ssh\id_ed25519_devbox"`

### 2. Настройка SSH-конфига (`~/.ssh/config`)

Если контейнер работает на этой же машине (Linux или Docker Desktop / WSL2 на Windows), используйте `HostName 127.0.0.1`. Если контейнер запущен на другом сервере в сети — укажите IP сервера (и проверьте, что в `.env` контейнера задан `SSH_BIND_IP=0.0.0.0`).

**Linux (`~/.ssh/config`):**
```ssh-config
Host vscode-devbox
    HostName 127.0.0.1
    Port 2222
    User dev
    IdentityFile ~/.ssh/id_ed25519_devbox
    IdentitiesOnly yes
    ForwardAgent yes
```
Проверьте права на файл конфигурации:
```bash
chmod 700 ~/.ssh && chmod 600 ~/.ssh/config
```

**Windows (`C:\Users\<ИмяПользователя>\.ssh\config`):**

Откройте файл в редакторе (например, в PowerShell: `notepad "$env:USERPROFILE\.ssh\config"`) и добавьте:
```ssh-config
Host vscode-devbox
    HostName 127.0.0.1
    Port 2222
    User dev
    IdentityFile ~/.ssh/id_ed25519_devbox
    IdentitiesOnly yes
    ForwardAgent yes
```
*(В Windows OpenSSH пути вида `~/.ssh/...` или `C:/Users/<Имя>/.ssh/...` с прямыми слэшами работают штатно.)*

Проверьте подключение из терминала / PowerShell:
```bash
ssh vscode-devbox
```

> **После пересоздания контейнера (`docker compose down && docker compose up -d`):** SSH host-ключи внутри контейнера генерируются заново, поэтому SSH предупредит об изменении ключа (`REMOTE HOST IDENTIFICATION HAS CHANGED`). Сбросьте старый отпечаток командой:
> ```bash
> ssh-keygen -R "[127.0.0.1]:2222"
> ```
> Либо для **локального** стенда (`127.0.0.1`) можно добавить в блок `Host vscode-devbox` строки `StrictHostKeyChecking no` и `UserKnownHostsFile /dev/null` (на Linux) или `UserKnownHostsFile NUL` (на Windows).

### 3. Подключение в VS Code / Antigravity

1. Установите в VS Code расширение **Remote - SSH** (`ms-vscode-remote.remote-ssh`). В **Antigravity** поддержка Remote-SSH доступна сразу.
2. Нажмите `F1` (или `Ctrl+Shift+P`) и выберите **Remote-SSH: Connect to Host...** -> **`vscode-devbox`**.
3. Если VS Code (особенно на Windows) спросит тип ОС удалённого хоста — выберите **Linux**. Чтобы отключить повторный запрос, можно добавить в локальный `settings.json` клиента:
   ```json
   "remote.SSH.remotePlatform": {
     "vscode-devbox": "linux"
   }
   ```
4. После подключения откройте рабочую директорию: **File -> Open Folder...** -> `/workspace`.
5. *(Для Antigravity внутри контейнера)*: так как стандартные профили Docker блокируют вложенные kernel namespaces песочницы терминала, в настройках прав Antigravity (`Settings -> General -> Global Permissions -> Permission Preset`) выберите **Turbo** или **Request Review**.

## Тома (volumes)

- `/workspace` — рабочий каталог с проектами (`WORKSPACE_PATH`).
- `./volumes/vscode-server` -> `/home/dev/.vscode-server` — кэш и расширения редактора.
- `./volumes/gemini` -> `/home/dev/.gemini` — настройки, сессии и токен Antigravity.
- `./volumes/antigravity-config` -> `/home/dev/.config/antigravity` — конфигурация учётных данных Antigravity.
- `./volumes/nvm` -> `/home/dev/.nvm` — версии Node.js и глобальные пакеты.
- `./volumes/nuget` -> `/home/dev/.nuget` — кэш пакетов NuGet.

## CI/CD и релизы (GitHub Actions)

- **[ci.yml](.github/workflows/ci.yml)** — запускается на `push` и `pull_request` в `main`: проверяет `entrypoint.sh` (`bash -n`, `shellcheck`), окончания строк `LF`, валидность `docker-compose.yml` и тестовую сборку `Dockerfile`.
- **[release.yml](.github/workflows/release.yml)** — запускается по пушу тега `v*` (например, `git tag v1.0.0 && git push origin v1.0.0`):
  - собирает и публикует образ в GitHub Container Registry (`ghcr.io/<owner>/<repo>`);
  - создаёт GitHub Release с архивом конфигураций `vscode-devbox-<tag>.tar.gz`, файлом контрольной суммы `.sha256` и сгенерированным changelog.
  - если тег содержит суффикс (например, `v1.0.0-rc.1`), релиз автоматически помечается как pre-release без обновления тега `latest`.
