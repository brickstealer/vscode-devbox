#!/usr/bin/env bash
set -e

NVM_DIR="/home/dev/.nvm"
GIT_CONFIG_FILE="${GIT_CONFIG_FILE:-/home/dev/.gitconfig}"
SSH_AUTH_KEYS_FILE="${SSH_AUTH_KEYS_FILE:-/home/dev/.ssh/authorized_keys}"
DNSMASQ_CONF_FILE="${DNSMASQ_CONF_FILE:-/etc/dnsmasq.conf}"
REDSOCKS_CONF_FILE="${REDSOCKS_CONF_FILE:-/etc/redsocks.conf}"

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
        echo "Error: failed to resolve SOCKS_PROXY_HOST '$target' to an IPv4 address" >&2
        return 1
    fi
    printf '%s\n' "$ip"
}

configure_proxy_files() {
    local socks_ip upstream_dns socks_port socks_type domain rule
    socks_ip="$(resolve_ipv4 "$SOCKS_PROXY_HOST")"
    upstream_dns="${UPSTREAM_DNS:-1.1.1.1}"
    socks_port="${SOCKS_PROXY_PORT:-10808}"
    socks_type="${SOCKS_PROXY_TYPE:-socks5}"

    sed -i \
        -e "s|^\([[:space:]]*ip[[:space:]]*=[[:space:]]*\).*|\1${socks_ip};|" \
        -e "s|^\([[:space:]]*port[[:space:]]*=[[:space:]]*\).*|\1${socks_port};|" \
        -e "s|^\([[:space:]]*type[[:space:]]*=[[:space:]]*\).*|\1${socks_type};|" \
        "$REDSOCKS_CONF_FILE"

    sed -i "s|^server=.*|server=${upstream_dns}|" "$DNSMASQ_CONF_FILE"

    if [ -n "${PROXY_EXTRA_DOMAINS:-}" ]; then
        while IFS= read -r domain; do
            domain="${domain#.}"
            if [ -z "$domain" ]; then
                continue
            fi
            rule="ipset=/${domain}/special_proxy"
            if ! grep -qxF "$rule" "$DNSMASQ_CONF_FILE" 2>/dev/null; then
                printf '%s\n' "$rule" >> "$DNSMASQ_CONF_FILE"
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

    chown -R dev:dev /workspace /home/dev/.vscode-server /home/dev/.nvm /home/dev/.nuget

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

    # --- Настройка селективного прокси ---
    local proxy_active=0
    case "${PROXY_ENABLED:-true}" in
        true|TRUE|1|yes|YES) proxy_active=1 ;;
    esac

    if [ "$proxy_active" -eq 1 ] && [ -n "${SOCKS_PROXY_HOST:-}" ]; then
        echo "Setting up selective proxy rules..."
        configure_proxy_files
        setup_proxy_iptables
        echo "✓ Proxy rules configured successfully"

        pgrep -x redsocks >/dev/null || redsocks -c "$REDSOCKS_CONF_FILE"
        pgrep -x dnsmasq >/dev/null || dnsmasq --conf-file="$DNSMASQ_CONF_FILE"
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
    else
        echo "Selective proxy disabled or SOCKS_PROXY_HOST not set — using direct DNS (${UPSTREAM_DNS:-1.1.1.1})"
        echo "nameserver ${UPSTREAM_DNS:-1.1.1.1}" > /etc/resolv.conf
    fi

    mkdir -p /run/sshd
    ssh-keygen -A
    exec /usr/sbin/sshd -D
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
