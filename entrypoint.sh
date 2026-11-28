#!/usr/bin/env bash
set -e

NVM_DIR="/home/dev/.nvm"
GIT_CONFIG_FILE="${GIT_CONFIG_FILE:-/home/dev/.gitconfig}"
SSH_AUTH_KEYS_FILE="${SSH_AUTH_KEYS_FILE:-/home/dev/.ssh/authorized_keys}"
SMARTDNS_CONF_FILE="${SMARTDNS_CONF_FILE:-/etc/smartdns/smartdns.conf}"
SMARTDNS_PID_FILE="${SMARTDNS_PID_FILE:-/run/smartdns.pid}"
SMARTDNS_GROUP="${SMARTDNS_GROUP:-smartdns}"
REDSOCKS_CONF_FILE="${REDSOCKS_CONF_FILE:-/etc/redsocks.conf}"

is_truthy() {
    case "${1:-}" in
        true|TRUE|1|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

log_info() {
    if is_truthy "${VERBOSE_LOGS:-true}"; then
        printf '[%s] [entrypoint] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    fi
}

validate_ttl() {
    local var_name="$1"
    local ttl="$2"
    local extra_hint="${3:-}"
    if [[ ! "$ttl" =~ ^[1-9][0-9]*$ ]] || [ "$ttl" -gt 2147483 ]; then
        echo "Error: ${var_name} must be an integer between 1 and 2147483 seconds (got '${ttl}').${extra_hint}" >&2
        return 1
    fi
    printf '%s\n' "$ttl"
}

get_dns_cache_ttl() {
    validate_ttl "DNS_CACHE_TTL" "${DNS_CACHE_TTL:-300}" " To disable DNS cache, set DNS_CACHE_ENABLED=false."
}

get_ipset_ttl() {
    validate_ttl "IPSET_TTL" "${IPSET_TTL:-3600}"
}

configure_ssh_keys() {
    if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
        local ssh_dir
        ssh_dir="$(dirname "$SSH_AUTH_KEYS_FILE")"
        mkdir -p "$ssh_dir"
        touch "$SSH_AUTH_KEYS_FILE"
        if ! grep -qxF "$SSH_PUBLIC_KEY" "$SSH_AUTH_KEYS_FILE" 2>/dev/null; then
            printf '%s\n' "$SSH_PUBLIC_KEY" >> "$SSH_AUTH_KEYS_FILE"
        fi
        chmod 700 "$ssh_dir"
        chmod 600 "$SSH_AUTH_KEYS_FILE"
        if id -u dev >/dev/null 2>&1; then
            chown -R dev:dev "$ssh_dir"
        fi
    fi
}

configure_git() {
    local key val env_var kv map
    for kv in "init.defaultBranch:main" "core.filemode:false"; do
        key="${kv%%:*}"
        val="${kv#*:}"
        if ! git config --file "$GIT_CONFIG_FILE" --get "$key" >/dev/null 2>&1; then
            git config --file "$GIT_CONFIG_FILE" "$key" "$val"
        fi
    done
    for map in "user.name:GIT_USER_NAME" "user.email:GIT_USER_EMAIL"; do
        key="${map%%:*}"
        env_var="${map#*:}"
        val="${!env_var:-}"
        if [ -n "$val" ]; then
            git config --file "$GIT_CONFIG_FILE" "$key" "$val"
        fi
    done
    if [ -f "$GIT_CONFIG_FILE" ] && id -u dev >/dev/null 2>&1; then
        chown dev:dev "$GIT_CONFIG_FILE"
    fi
}

resolve_ipv4() {
    local target="$1"
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$target"
        return 0
    fi
    local ip
    ip="$(getent ahostsv4 "$target" 2>/dev/null | awk 'NR==1 { print $1 }')"
    if [ -z "$ip" ]; then
        echo "Error: failed to resolve '$target' to an IPv4 address" >&2
        return 1
    fi
    printf '%s\n' "$ip"
}

read_redsocks_value() {
    local key="$1"
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([^;[:space:]]*\).*/\1/p" "$REDSOCKS_CONF_FILE" | head -n 1
}

get_configured_socks_ip() {
    local conf_ip
    conf_ip="$(read_redsocks_value ip)"
    if [ -n "$conf_ip" ] && [ "$conf_ip" != "127.0.0.1" ] && [ "$conf_ip" != "0.0.0.0" ]; then
        printf '%s\n' "$conf_ip"
        return 0
    fi
    return 1
}

# Возвращает 0, если прокси для redsocks реально сконфигурирован (через .env или вручную в redsocks.conf)
configure_redsocks_file() {
    local redsocks_log_info="off"
    local redsocks_daemon="on"
    if is_truthy "${VERBOSE_LOGS:-true}"; then
        redsocks_log_info="on"
        redsocks_daemon="off"
    fi

    sed -i \
        -e "s|^\([[:space:]]*log_info[[:space:]]*=[[:space:]]*\).*|\1${redsocks_log_info};|" \
        -e "s|^\([[:space:]]*daemon[[:space:]]*=[[:space:]]*\).*|\1${redsocks_daemon};|" \
        "$REDSOCKS_CONF_FILE"

    if [ -n "${SOCKS_PROXY_HOST:-}" ]; then
        local socks_ip socks_port socks_type
        socks_ip="$(resolve_ipv4 "$SOCKS_PROXY_HOST")"
        socks_port="${SOCKS_PROXY_PORT:-10808}"
        socks_type="${SOCKS_PROXY_TYPE:-socks5}"

        sed -i \
            -e "s|^\([[:space:]]*ip[[:space:]]*=[[:space:]]*\).*|\1${socks_ip};|" \
            -e "s|^\([[:space:]]*port[[:space:]]*=[[:space:]]*\).*|\1${socks_port};|" \
            -e "s|^\([[:space:]]*type[[:space:]]*=[[:space:]]*\).*|\1${socks_type};|" \
            "$REDSOCKS_CONF_FILE"
        return 0
    fi

    # Если в .env SOCKS_PROXY_HOST пустой — читаем redsocks.conf как есть (кроме плейсхолдера 127.0.0.1)
    get_configured_socks_ip >/dev/null
}

replace_smartdns_upstreams_block() {
    local block="$1"
    local tmp_conf
    tmp_conf="$(mktemp)"
    awk -v block="$block" '
        BEGIN { in_block = 0; replaced = 0 }
        /^# --- BEGIN UPSTREAMS/ {
            print "# --- BEGIN UPSTREAMS (auto-managed when .env DNS vars are set) ---"
            printf "%s", block
            print "# --- END UPSTREAMS ---"
            in_block = 1
            replaced = 1
            next
        }
        /^# --- END UPSTREAMS/ { in_block = 0; next }
        !in_block { print }
        END {
            if (!replaced) {
                printf "\n# --- BEGIN UPSTREAMS (auto-managed when .env DNS vars are set) ---\n%s# --- END UPSTREAMS ---\n", block
            }
        }
    ' "$SMARTDNS_CONF_FILE" > "$tmp_conf" && mv "$tmp_conf" "$SMARTDNS_CONF_FILE"
}

configure_smartdns_file() {
    local cache_ttl="${1:-}"
    local cache_block=""
    local log_block=""
    local upstream_block=""
    local tmp_conf

    if [ -z "$cache_ttl" ]; then
        cache_ttl="$(get_dns_cache_ttl)"
    fi

    if is_truthy "${DNS_CACHE_ENABLED:-true}"; then
        cache_block="cache-size 4096"$'\n'
        cache_block="${cache_block}cache-persist no"$'\n'
        cache_block="${cache_block}serve-expired no"$'\n'
        cache_block="${cache_block}rr-ttl ${cache_ttl}"$'\n'
        cache_block="${cache_block}rr-ttl-reply-max ${cache_ttl}"$'\n'
        cache_block="${cache_block}ipset-timeout no"$'\n'
    else
        cache_block="cache-size 0"$'\n'
        cache_block="${cache_block}cache-persist no"$'\n'
        cache_block="${cache_block}serve-expired no"$'\n'
        cache_block="${cache_block}rr-ttl-reply-max 1"$'\n'
        cache_block="${cache_block}ipset-timeout no"$'\n'
    fi

    if is_truthy "${VERBOSE_LOGS:-true}"; then
        log_block="log-level info"$'\n'
        log_block="${log_block}log-console yes"$'\n'
    else
        log_block="log-level warn"$'\n'
        log_block="${log_block}log-console no"$'\n'
    fi
    log_block="${log_block}log-file /var/log/smartdns/smartdns.log"$'\n'
    log_block="${log_block}log-size 128k"$'\n'
    log_block="${log_block}log-num 2"$'\n'

    tmp_conf="$(mktemp)"
    awk -v cblock="$cache_block" -v lblock="$log_block" '
        BEGIN { in_cache = 0; replaced_cache = 0; in_log = 0; replaced_log = 0 }
        /^# --- BEGIN CACHE/ {
            print "# --- BEGIN CACHE (auto-managed from .env) ---"
            printf "%s", cblock
            print "# --- END CACHE ---"
            in_cache = 1
            replaced_cache = 1
            next
        }
        /^# --- END CACHE/ { in_cache = 0; next }
        /^# --- BEGIN LOGGING/ {
            print "# --- BEGIN LOGGING (auto-managed from .env) ---"
            printf "%s", lblock
            print "# --- END LOGGING ---"
            in_log = 1
            replaced_log = 1
            next
        }
        /^# --- END LOGGING/ { in_log = 0; next }
        (in_cache || in_log) { next }
        /^[[:space:]]*(cache-size|cache-persist|serve-expired|rr-ttl|rr-ttl-reply-max|ipset-timeout)[[:space:]]/ { next }
        /^[[:space:]]*(log-level|log-console|log-file|log-size|log-num)[[:space:]]/ { next }
        { print }
        END {
            if (!replaced_cache) {
                printf "\n# --- BEGIN CACHE (auto-managed from .env) ---\n%s# --- END CACHE ---\n", cblock
            }
            if (!replaced_log) {
                printf "\n# --- BEGIN LOGGING (auto-managed from .env) ---\n%s# --- END LOGGING ---\n", lblock
            }
        }
    ' "$SMARTDNS_CONF_FILE" > "$tmp_conf" && mv "$tmp_conf" "$SMARTDNS_CONF_FILE"

    if ! grep -Eq '^[[:space:]]*bind-tcp[[:space:]]' "$SMARTDNS_CONF_FILE" 2>/dev/null; then
        printf '\nbind-tcp 127.0.0.1:53\n' >> "$SMARTDNS_CONF_FILE"
    fi

    if ! grep -Eq '^[[:space:]]*force-qtype-SOA[[:space:]]' "$SMARTDNS_CONF_FILE" 2>/dev/null; then
        printf '\nforce-qtype-SOA 64 65\n' >> "$SMARTDNS_CONF_FILE"
    fi

    local proxy_all_dns=false
    if is_truthy "${PROXY_ENABLED:-true}" && is_truthy "${PROXY_ALL:-false}"; then
        proxy_all_dns=true
    fi

    # Обновляем блок апстримов, если заданы DNS-переменные в .env или включён PROXY_ALL=true;
    # иначе SmartDNS читает настройки серверов напрямую из smartdns.conf
    if [ -n "${UPSTREAM_DNS:-}" ] || [ -n "${DNS_ENCRYPTED_SERVERS:-}" ] || [ "$proxy_all_dns" = "true" ]; then
        local proxy_flag=""
        local socks_ip socks_port socks_type
        local want_dns_via_socks=false

        if [ "$proxy_all_dns" = "true" ] || { [ -n "${DNS_ENCRYPTED_SERVERS:-}" ] && is_truthy "${DNS_ENCRYPTED_VIA_SOCKS:-false}"; }; then
            want_dns_via_socks=true
        fi

        if [ "$want_dns_via_socks" = "true" ]; then
            socks_ip="$(get_configured_socks_ip || true)"
            socks_port="$(read_redsocks_value port)"
            socks_type="$(read_redsocks_value type)"
            if [ -n "$socks_ip" ] && [ "$socks_type" = "socks5" ]; then
                upstream_block="${upstream_block}proxy-server socks5://${socks_ip}:${socks_port:-10808} -name env_socks"$'\n'
                proxy_flag=" -proxy env_socks"
            else
                echo "Warning: DNS via SOCKS requested, but no active SOCKS5 proxy is configured; using direct DNS upstreams" >&2
            fi
        fi

        if [ -n "${DNS_ENCRYPTED_SERVERS:-}" ]; then
            local bootstrap_ip="${UPSTREAM_DNS:-1.1.1.1}"
            if [ -n "$proxy_flag" ]; then
                upstream_block="${upstream_block}server-tcp ${bootstrap_ip} -bootstrap-dns -exclude-default-group${proxy_flag}"$'\n'
            else
                upstream_block="${upstream_block}server ${bootstrap_ip} -bootstrap-dns -exclude-default-group"$'\n'
            fi

            local srv
            while IFS= read -r srv; do
                [ -z "$srv" ] && continue
                upstream_block="${upstream_block}server ${srv}${proxy_flag}"$'\n'
            done < <(tr ',' ' ' <<< "$DNS_ENCRYPTED_SERVERS" | tr -s '[:space:]' '\n')
        else
            local plain_dns="${UPSTREAM_DNS:-1.1.1.1}"
            if [ -n "$proxy_flag" ]; then
                upstream_block="${upstream_block}server-tcp ${plain_dns}${proxy_flag}"$'\n'
            else
                upstream_block="${upstream_block}server ${plain_dns}"$'\n'
            fi
        fi

        replace_smartdns_upstreams_block "$upstream_block"
    elif grep -q ' -name env_socks$' "$SMARTDNS_CONF_FILE" 2>/dev/null; then
        replace_smartdns_upstreams_block "server 1.1.1.1"$'\n'
    fi

    if [ -n "${PROXY_EXTRA_DOMAINS:-}" ]; then
        local domain rule
        while IFS= read -r domain; do
            domain="${domain#.}"
            [ -z "$domain" ] && continue
            rule="ipset /${domain}/special_proxy"
            if ! grep -qxF "$rule" "$SMARTDNS_CONF_FILE" 2>/dev/null; then
                printf '%s\n' "$rule" >> "$SMARTDNS_CONF_FILE"
            fi
        done < <(tr ',' ' ' <<< "$PROXY_EXTRA_DOMAINS" | tr -s '[:space:]' '\n')
    fi
}

disable_ipv6() {
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D OUTPUT -j IPV6_BLOCK 2>/dev/null || true
        ip6tables -D FORWARD -j IPV6_BLOCK 2>/dev/null || true
        ip6tables -F IPV6_BLOCK 2>/dev/null || true
        ip6tables -X IPV6_BLOCK 2>/dev/null || true

        if ip6tables -N IPV6_BLOCK 2>/dev/null; then
            ip6tables -A IPV6_BLOCK -o lo -j ACCEPT
            ip6tables -A IPV6_BLOCK -j REJECT
            ip6tables -I OUTPUT -j IPV6_BLOCK
            ip6tables -I FORWARD -j IPV6_BLOCK
        fi
    fi
}

cleanup_proxy_iptables() {
    iptables -t nat -D OUTPUT -p tcp -m owner ! --gid-owner "$SMARTDNS_GROUP" -j SPECIAL_PROXY 2>/dev/null || true
    iptables -t nat -D OUTPUT -p tcp -j SPECIAL_PROXY 2>/dev/null || true
    iptables -t nat -D PREROUTING -p tcp -j SPECIAL_PROXY 2>/dev/null || true
    iptables -t nat -F SPECIAL_PROXY 2>/dev/null || true
    iptables -t nat -X SPECIAL_PROXY 2>/dev/null || true

    iptables -D OUTPUT -p udp -m owner ! --gid-owner "$SMARTDNS_GROUP" -j SPECIAL_PROXY_UDP 2>/dev/null || true
    iptables -D FORWARD -p udp -j SPECIAL_PROXY_UDP 2>/dev/null || true
    iptables -F SPECIAL_PROXY_UDP 2>/dev/null || true
    iptables -X SPECIAL_PROXY_UDP 2>/dev/null || true

    # Legacy single-rule cleanup
    iptables -D OUTPUT -p udp --dport 443 -m set --match-set special_proxy dst -j REJECT 2>/dev/null || true
    iptables -D FORWARD -p udp --dport 443 -m set --match-set special_proxy dst -j REJECT 2>/dev/null || true
}

setup_proxy_iptables() {
    local ipset_ttl="${1:-}"
    local socks_ip
    if [ -z "$ipset_ttl" ]; then
        ipset_ttl="$(get_ipset_ttl)"
    fi
    socks_ip="$(get_configured_socks_ip || true)"

    cleanup_proxy_iptables

    # Create or atomically update ipset so timeout always matches IPSET_TTL
    if ipset list -t special_proxy >/dev/null 2>&1; then
        ipset destroy special_proxy_tmp 2>/dev/null || true
        ipset create special_proxy_tmp hash:ip timeout "$ipset_ttl"
        ipset swap special_proxy_tmp special_proxy
        ipset destroy special_proxy_tmp
    else
        ipset create special_proxy hash:ip timeout "$ipset_ttl"
    fi

    iptables -t nat -N SPECIAL_PROXY
    iptables -N SPECIAL_PROXY_UDP

    # Exclude local networks and the upstream SOCKS server itself (prevents redsocks redirect loops)
    local cidr
    for cidr in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t nat -A SPECIAL_PROXY -d "$cidr" -j RETURN
        iptables -A SPECIAL_PROXY_UDP -d "$cidr" -j RETURN
    done
    if [ -n "$socks_ip" ]; then
        iptables -t nat -A SPECIAL_PROXY -d "${socks_ip}/32" -j RETURN
        iptables -A SPECIAL_PROXY_UDP -d "${socks_ip}/32" -j RETURN
    fi

    # Redirect TCP traffic to redsocks and reject UDP (including QUIC/WebRTC) to force TCP fallback
    if is_truthy "${PROXY_ALL:-false}"; then
        iptables -t nat -A SPECIAL_PROXY -p tcp -j REDIRECT --to-ports 12345
        iptables -A SPECIAL_PROXY_UDP -p udp -j REJECT
    else
        iptables -t nat -A SPECIAL_PROXY -p tcp -m set --match-set special_proxy dst -j REDIRECT --to-ports 12345
        iptables -A SPECIAL_PROXY_UDP -p udp -m set --match-set special_proxy dst -j REJECT
    fi

    # Skip SmartDNS traffic on OUTPUT (also when DNS_FORCE_REDIRECT=false); -m owner cannot be used inside PREROUTING chains
    iptables -t nat -I OUTPUT -p tcp -m owner ! --gid-owner "$SMARTDNS_GROUP" -j SPECIAL_PROXY
    iptables -t nat -I PREROUTING -p tcp -j SPECIAL_PROXY
    iptables -I OUTPUT -p udp -m owner ! --gid-owner "$SMARTDNS_GROUP" -j SPECIAL_PROXY_UDP
    iptables -I FORWARD -p udp -j SPECIAL_PROXY_UDP
}

ensure_smartdns_group() {
    getent group "$SMARTDNS_GROUP" >/dev/null 2>&1 || groupadd -r "$SMARTDNS_GROUP"
}

cleanup_dns_iptables() {
    iptables -t nat -D OUTPUT -j DNS_REDIRECT 2>/dev/null || true
    iptables -t nat -F DNS_REDIRECT 2>/dev/null || true
    iptables -t nat -X DNS_REDIRECT 2>/dev/null || true

    iptables -D OUTPUT -j DNS_GUARD 2>/dev/null || true
    iptables -F DNS_GUARD 2>/dev/null || true
    iptables -X DNS_GUARD 2>/dev/null || true
}

setup_dns_iptables() {
    local socks_ip
    socks_ip="$(get_configured_socks_ip || true)"

    cleanup_dns_iptables

    # Known public DoH resolvers (blocked on 443 for non-smartdns processes so clients fall back to 127.0.0.1:53)
    ipset create doh_resolvers hash:ip -exist
    ipset flush doh_resolvers
    ipset restore -exist <<'EOF'
add doh_resolvers 1.1.1.1
add doh_resolvers 1.0.0.1
add doh_resolvers 1.1.1.2
add doh_resolvers 1.0.0.2
add doh_resolvers 1.1.1.3
add doh_resolvers 1.0.0.3
add doh_resolvers 104.16.248.249
add doh_resolvers 104.16.249.249
add doh_resolvers 8.8.8.8
add doh_resolvers 8.8.4.4
add doh_resolvers 9.9.9.9
add doh_resolvers 9.9.9.10
add doh_resolvers 9.9.9.11
add doh_resolvers 149.112.112.112
add doh_resolvers 149.112.112.10
add doh_resolvers 149.112.112.11
add doh_resolvers 208.67.222.222
add doh_resolvers 208.67.220.220
add doh_resolvers 208.67.222.123
add doh_resolvers 208.67.220.123
add doh_resolvers 94.140.14.14
add doh_resolvers 94.140.15.15
add doh_resolvers 94.140.14.140
add doh_resolvers 94.140.14.141
add doh_resolvers 185.228.168.9
add doh_resolvers 185.228.169.9
add doh_resolvers 185.228.168.168
add doh_resolvers 185.228.169.168
add doh_resolvers 77.88.8.8
add doh_resolvers 77.88.8.1
add doh_resolvers 194.242.2.2
EOF

    # Redirect any non-SmartDNS plain DNS (UDP/TCP 53) to local SmartDNS (127.0.0.1:53)
    # ACCEPT in nat stops further nat processing (including SPECIAL_PROXY) for SmartDNS itself
    iptables -t nat -N DNS_REDIRECT
    iptables -t nat -A DNS_REDIRECT -m owner --gid-owner "$SMARTDNS_GROUP" -j ACCEPT
    iptables -t nat -A DNS_REDIRECT -d 127.0.0.1/32 -j RETURN
    iptables -t nat -A DNS_REDIRECT -p udp --dport 53 -j REDIRECT --to-ports 53
    iptables -t nat -A DNS_REDIRECT -p tcp --dport 53 -j REDIRECT --to-ports 53
    iptables -t nat -I OUTPUT -j DNS_REDIRECT

    # Block external DoT/DoQ (853) and public DoH (443) for all processes except SmartDNS
    iptables -N DNS_GUARD
    iptables -A DNS_GUARD -m owner --gid-owner "$SMARTDNS_GROUP" -j RETURN
    if [ -n "$socks_ip" ]; then
        iptables -A DNS_GUARD -d "${socks_ip}/32" -j RETURN
    fi
    iptables -A DNS_GUARD -p tcp --dport 853 -j REJECT
    iptables -A DNS_GUARD -p udp --dport 853 -j REJECT
    iptables -A DNS_GUARD -p tcp --dport 443 -m set --match-set doh_resolvers dst -j REJECT
    iptables -A DNS_GUARD -p udp --dport 443 -m set --match-set doh_resolvers dst -j REJECT
    iptables -I OUTPUT -j DNS_GUARD
}

main() {
    log_info "Starting vscode-devbox initialization (TZ=${TZ:-UTC})..."

    # Если локальный volume ./volumes/nvm пустой — копируем туда предсобранный nvm + Node LTS
    if [ ! -f "$NVM_DIR/nvm.sh" ]; then
        log_info "Initializing empty NVM volume from /opt/nvm-seed..."
        cp -a /opt/nvm-seed/. "$NVM_DIR/"
    fi

    log_info "Ensuring volume mountpoint permissions (non-recursive)..."
    mkdir -p /workspace /home/dev/.vscode-server /home/dev/.gemini /home/dev/.config /home/dev/.config/antigravity /home/dev/.nvm /home/dev/.nuget
    chown dev:dev /workspace 2>/dev/null || true
    chown dev:dev \
        /home/dev/.vscode-server \
        /home/dev/.gemini \
        /home/dev/.config \
        /home/dev/.config/antigravity \
        /home/dev/.nvm \
        /home/dev/.nuget

    # Прокидываем симлинки активной Node в /usr/local/bin для расширений VS Code
    local node_bin_dir
    node_bin_dir="$(find "$NVM_DIR/versions/node" -maxdepth 2 -name bin -type d 2>/dev/null | sort -V | tail -n 1)"
    if [ -n "$node_bin_dir" ]; then
        ln -sf "$node_bin_dir/node" /usr/local/bin/node
        ln -sf "$node_bin_dir/npm" /usr/local/bin/npm
        ln -sf "$node_bin_dir/npx" /usr/local/bin/npx
        [ -f "$node_bin_dir/pnpm" ] && ln -sf "$node_bin_dir/pnpm" /usr/local/bin/pnpm
        if is_truthy "${VERBOSE_LOGS:-true}"; then
            log_info "Toolchain ready: node $(/usr/local/bin/node -v 2>/dev/null || echo 'n/a'), npm $(/usr/local/bin/npm -v 2>/dev/null || echo 'n/a'), dotnet $(dotnet --version 2>/dev/null || echo 'n/a')"
        fi
    fi

    if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
        ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
        printf '%s\n' "$TZ" > /etc/timezone
    fi

    local dotnet_root="/usr/lib/dotnet"
    if command -v dotnet >/dev/null 2>&1; then
        dotnet_root="$(dirname "$(readlink -f "$(command -v dotnet)")")"
    elif [ -d /usr/share/dotnet ]; then
        dotnet_root="/usr/share/dotnet"
    fi

    cat <<EOF > /etc/environment
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${dotnet_root}:/home/dev/.dotnet/tools"
DOTNET_ROOT="${dotnet_root}"
DOTNET_CLI_TELEMETRY_OPTOUT="1"
NVM_DIR="/home/dev/.nvm"
NODE_OPTIONS="--dns-result-order=ipv4first"
TZ="${TZ:-UTC}"
EOF

    configure_ssh_keys
    configure_git
    if is_truthy "${VERBOSE_LOGS:-true}"; then
        local ssh_key_count=0
        if [ -f "$SSH_AUTH_KEYS_FILE" ]; then
            ssh_key_count="$(grep -cve '^[[:space:]]*\(#\|$\)' "$SSH_AUTH_KEYS_FILE" || true)"
        fi
        log_info "SSH & Git configured (authorized_keys entries: ${ssh_key_count})"
    fi

    local dns_cache_ttl ipset_ttl
    dns_cache_ttl="$(get_dns_cache_ttl)"
    ipset_ttl="$(get_ipset_ttl)"

    if is_truthy "${DNS_CACHE_ENABLED:-true}" && [ "$ipset_ttl" -le "$dns_cache_ttl" ]; then
        echo "Warning: IPSET_TTL (${ipset_ttl}s) <= DNS_CACHE_TTL (${dns_cache_ttl}s); ipset entries may expire before SmartDNS cache or client DNS TTL." >&2
    fi

    disable_ipv6
    log_info "IPv6 disabled via sysctl and ip6tables"
    ensure_smartdns_group

    # Снимаем старый DNS-перехват на случай повторного запуска скрипта до подъёма SmartDNS
    cleanup_dns_iptables

    # --- Проксирование (redsocks + iptables, fail-closed при PROXY_ENABLED=true) ---
    if is_truthy "${PROXY_ENABLED:-true}"; then
        if ! configure_redsocks_file; then
            echo "Error: PROXY_ENABLED=true, but no SOCKS proxy is configured. Set SOCKS_PROXY_HOST in .env (or ip in redsocks.conf), or set PROXY_ENABLED=false." >&2
            return 1
        fi
        local active_socks_ip active_socks_port active_socks_type proxy_mode_label="selective"
        active_socks_ip="$(read_redsocks_value ip)"
        active_socks_port="$(read_redsocks_value port)"
        active_socks_type="$(read_redsocks_value type)"
        if is_truthy "${PROXY_ALL:-false}"; then
            proxy_mode_label="all"
        fi
        log_info "Setting up proxy rules (mode: ${proxy_mode_label}, ${active_socks_type}://${active_socks_ip}:${active_socks_port}, ipset TTL: ${ipset_ttl}s, DNS TTL: ${dns_cache_ttl}s)..."
        setup_proxy_iptables "$ipset_ttl"
        redsocks -t -c "$REDSOCKS_CONF_FILE"
        if ! pgrep -x redsocks >/dev/null; then
            if is_truthy "${VERBOSE_LOGS:-true}"; then
                redsocks -c "$REDSOCKS_CONF_FILE" &
                sleep 0.1
            else
                redsocks -c "$REDSOCKS_CONF_FILE"
            fi
        fi
        if ! pgrep -x redsocks >/dev/null; then
            echo "Error: redsocks failed to start" >&2
            return 1
        fi
        log_info "✓ Proxy rules and redsocks active (mode: ${proxy_mode_label})"
    else
        if is_truthy "${PROXY_ALL:-false}"; then
            echo "Warning: PROXY_ALL=true is ignored because PROXY_ENABLED=false." >&2
        fi
        cleanup_proxy_iptables
        log_info "Proxy disabled (PROXY_ENABLED=false) — skipping redsocks/iptables"
    fi

    # --- DNS (SmartDNS: читает smartdns.conf, либо применяет переменные из .env) ---
    configure_smartdns_file "$dns_cache_ttl"
    mkdir -p /var/log/smartdns
    if is_truthy "${VERBOSE_LOGS:-true}"; then
        local proxy_domains_count=0
        proxy_domains_count="$(grep -cE '^[[:space:]]*ipset[[:space:]]+/.+/special_proxy' "$SMARTDNS_CONF_FILE" || true)"
        log_info "Starting SmartDNS (cache: ${DNS_CACHE_ENABLED:-true}, proxy_all: ${PROXY_ALL:-false}, domains in special_proxy: ${proxy_domains_count})..."
    fi
    if ! pgrep -x smartdns >/dev/null; then
        setpriv --regid="$SMARTDNS_GROUP" --clear-groups smartdns -c "$SMARTDNS_CONF_FILE" -p "$SMARTDNS_PID_FILE"
    fi
    if ! pgrep -x smartdns >/dev/null; then
        echo "Error: smartdns failed to start" >&2
        return 1
    fi
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    log_info "✓ SmartDNS active on 127.0.0.1:53"

    if is_truthy "${DNS_FORCE_REDIRECT:-true}"; then
        log_info "Setting up forced DNS interception and DoT/DoH guard..."
        setup_dns_iptables
        log_info "✓ Forced DNS rules configured successfully"
    else
        log_info "Forced DNS interception disabled (DNS_FORCE_REDIRECT=false)"
    fi

    mkdir -p /run/sshd
    if is_truthy "${VERBOSE_LOGS:-true}"; then
        ssh-keygen -A
        log_info "Initialization complete — starting OpenSSH server on port 22"
        exec /usr/sbin/sshd -D -e
    else
        ssh-keygen -A >/dev/null
        exec /usr/sbin/sshd -D
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
