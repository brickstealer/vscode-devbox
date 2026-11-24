#!/usr/bin/env bash
set -e

NVM_DIR="/home/dev/.nvm"
GIT_CONFIG_FILE="${GIT_CONFIG_FILE:-/home/dev/.gitconfig}"
SSH_AUTH_KEYS_FILE="${SSH_AUTH_KEYS_FILE:-/home/dev/.ssh/authorized_keys}"
SMARTDNS_CONF_FILE="${SMARTDNS_CONF_FILE:-/etc/smartdns/smartdns.conf}"
SMARTDNS_PID_FILE="${SMARTDNS_PID_FILE:-/run/smartdns.pid}"
REDSOCKS_CONF_FILE="${REDSOCKS_CONF_FILE:-/etc/redsocks.conf}"

is_truthy() {
    case "${1:-}" in
        true|TRUE|1|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
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
    local upstream_block=""
    local tmp_conf

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

setup_proxy_iptables() {
    ipset create special_proxy hash:ip timeout 300 -exist

    # Clean old jumps to avoid duplicates on re-run
    iptables -t nat -D OUTPUT -p tcp -j SPECIAL_PROXY 2>/dev/null || true
    iptables -t nat -D PREROUTING -p tcp -j SPECIAL_PROXY 2>/dev/null || true
    iptables -D OUTPUT -p udp --dport 443 -m set --match-set special_proxy dst -j REJECT 2>/dev/null || true
    iptables -D FORWARD -p udp --dport 443 -m set --match-set special_proxy dst -j REJECT 2>/dev/null || true

    # Flush and recreate nat chain
    iptables -t nat -F SPECIAL_PROXY 2>/dev/null || true
    iptables -t nat -X SPECIAL_PROXY 2>/dev/null || true
    iptables -t nat -N SPECIAL_PROXY

    # Exclude local networks
    iptables -t nat -A SPECIAL_PROXY -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A SPECIAL_PROXY -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A SPECIAL_PROXY -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A SPECIAL_PROXY -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A SPECIAL_PROXY -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A SPECIAL_PROXY -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A SPECIAL_PROXY -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A SPECIAL_PROXY -d 240.0.0.0/4 -j RETURN

    # Redirect matched TCP traffic to redsocks
    iptables -t nat -A SPECIAL_PROXY -p tcp -m set --match-set special_proxy dst -j REDIRECT --to-ports 12345

    # Apply TCP redirect and block QUIC (UDP 443) for proxied IPs
    iptables -t nat -I OUTPUT -p tcp -j SPECIAL_PROXY
    iptables -t nat -I PREROUTING -p tcp -j SPECIAL_PROXY
    iptables -I OUTPUT -p udp --dport 443 -m set --match-set special_proxy dst -j REJECT
    iptables -I FORWARD -p udp --dport 443 -m set --match-set special_proxy dst -j REJECT
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

    # --- Селективный прокси (redsocks + iptables) ---
    if is_truthy "${PROXY_ENABLED:-true}" && configure_redsocks_file; then
        echo "Setting up selective proxy rules..."
        setup_proxy_iptables
        echo "✓ Proxy rules configured successfully"
        pgrep -x redsocks >/dev/null || redsocks -c "$REDSOCKS_CONF_FILE"
    else
        echo "Selective proxy disabled or no SOCKS host configured — skipping redsocks/iptables"
    fi

    # --- DNS (SmartDNS: читает smartdns.conf, либо применяет переменные из .env) ---
    configure_smartdns_file
    mkdir -p /var/log/smartdns
    pgrep -x smartdns >/dev/null || smartdns -c "$SMARTDNS_CONF_FILE" -p "$SMARTDNS_PID_FILE"
    echo "nameserver 127.0.0.1" > /etc/resolv.conf

    mkdir -p /run/sshd
    ssh-keygen -A
    exec /usr/sbin/sshd -D
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
