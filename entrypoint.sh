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

get_dns_cache_ttl() {
    local ttl="${DNS_CACHE_TTL:-300}"
    if [[ ! "$ttl" =~ ^[1-9][0-9]*$ ]] || [ "$ttl" -gt 2147483 ]; then
        echo "Error: DNS_CACHE_TTL must be an integer between 1 and 2147483 seconds (got '${ttl}'). To disable DNS cache, set DNS_CACHE_ENABLED=false." >&2
        return 1
    fi
    printf '%s\n' "$ttl"
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

# Возвращает 0, если прокси для redsocks реально сконфигурирован (через .env или вручную в redsocks.conf)
configure_redsocks_file() {
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
    local conf_ip
    conf_ip="$(read_redsocks_value ip)"
    if [ -n "$conf_ip" ] && [ "$conf_ip" != "127.0.0.1" ] && [ "$conf_ip" != "0.0.0.0" ]; then
        return 0
    fi
    return 1
}

configure_smartdns_file() {
    local cache_ttl="${1:-}"
    local cache_block=""
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
        cache_block="${cache_block}ipset-timeout yes"$'\n'
    else
        cache_block="cache-size 0"$'\n'
        cache_block="${cache_block}cache-persist no"$'\n'
        cache_block="${cache_block}serve-expired no"$'\n'
        cache_block="${cache_block}rr-ttl-reply-max 1"$'\n'
        cache_block="${cache_block}ipset-timeout no"$'\n'
    fi

    tmp_conf="$(mktemp)"
    awk -v block="$cache_block" '
        BEGIN { in_block = 0; replaced = 0 }
        /^# --- BEGIN CACHE/ {
            print "# --- BEGIN CACHE (auto-managed from .env) ---"
            printf "%s", block
            print "# --- END CACHE ---"
            in_block = 1
            replaced = 1
            next
        }
        /^# --- END CACHE/ { in_block = 0; next }
        !in_block && /^[[:space:]]*(cache-size|cache-persist|serve-expired|rr-ttl|rr-ttl-reply-max|ipset-timeout)[[:space:]]/ { next }
        !in_block { print }
        END {
            if (!replaced) {
                printf "\n# --- BEGIN CACHE (auto-managed from .env) ---\n%s# --- END CACHE ---\n", block
            }
        }
    ' "$SMARTDNS_CONF_FILE" > "$tmp_conf" && mv "$tmp_conf" "$SMARTDNS_CONF_FILE"

    if ! grep -Eq '^[[:space:]]*bind-tcp[[:space:]]' "$SMARTDNS_CONF_FILE" 2>/dev/null; then
        printf '\nbind-tcp 127.0.0.1:53\n' >> "$SMARTDNS_CONF_FILE"
    fi

    if ! grep -Eq '^[[:space:]]*force-qtype-SOA[[:space:]]' "$SMARTDNS_CONF_FILE" 2>/dev/null; then
        printf '\nforce-qtype-SOA 64 65\n' >> "$SMARTDNS_CONF_FILE"
    fi

    # Обновляем блок апстримов только если заданы переменные в .env;
    # иначе SmartDNS читает настройки серверов напрямую из smartdns.conf
    if [ -n "${UPSTREAM_DNS:-}" ] || [ -n "${DNS_ENCRYPTED_SERVERS:-}" ]; then
        local proxy_flag=""
        local socks_ip socks_port socks_type

        if [ -n "${DNS_ENCRYPTED_SERVERS:-}" ]; then
            if is_truthy "${DNS_ENCRYPTED_VIA_SOCKS:-false}"; then
                socks_ip="$(read_redsocks_value ip)"
                socks_port="$(read_redsocks_value port)"
                socks_type="$(read_redsocks_value type)"
                if [ -n "$socks_ip" ] && [ "$socks_ip" != "127.0.0.1" ] && [ "$socks_ip" != "0.0.0.0" ] && [ "$socks_type" = "socks5" ]; then
                    upstream_block="${upstream_block}proxy-server socks5://${socks_ip}:${socks_port:-10808} -name env_socks"$'\n'
                    proxy_flag=" -proxy env_socks"
                else
                    echo "Warning: DNS_ENCRYPTED_VIA_SOCKS=true, but no active SOCKS5 proxy is configured; using direct DoH/DoT" >&2
                fi
            fi

            local bootstrap_ip="${UPSTREAM_DNS:-1.1.1.1}"
            upstream_block="${upstream_block}server ${bootstrap_ip} -bootstrap-dns -exclude-default-group"$'\n'

            local srv
            while IFS= read -r srv; do
                [ -z "$srv" ] && continue
                upstream_block="${upstream_block}server ${srv}${proxy_flag}"$'\n'
            done < <(tr ',' ' ' <<< "$DNS_ENCRYPTED_SERVERS" | tr -s '[:space:]' '\n')
        else
            upstream_block="${upstream_block}server ${UPSTREAM_DNS}"$'\n'
        fi

        tmp_conf="$(mktemp)"
        awk -v block="$upstream_block" '
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
    local cache_ttl="${1:-}"
    if [ -z "$cache_ttl" ]; then
        cache_ttl="$(get_dns_cache_ttl)"
    fi

    cleanup_proxy_iptables

    # Create or atomically update ipset so timeout always matches DNS_CACHE_TTL
    if ipset list -t special_proxy >/dev/null 2>&1; then
        ipset destroy special_proxy_tmp 2>/dev/null || true
        ipset create special_proxy_tmp hash:ip timeout "$cache_ttl"
        ipset swap special_proxy_tmp special_proxy
        ipset destroy special_proxy_tmp
    else
        ipset create special_proxy hash:ip timeout "$cache_ttl"
    fi

    iptables -t nat -N SPECIAL_PROXY
    iptables -N SPECIAL_PROXY_UDP

    # Exclude local networks
    local cidr
    for cidr in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t nat -A SPECIAL_PROXY -d "$cidr" -j RETURN
        iptables -A SPECIAL_PROXY_UDP -d "$cidr" -j RETURN
    done

    # Redirect matched TCP traffic to redsocks and reject all UDP (including QUIC/WebRTC) to force TCP fallback
    iptables -t nat -A SPECIAL_PROXY -p tcp -m set --match-set special_proxy dst -j REDIRECT --to-ports 12345
    iptables -A SPECIAL_PROXY_UDP -p udp -m set --match-set special_proxy dst -j REJECT

    iptables -t nat -I OUTPUT -p tcp -j SPECIAL_PROXY
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
    socks_ip="$(read_redsocks_value ip)"

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
    if [ -n "$socks_ip" ] && [ "$socks_ip" != "127.0.0.1" ] && [ "$socks_ip" != "0.0.0.0" ]; then
        iptables -A DNS_GUARD -d "${socks_ip}/32" -j RETURN
    fi
    iptables -A DNS_GUARD -p tcp --dport 853 -j REJECT
    iptables -A DNS_GUARD -p udp --dport 853 -j REJECT
    iptables -A DNS_GUARD -p tcp --dport 443 -m set --match-set doh_resolvers dst -j REJECT
    iptables -A DNS_GUARD -p udp --dport 443 -m set --match-set doh_resolvers dst -j REJECT
    iptables -I OUTPUT -j DNS_GUARD
}

main() {
    # Если локальный volume ./volumes/nvm пустой — копируем туда предсобранный nvm + Node LTS
    if [ ! -f "$NVM_DIR/nvm.sh" ]; then
        cp -a /opt/nvm-seed/. "$NVM_DIR/"
    fi

    mkdir -p /home/dev/.config /home/dev/.gemini /home/dev/.config/antigravity
    chown -R dev:dev /workspace /home/dev/.vscode-server /home/dev/.gemini /home/dev/.config /home/dev/.nvm /home/dev/.nuget

    # Прокидываем симлинки активной Node в /usr/local/bin для расширений VS Code
    local node_bin_dir
    node_bin_dir="$(find "$NVM_DIR/versions/node" -maxdepth 2 -name bin -type d 2>/dev/null | sort -V | tail -n 1)"
    if [ -n "$node_bin_dir" ]; then
        ln -sf "$node_bin_dir/node" /usr/local/bin/node
        ln -sf "$node_bin_dir/npm" /usr/local/bin/npm
        ln -sf "$node_bin_dir/npx" /usr/local/bin/npx
        [ -f "$node_bin_dir/pnpm" ] && ln -sf "$node_bin_dir/pnpm" /usr/local/bin/pnpm
    fi

    if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
        ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
        printf '%s\n' "$TZ" > /etc/timezone
    fi

    cat <<EOF > /etc/environment
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/share/dotnet:/home/dev/.dotnet/tools"
DOTNET_ROOT="/usr/share/dotnet"
DOTNET_CLI_TELEMETRY_OPTOUT="1"
NVM_DIR="/home/dev/.nvm"
NODE_OPTIONS="--dns-result-order=ipv4first"
TZ="${TZ:-UTC}"
EOF

    configure_ssh_keys
    configure_git

    local dns_cache_ttl
    dns_cache_ttl="$(get_dns_cache_ttl)"

    disable_ipv6
    ensure_smartdns_group

    # Снимаем старый DNS-перехват на случай повторного запуска скрипта до подъёма SmartDNS
    cleanup_dns_iptables

    # --- Селективный прокси (redsocks + iptables, fail-closed при PROXY_ENABLED=true) ---
    if is_truthy "${PROXY_ENABLED:-true}"; then
        if ! configure_redsocks_file; then
            echo "Error: PROXY_ENABLED=true, but no SOCKS proxy is configured. Set SOCKS_PROXY_HOST in .env (or ip in redsocks.conf), or set PROXY_ENABLED=false." >&2
            return 1
        fi
        echo "Setting up selective proxy rules (TTL: ${dns_cache_ttl}s)..."
        setup_proxy_iptables "$dns_cache_ttl"
        echo "✓ Proxy rules configured successfully"
        pgrep -x redsocks >/dev/null || redsocks -c "$REDSOCKS_CONF_FILE"
        if ! pgrep -x redsocks >/dev/null; then
            echo "Error: redsocks failed to start" >&2
            return 1
        fi
    else
        cleanup_proxy_iptables
        echo "Selective proxy disabled (PROXY_ENABLED=false) — skipping redsocks/iptables"
    fi

    # --- DNS (SmartDNS: читает smartdns.conf, либо применяет переменные из .env) ---
    configure_smartdns_file "$dns_cache_ttl"
    mkdir -p /var/log/smartdns
    if ! pgrep -x smartdns >/dev/null; then
        setpriv --regid="$SMARTDNS_GROUP" --clear-groups smartdns -c "$SMARTDNS_CONF_FILE" -p "$SMARTDNS_PID_FILE"
    fi
    if ! pgrep -x smartdns >/dev/null; then
        echo "Error: smartdns failed to start" >&2
        return 1
    fi
    echo "nameserver 127.0.0.1" > /etc/resolv.conf

    if is_truthy "${DNS_FORCE_REDIRECT:-true}"; then
        echo "Setting up forced DNS interception and DoT/DoH guard..."
        setup_dns_iptables
        echo "✓ Forced DNS rules configured successfully"
    fi

    mkdir -p /run/sshd
    ssh-keygen -A
    exec /usr/sbin/sshd -D
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
