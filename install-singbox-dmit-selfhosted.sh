#!/bin/bash
# DMIT 自建站专用版：使用用户自己的 HTTPS 域名作为 Reality SNI，
# 优先复用本机 HTTPS 网站；在安全条件满足时可自动安装 Caddy 建站。
set -eu
set -o pipefail 2>/dev/null || true
umask 077

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

CONFIG_DIR="/etc/sing-box"
CONFIG_PATH="$CONFIG_DIR/config.json"
CACHE_FILE="$CONFIG_DIR/.config_cache"
URI_FILE="$CONFIG_DIR/uris.txt"
QR_DIR="$CONFIG_DIR/qrcodes"
CERT_DIR="$CONFIG_DIR/certs"
PROTOCOL_FILE="$CONFIG_DIR/.protocols"
NODE_SUFFIX_FILE="/root/node_names.txt"
USER_DB="$CONFIG_DIR/users.csv"

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

url_encode() {
  local LC_ALL=C
  local s="$1"
  local i c out="" hex
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *)
        printf -v hex '%02X' "'$c"
        out+="%$hex"
        ;;
    esac
  done
  printf '%s' "$out"
}

b64() {
  if base64 --help 2>/dev/null | grep -q '\-w'; then
    printf '%s' "$1" | base64 -w0
  else
    printf '%s' "$1" | base64 | tr -d '\r\n'
  fi
}

detect_os() {
  OS="unknown"
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
      alpine) OS="alpine" ;;
      debian|ubuntu) OS="debian" ;;
      centos|rhel|fedora|rocky|almalinux) OS="redhat" ;;
      *)
        case "${ID_LIKE:-}" in
          *debian*|*ubuntu*) OS="debian" ;;
          *rhel*|*fedora*|*centos*) OS="redhat" ;;
        esac
        ;;
    esac
  fi
}

detect_os
info "检测到系统: $OS"

install_deps() {
  info "安装依赖..."
  case "$OS" in
    alpine)
      apk update
      apk add --no-cache bash curl ca-certificates openssl jq qrencode coreutils grep sed gawk bind-tools iproute2
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y bash curl ca-certificates openssl jq qrencode coreutils grep sed gawk dnsutils iproute2
      ;;
    redhat)
      yum install -y bash curl ca-certificates openssl jq qrencode coreutils grep sed gawk bind-utils iproute || \
      dnf install -y bash curl ca-certificates openssl jq qrencode coreutils grep sed gawk bind-utils iproute
      ;;
    *)
      warn "未识别系统，请确保已安装: bash curl openssl jq qrencode"
      ;;
  esac
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    info "已检测到 sing-box"
    return 0
  fi

  info "安装 sing-box..."
  case "$OS" in
    alpine)
      apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box
      ;;
    debian|redhat)
      bash <(curl -fsSL https://sing-box.app/install.sh)
      ;;
    *)
      err "当前系统暂未适配自动安装 sing-box"
      exit 1
      ;;
  esac

  command -v sing-box >/dev/null 2>&1 || { err "sing-box 安装失败"; exit 1; }
}

rand_port() {
  if command -v shuf >/dev/null 2>&1; then
    shuf -i 10000-60000 -n 1
  else
    echo $((RANDOM % 50001 + 10000))
  fi
}

declare -A RESERVED_PORTS=()

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

port_is_listening() {
  local port="$1"
  ss -H -lntu 2>/dev/null |
    awk -v port="$port" '
      $5 ~ (":" port "$") { found=1 }
      END { exit(found ? 0 : 1) }
    '
}

port_is_reserved() {
  [ -n "${RESERVED_PORTS[$1]:-}" ]
}

reserve_port() {
  RESERVED_PORTS["$1"]=1
}

random_free_port() {
  local candidate attempts=0
  while [ "$attempts" -lt 100 ]; do
    candidate="$(rand_port)"
    if ! port_is_listening "$candidate" && ! port_is_reserved "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    attempts=$((attempts + 1))
  done
  return 1
}

prompt_free_port() {
  local output_var="$1" label="$2" input candidate
  while true; do
    read -r -p "${label}端口（留空自动选择空闲端口）: " input
    if [ -z "$input" ]; then
      candidate="$(random_free_port)" || {
        err "无法找到可用端口"
        exit 1
      }
    else
      candidate="$input"
    fi
    if ! valid_port "$candidate"; then
      warn "端口必须是 1-65535 的整数"
      continue
    fi
    if port_is_listening "$candidate"; then
      warn "端口 $candidate 已被系统服务占用，请换一个"
      continue
    fi
    if port_is_reserved "$candidate"; then
      warn "端口 $candidate 已分配给本次安装中的其他协议，请换一个"
      continue
    fi
    reserve_port "$candidate"
    printf -v "$output_var" '%s' "$candidate"
    info "${label}端口: $candidate"
    return 0
  done
}

rand_pass() {
  openssl rand -base64 16 2>/dev/null | tr -d '\r\n'
}

rand_uuid() {
  if [ -f /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'
  fi
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-'
}

get_public_ip() {
  local ip=""
  for url in https://api.ipify.org https://ipinfo.io/ip https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

# ---------- 自建 HTTPS 站点 Reality SNI ----------
REALITY_SNI=""
REALITY_HANDSHAKE_SERVER=""
REALITY_HANDSHAKE_PORT="443"
declare -a LOCAL_PUBLIC_IPS=()
declare -a REALITY_DOMAIN_IPS=()

sanitize_sni() {
  printf '%s' "$1" |
    sed -E 's#^[[:space:]]*https?://##I; s#/.*$##; s/:443$//; s/[[:space:]]//g' |
    tr '[:upper:]' '[:lower:]'
}

valid_sni() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

append_unique_ip() {
  local candidate="$1" item
  [ -n "$candidate" ] || return 0
  for item in "${LOCAL_PUBLIC_IPS[@]}"; do
    [ "$item" != "$candidate" ] || return 0
  done
  LOCAL_PUBLIC_IPS+=("$candidate")
}

collect_local_public_ips() {
  local ip url
  LOCAL_PUBLIC_IPS=()

  if command -v ip >/dev/null 2>&1; then
    while read -r ip; do
      append_unique_ip "$ip"
    done < <(
      ip -o addr show scope global 2>/dev/null |
        awk '{split($4, parts, "/"); print parts[1]}'
    )
  fi

  for url in https://api4.ipify.org https://v4.ident.me; do
    ip="$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      append_unique_ip "$ip"
      break
    fi
  done

  for url in https://api6.ipify.org https://v6.ident.me; do
    ip="$(curl -6 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" == *:* ]] && [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
      append_unique_ip "$ip"
      break
    fi
  done
}

ip_is_local_public() {
  local candidate="$1" item
  for item in "${LOCAL_PUBLIC_IPS[@]}"; do
    [ "$candidate" != "$item" ] || return 0
  done
  return 1
}

validate_reality_domain_dns() {
  local domain="$1" ip
  local mismatch=false

  collect_local_public_ips
  [ "${#LOCAL_PUBLIC_IPS[@]}" -gt 0 ] || {
    err "无法确定本 VPS 的公网 IP，不能安全验证域名解析"
    return 1
  }

  mapfile -t REALITY_DOMAIN_IPS < <(
    {
      dig +short A "$domain" 2>/dev/null |
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
      dig +short AAAA "$domain" 2>/dev/null |
        grep -E '^[0-9a-fA-F:]+$'
    } | sort -u
  )

  [ "${#REALITY_DOMAIN_IPS[@]}" -gt 0 ] || {
    err "域名 $domain 没有可用的 A/AAAA 记录"
    return 1
  }

  for ip in "${REALITY_DOMAIN_IPS[@]}"; do
    if ! ip_is_local_public "$ip"; then
      err "域名 $domain 的记录 $ip 不属于本 VPS"
      mismatch=true
    fi
  done

  if [ "$mismatch" = true ]; then
    err "请关闭 CDN 代理，并确保该域名的全部 A/AAAA 记录都直连本 VPS"
    return 1
  fi

  info "域名解析验证通过: $domain -> ${REALITY_DOMAIN_IPS[*]}"
}

format_connect_address() {
  case "$1" in
    *:*) printf '[%s]:%s' "$1" "$2" ;;
    *) printf '%s:%s' "$1" "$2" ;;
  esac
}

probe_https_backend() {
  local backend="$1" port="$2" domain="$3"
  local probe_timeout="${4:-10}"
  local connect_address output_file
  connect_address="$(format_connect_address "$backend" "$port")"
  output_file="$(mktemp)"

  if timeout "$probe_timeout" openssl s_client \
      -connect "$connect_address" \
      -servername "$domain" \
      -verify_hostname "$domain" \
      -verify_return_error \
      </dev/null >"$output_file" 2>&1 &&
     grep -Eq 'Verify return code: 0 \(ok\)|Verification: OK' "$output_file"; then
    rm -f "$output_file"
    return 0
  fi

  rm -f "$output_file"
  return 1
}

show_web_port_owners() {
  ss -H -lntp 2>/dev/null |
    awk '$4 ~ /:(80|443)$/ { print "  " $0 }' || true
}

open_web_firewall_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    info "放行 UFW 的 80/443 TCP 端口..."
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    info "放行 firewalld 的 80/443 TCP 端口..."
    firewall-cmd --permanent --add-service=http >/dev/null
    firewall-cmd --permanent --add-service=https >/dev/null
    firewall-cmd --reload >/dev/null
  else
    warn "未检测到启用中的 UFW/firewalld；请确认 DMIT 控制台防火墙已放行 TCP 80 和 443"
  fi
}

install_caddy_debian() {
  local temp_dir managed_marker="/etc/caddy/.singbox-reality-managed"

  [ "$OS" = "debian" ] || {
    err "自动安装 Caddy 目前仅支持 Debian/Ubuntu"
    return 1
  }

  if command -v caddy >/dev/null 2>&1 || [ -e /etc/caddy/Caddyfile ]; then
    if [ -f "$managed_marker" ] && grep -Fxq "$REALITY_SNI" "$managed_marker"; then
      info "复用本脚本此前为 $REALITY_SNI 创建的 Caddy 站点"
      return 0
    fi
    err "检测到已有 Caddy 或 Caddy 配置；为避免覆盖现有站点，自动建站已停止"
    err "请手动把域名 $REALITY_SNI 配置到现有 Caddy，完成后重新运行脚本"
    return 1
  fi

  if port_is_listening 80 || port_is_listening 443; then
    err "TCP 80 或 443 已被其他服务占用，不能安全地自动安装 Caddy"
    show_web_port_owners
    err "请先处理现有 Web 服务，或手动给它添加域名 $REALITY_SNI"
    return 1
  fi

  info "安装 Caddy 官方稳定版软件源和服务..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg debian-keyring debian-archive-keyring apt-transport-https

  temp_dir="$(mktemp -d)"
  if ! curl -1fsSL --proto '=https' --tlsv1.2 \
      'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      -o "$temp_dir/caddy.gpg.key"; then
    rm -rf -- "$temp_dir"
    err "Caddy 软件源签名密钥下载失败"
    return 1
  fi
  if ! gpg --batch --yes --dearmor \
      --output "$temp_dir/caddy-stable-archive-keyring.gpg" \
      "$temp_dir/caddy.gpg.key"; then
    rm -rf -- "$temp_dir"
    err "Caddy 软件源签名密钥解析失败"
    return 1
  fi
  if ! curl -1fsSL --proto '=https' --tlsv1.2 \
      'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      -o "$temp_dir/caddy-stable.list"; then
    rm -rf -- "$temp_dir"
    err "Caddy 软件源配置下载失败"
    return 1
  fi

  grep -Eq '^deb ' "$temp_dir/caddy-stable.list" || {
    rm -rf -- "$temp_dir"
    err "下载的 Caddy 软件源配置格式异常"
    return 1
  }

  install -m 0644 "$temp_dir/caddy-stable-archive-keyring.gpg" \
    /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  install -m 0644 "$temp_dir/caddy-stable.list" \
    /etc/apt/sources.list.d/caddy-stable.list
  rm -rf -- "$temp_dir"

  apt-get update -y
  apt-get install -y caddy
  command -v caddy >/dev/null 2>&1 || {
    err "Caddy 安装失败"
    return 1
  }
}

deploy_caddy_reality_site() {
  local domain="$1" site_dir temp_config config_backup attempt

  [ "$REALITY_HANDSHAKE_PORT" = "443" ] || {
    err "自动建站只支持标准 HTTPS 后端端口 443"
    return 1
  }

  install_caddy_debian || return 1
  open_web_firewall_ports

  site_dir="/var/www/reality-decoy/$domain"
  install -d -m 0755 "$site_dir"
  cat > "$site_dir/index.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head>
<body><main><h1>Welcome</h1><p>This site is running normally.</p></main></body>
</html>
EOF
  chmod 0644 "$site_dir/index.html"

  temp_config="$(mktemp)"
  cat > "$temp_config" <<EOF
$domain {
    root * $site_dir
    encode zstd gzip
    header {
        X-Content-Type-Options nosniff
        Referrer-Policy no-referrer
        -Server
    }
    file_server
}
EOF

  caddy fmt --overwrite "$temp_config"
  caddy validate --config "$temp_config" --adapter caddyfile || {
    rm -f "$temp_config"
    err "生成的 Caddy 配置校验失败"
    return 1
  }

  install -d -m 0755 /etc/caddy
  config_backup=""
  if [ -f /etc/caddy/Caddyfile ]; then
    config_backup="/etc/caddy/Caddyfile.pre-reality.$(date +%Y%m%d%H%M%S)"
    cp -p /etc/caddy/Caddyfile "$config_backup"
  fi
  install -m 0644 "$temp_config" /etc/caddy/Caddyfile
  rm -f "$temp_config"
  printf '%s\n' "$domain" > /etc/caddy/.singbox-reality-managed
  chmod 0644 /etc/caddy/.singbox-reality-managed

  systemctl daemon-reload
  systemctl enable caddy >/dev/null 2>&1 || true
  if ! systemctl restart caddy; then
    if [ -n "$config_backup" ] && [ -f "$config_backup" ]; then
      cp -p "$config_backup" /etc/caddy/Caddyfile
      systemctl restart caddy || true
    fi
    err "Caddy 启动失败；请检查: journalctl -u caddy -n 100 --no-pager"
    return 1
  fi

  info "等待 Caddy 申请 HTTPS 证书..."
  for ((attempt=1; attempt<=20; attempt++)); do
    if probe_https_backend 127.0.0.1 443 "$domain" 3; then
      REALITY_HANDSHAKE_SERVER="127.0.0.1"
      info "Caddy 建站及可信 HTTPS 证书验证通过"
      return 0
    fi
    sleep 3
  done

  err "Caddy 在等待时间内未取得有效证书"
  err "请确认公网 TCP 80/443 已放行，然后检查: journalctl -u caddy -n 100 --no-pager"
  return 1
}

offer_caddy_auto_deploy() {
  local choice

  if [ "$OS" != "debian" ] || [ "$REALITY_HANDSHAKE_PORT" != "443" ]; then
    return 1
  fi

  echo
  warn "没有检测到可用的 HTTPS 网站"
  echo "脚本可以自动安装 Caddy、创建最小伪装页，并为 $REALITY_SNI 申请可信证书。"
  read -r -p "是否自动建站？[Y/n]: " choice
  case "${choice,,}" in
    ""|y|yes) deploy_caddy_reality_site "$REALITY_SNI" ;;
    *) return 1 ;;
  esac
}

find_local_https_backend() {
  local domain="$1" port="$2" candidate

  for candidate in 127.0.0.1 ::1 "${REALITY_DOMAIN_IPS[@]}"; do
    [ -n "$candidate" ] || continue
    if probe_https_backend "$candidate" "$port" "$domain"; then
      REALITY_HANDSHAKE_SERVER="$candidate"
      info "本机 HTTPS 后端验证通过: $candidate:$port，证书匹配 $domain"
      return 0
    fi
  done

  err "未找到可用的本机 HTTPS 后端"
  err "请确认网站正在指定端口提供 HTTPS，证书有效且包含域名 $domain"
  return 1
}

configure_reality_site() {
  local input default_domain=""

  echo
  info "Reality 将使用你自己的 HTTPS 网站作为唯一伪装站点"
  warn "域名必须直连本 VPS，不能开启 Cloudflare 等 CDN 代理"

  if valid_sni "${SERVER_HOST:-}"; then
    default_domain="$SERVER_HOST"
  fi

  while true; do
    if [ -n "$default_domain" ]; then
      read -r -p "Reality 网站域名 [默认 $default_domain]: " input
      input="${input:-$default_domain}"
    else
      read -r -p "Reality 网站域名（例如 www.example.com）: " input
    fi
    REALITY_SNI="$(sanitize_sni "$input")"
    if valid_sni "$REALITY_SNI"; then
      break
    fi
    warn "请输入不带协议、路径和端口的完整域名"
  done

  while true; do
    read -r -p "本机网站 HTTPS 后端端口 [默认 443]: " input
    REALITY_HANDSHAKE_PORT="${input:-443}"
    valid_port "$REALITY_HANDSHAKE_PORT" && break
    warn "端口必须是 1-65535 的整数"
  done

  validate_reality_domain_dns "$REALITY_SNI" || return 1
  if ! find_local_https_backend "$REALITY_SNI" "$REALITY_HANDSHAKE_PORT"; then
    offer_caddy_auto_deploy || return 1
    find_local_https_backend "$REALITY_SNI" "$REALITY_HANDSHAKE_PORT" || return 1
  fi

  echo
  info "Reality 伪装站点配置:"
  echo "  客户端 SNI: $REALITY_SNI"
  echo "  本机后端:   $REALITY_HANDSHAKE_SERVER:$REALITY_HANDSHAKE_PORT"
  echo
  echo "提示："
  echo "  - 网站继续占用 443 时，Reality 请选择其他端口。"
  echo "  - 如需 Reality 占用 443，请先让网站仅监听本机其他 TLS 端口（如 8443）。"
}


generate_reality_keys() {
  REALITY_PK=""
  REALITY_PUB=""
  REALITY_SID=""

  [ "$ENABLE_REALITY" = "true" ] || return 0

  info "生成 Reality 密钥..."
  local keys
  keys="$(sing-box generate reality-keypair 2>/dev/null || true)"
  REALITY_PK="$(echo "$keys" | awk '/PrivateKey/{print $NF}')"
  REALITY_PUB="$(echo "$keys" | awk '/PublicKey/{print $NF}')"
  REALITY_SID="$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")"

  [ -n "$REALITY_PK" ] && [ -n "$REALITY_PUB" ] || { err "Reality 密钥生成失败"; exit 1; }
}

generate_cert() {
  local cert_pub key_pub

  if [ "$ENABLE_HY2" != "true" ] && [ "$ENABLE_TUIC" != "true" ]; then
    return 0
  fi

  [ -r "$TLS_CERT_PATH" ] || {
    err "证书文件不可读: $TLS_CERT_PATH"
    exit 1
  }
  [ -r "$TLS_KEY_PATH" ] || {
    err "私钥文件不可读: $TLS_KEY_PATH"
    exit 1
  }

  openssl x509 -in "$TLS_CERT_PATH" -noout -checkend 86400 >/dev/null 2>&1 || {
    err "TLS 证书无效或将在 24 小时内过期"
    exit 1
  }
  openssl x509 -in "$TLS_CERT_PATH" -noout -checkhost "$TLS_SERVER_NAME" >/dev/null 2>&1 || {
    err "TLS 证书不包含域名 $TLS_SERVER_NAME"
    exit 1
  }

  cert_pub="$(
    openssl x509 -in "$TLS_CERT_PATH" -pubkey -noout 2>/dev/null |
      openssl pkey -pubin -outform DER 2>/dev/null |
      openssl dgst -sha256 2>/dev/null
  )"
  key_pub="$(
    openssl pkey -in "$TLS_KEY_PATH" -pubout -outform DER 2>/dev/null |
      openssl dgst -sha256 2>/dev/null
  )"

  [ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ] || {
    err "TLS 证书与私钥不匹配"
    exit 1
  }

  info "HY2/TUIC 正式证书验证通过: $TLS_SERVER_NAME"
}
setup_service() {
  info "配置系统服务..."

  if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'SVC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/sing-box.pid"
command_background="yes"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"
depend() { need net; }
start_pre() {
  checkpath --directory --mode 0755 /run
  checkpath --directory --mode 0755 /var/log
}
SVC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1 || true
    if ! rc-service sing-box restart; then
      if [ -n "${CONFIG_BACKUP:-}" ] && [ -f "$CONFIG_BACKUP" ]; then
        warn "启动失败，正在恢复原配置"
        cp -p "$CONFIG_BACKUP" "$CONFIG_PATH"
        rc-service sing-box restart || true
      fi
      err "sing-box 启动失败"
      exit 1
    fi
  else
    cat > /etc/systemd/system/sing-box.service <<'SVC'
[Unit]
Description=Sing-box Proxy Server
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1 || true
    if ! systemctl restart sing-box; then
      if [ -n "${CONFIG_BACKUP:-}" ] && [ -f "$CONFIG_BACKUP" ]; then
        warn "启动失败，正在恢复原配置"
        cp -p "$CONFIG_BACKUP" "$CONFIG_PATH"
        systemctl restart sing-box || true
      fi
      err "sing-box 启动失败"
      exit 1
    fi
  fi
}

prompt_basic() {
  echo "请输入节点名称后缀(留空可不加):"
  read -r NODE_SUFFIX_RAW
  NODE_SUFFIX="${NODE_SUFFIX_RAW:+-$NODE_SUFFIX_RAW}"
  echo "$NODE_SUFFIX" > "$NODE_SUFFIX_FILE"

  echo "请输入节点连接 IP 或 DDNS 域名(留空自动检测公网 IP):"
  read -r CUSTOM_IP
  CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"
  if [ -n "$CUSTOM_IP" ]; then
    SERVER_HOST="$CUSTOM_IP"
  else
    SERVER_HOST="$(get_public_ip || echo YOUR_SERVER_IP)"
  fi


  echo "请选择要部署的协议(多个用空格分隔，例如: 1 2 3 4)"
  echo "1) Shadowsocks (SS)"
  echo "2) Hysteria2 (HY2)"
  echo "3) TUIC"
  echo "4) VLESS Reality"
  read -r PROTOCOL_INPUT

  ENABLE_SS=false
  ENABLE_HY2=false
  ENABLE_TUIC=false
  ENABLE_REALITY=false

  for num in $PROTOCOL_INPUT; do
    case "$num" in
      1) ENABLE_SS=true ;;
      2) ENABLE_HY2=true ;;
      3) ENABLE_TUIC=true ;;
      4) ENABLE_REALITY=true ;;
      *) warn "忽略无效选项: $num" ;;
    esac
  done

  if [ "$ENABLE_SS" = false ] && [ "$ENABLE_HY2" = false ] && [ "$ENABLE_TUIC" = false ] && [ "$ENABLE_REALITY" = false ]; then
    err "未选择任何协议"
    exit 1
  fi

  cat > "$PROTOCOL_FILE" <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
EOF
  chmod 600 "$PROTOCOL_FILE"

  TLS_SERVER_NAME=""
  TLS_CERT_PATH=""
  TLS_KEY_PATH=""
  if [ "$ENABLE_HY2" = true ] || [ "$ENABLE_TUIC" = true ]; then
    while true; do
      read -r -p "HY2/TUIC TLS 域名: " TLS_SERVER_NAME
      TLS_SERVER_NAME="$(sanitize_sni "$TLS_SERVER_NAME")"
      valid_sni "$TLS_SERVER_NAME" && break
      warn "请输入有效的完整域名"
    done

    read -r -p "正式证书 fullchain 路径 [/etc/letsencrypt/live/${TLS_SERVER_NAME}/fullchain.pem]: " TLS_CERT_PATH
    TLS_CERT_PATH="${TLS_CERT_PATH:-/etc/letsencrypt/live/${TLS_SERVER_NAME}/fullchain.pem}"
    read -r -p "正式证书私钥路径 [/etc/letsencrypt/live/${TLS_SERVER_NAME}/privkey.pem]: " TLS_KEY_PATH
    TLS_KEY_PATH="${TLS_KEY_PATH:-/etc/letsencrypt/live/${TLS_SERVER_NAME}/privkey.pem}"
  fi

  if [ "$ENABLE_SS" = true ]; then
    echo "选择 SS 加密方式：1) 2022-blake3-aes-128-gcm  2) aes-128-gcm"
    read -r SS_METHOD_CHOICE
    case "${SS_METHOD_CHOICE:-1}" in
      2) SS_METHOD="aes-128-gcm" ;;
      *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    esac
  else
    SS_METHOD="2022-blake3-aes-128-gcm"
  fi

  if [ "$ENABLE_REALITY" = true ]; then
    configure_reality_site || exit 1
  else
    REALITY_SNI=""
    REALITY_HANDSHAKE_SERVER=""
    REALITY_HANDSHAKE_PORT=""
  fi

  echo "请输入用户数量(默认 1):"
  read -r USER_COUNT_INPUT
  USER_COUNT="${USER_COUNT_INPUT:-1}"
  case "$USER_COUNT" in
    ''|*[!0-9]*) USER_COUNT=1 ;;
  esac
  [ "$USER_COUNT" -ge 1 ] 2>/dev/null || USER_COUNT=1
}

prompt_ports() {
  PORT_HY2=""
  PORT_TUIC=""
  PORT_REALITY=""

  [ "$ENABLE_HY2" != true ] || prompt_free_port PORT_HY2 "HY2"
  [ "$ENABLE_TUIC" != true ] || prompt_free_port PORT_TUIC "TUIC"
  [ "$ENABLE_REALITY" != true ] || prompt_free_port PORT_REALITY "Reality"
}

collect_users() {
  : > "$USER_DB"
  local i NOTE SAFE_NOTE SS_PORT SS_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_UUID

  for ((i=1; i<=USER_COUNT; i++)); do
    echo "===== 配置用户 $i / $USER_COUNT ====="
    read -r -p "备注名(留空默认 user$i): " NOTE
    NOTE="${NOTE:-user$i}"
    SAFE_NOTE="$(slugify "$NOTE")"
    [ -n "$SAFE_NOTE" ] || SAFE_NOTE="user$i"

    SS_PORT=""
    SS_PASSWORD=""
    if [ "$ENABLE_SS" = true ]; then
      prompt_free_port SS_PORT "[$NOTE] SS"

      SS_PASSWORD="$(rand_pass)"
    fi

    HY2_PASSWORD=""
    [ "$ENABLE_HY2" = true ] && HY2_PASSWORD="$(rand_pass)"

    TUIC_UUID=""
    TUIC_PASSWORD=""
    if [ "$ENABLE_TUIC" = true ]; then
      TUIC_UUID="$(rand_uuid)"
      TUIC_PASSWORD="$(rand_pass)"
    fi

    REALITY_UUID=""
    [ "$ENABLE_REALITY" = true ] && REALITY_UUID="$(rand_uuid)"

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
      "$NOTE" "$SS_PORT" "$SS_PASSWORD" "$HY2_PASSWORD" "$TUIC_UUID" "$TUIC_PASSWORD" "$REALITY_UUID" >> "$USER_DB"
  done
  chmod 600 "$USER_DB"
}

append_line() {
  printf '%s\n' "$1" >> "$TMP_CONFIG"
}

build_config() {
  TMP_CONFIG="$(mktemp)"
  : > "$TMP_CONFIG"

  append_line "{"
  append_line '  "log": {'
  append_line '    "level": "info",'
  append_line '    "timestamp": true'
  append_line '  },'
  append_line '  "inbounds": ['

  local first_inbound=true
  local NOTE SS_PORT SS_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_UUID
  local first_user

  if [ "$ENABLE_SS" = true ]; then
    while IFS=',' read -r NOTE SS_PORT SS_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_UUID; do
      [ -n "$SS_PORT" ] || continue
      [ "$first_inbound" = true ] || append_line "    ,"
      append_line "    {"
      append_line '      "type": "shadowsocks",'
      append_line "      \"tag\": \"ss-$(slugify "$NOTE")\","
      append_line '      "listen": "::",'
      append_line "      \"listen_port\": ${SS_PORT},"
      append_line "      \"method\": \"$(json_escape "$SS_METHOD")\","
      append_line "      \"password\": \"$(json_escape "$SS_PASSWORD")\""
      append_line "    }"
      first_inbound=false
    done < "$USER_DB"
  fi

  if [ "$ENABLE_HY2" = true ]; then
    [ "$first_inbound" = true ] || append_line "    ,"
    append_line "    {"
    append_line '      "type": "hysteria2",'
    append_line '      "tag": "hy2-in",'
    append_line '      "listen": "::",'
    append_line "      \"listen_port\": ${PORT_HY2},"
    append_line '      "users": ['

    first_user=true
    while IFS=',' read -r NOTE SS_PORT SS_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_UUID; do
      [ -n "$HY2_PASSWORD" ] || continue
      [ "$first_user" = true ] || append_line "        ,"
      append_line "        { \"name\": \"$(json_escape "$NOTE")\", \"password\": \"$(json_escape "$HY2_PASSWORD")\" }"
      first_user=false
    done < "$USER_DB"

    append_line '      ],'
    append_line '      "tls": {'
    append_line '        "enabled": true,'
    append_line '        "alpn": ["h3"],'
    append_line "        \"certificate_path\": \"$(json_escape "$TLS_CERT_PATH")\","
    append_line "        \"key_path\": \"$(json_escape "$TLS_KEY_PATH")\""
    append_line '      }'
    append_line '    }'
    first_inbound=false
  fi

  if [ "$ENABLE_TUIC" = true ]; then
    [ "$first_inbound" = true ] || append_line "    ,"
    append_line "    {"
    append_line '      "type": "tuic",'
    append_line '      "tag": "tuic-in",'
    append_line '      "listen": "::",'
    append_line "      \"listen_port\": ${PORT_TUIC},"
    append_line '      "users": ['

    first_user=true
    while IFS=',' read -r NOTE SS_PORT SS_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_UUID; do
      [ -n "$TUIC_UUID" ] || continue
      [ "$first_user" = true ] || append_line "        ,"
      append_line "        { \"name\": \"$(json_escape "$NOTE")\", \"uuid\": \"$TUIC_UUID\", \"password\": \"$(json_escape "$TUIC_PASSWORD")\" }"
      first_user=false
    done < "$USER_DB"

    append_line '      ],'
    append_line '      "congestion_control": "bbr",'
    append_line '      "tls": {'
    append_line '        "enabled": true,'
    append_line '        "alpn": ["h3"],'
    append_line "        \"certificate_path\": \"$(json_escape "$TLS_CERT_PATH")\","
    append_line "        \"key_path\": \"$(json_escape "$TLS_KEY_PATH")\""
    append_line '      }'
    append_line '    }'
    first_inbound=false
  fi

  if [ "$ENABLE_REALITY" = true ]; then
    [ "$first_inbound" = true ] || append_line "    ,"
    append_line "    {"
    append_line '      "type": "vless",'
    append_line '      "tag": "vless-in",'
    append_line '      "listen": "::",'
    append_line "      \"listen_port\": ${PORT_REALITY},"
    append_line '      "users": ['

    first_user=true
    while IFS=',' read -r NOTE SS_PORT SS_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_UUID; do
      [ -n "$REALITY_UUID" ] || continue
      [ "$first_user" = true ] || append_line "        ,"
      append_line "        { \"name\": \"$(json_escape "$NOTE")\", \"uuid\": \"$REALITY_UUID\", \"flow\": \"xtls-rprx-vision\" }"
      first_user=false
    done < "$USER_DB"

    append_line '      ],'
    append_line '      "tls": {'
    append_line '        "enabled": true,'
    append_line "        \"server_name\": \"$REALITY_SNI\","
    append_line '        "reality": {'
    append_line '          "enabled": true,'
    append_line "          \"handshake\": { \"server\": \"$(json_escape "$REALITY_HANDSHAKE_SERVER")\", \"server_port\": ${REALITY_HANDSHAKE_PORT} },"
    append_line "          \"private_key\": \"$REALITY_PK\","
    append_line "          \"short_id\": [\"$REALITY_SID\"]"
    append_line '        }'
    append_line '      }'
    append_line '    }'
    first_inbound=false
  fi

  append_line '  ],'
  append_line '  "outbounds": ['
  append_line '    { "type": "direct", "tag": "direct-out" }'
  append_line '  ]'
  append_line '}'

  if ! sing-box check -c "$TMP_CONFIG"; then
    err "配置校验失败，未覆盖现有配置"
    sing-box check -c "$TMP_CONFIG" || true
    rm -f "$TMP_CONFIG"
    exit 1
  fi

  CONFIG_BACKUP=""
  if [ -f "$CONFIG_PATH" ]; then
    CONFIG_BACKUP="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$CONFIG_PATH" "$CONFIG_BACKUP"
    info "原配置已备份: $CONFIG_BACKUP"
  fi
  install -m 600 "$TMP_CONFIG" "$CONFIG_PATH"
  rm -f "$TMP_CONFIG"
  info "配置校验通过"

  cat > "$CACHE_FILE" <<EOF
CUSTOM_IP=$CUSTOM_IP
SERVER_HOST=$SERVER_HOST
TLS_SERVER_NAME=$TLS_SERVER_NAME
REALITY_SNI=$REALITY_SNI
REALITY_HANDSHAKE_SERVER=$REALITY_HANDSHAKE_SERVER
REALITY_HANDSHAKE_PORT=$REALITY_HANDSHAKE_PORT
TLS_CERT_PATH=$TLS_CERT_PATH
TLS_KEY_PATH=$TLS_KEY_PATH
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
SS_METHOD=$SS_METHOD
PORT_HY2=${PORT_HY2:-}
PORT_TUIC=${PORT_TUIC:-}
PORT_REALITY=${PORT_REALITY:-}
REALITY_PUB=${REALITY_PUB:-}
REALITY_SID=${REALITY_SID:-}
EOF
  chmod 600 "$CACHE_FILE" "$USER_DB" "$CONFIG_PATH"
}

emit_qr() {
  local name="$1"
  local text="$2"
  local file_png="$QR_DIR/${name}.png"
  local file_txt="$QR_DIR/${name}.txt"

  printf '%s\n' "$text" > "$file_txt"

  if command -v qrencode >/dev/null 2>&1; then
    qrencode -o "$file_png" -s 6 -m 2 "$text" >/dev/null 2>&1 || true
    echo "----- QR: $name -----"
    qrencode -t ANSIUTF8 "$text" 2>/dev/null || true
    echo "---------------------"
  fi
}

generate_outputs() {
  : > "$URI_FILE"

  local NOTE SS_PORT SS_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_UUID
  local TAG SAFE
  while IFS=',' read -r NOTE SS_PORT SS_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_UUID; do
    TAG="${NOTE}${NODE_SUFFIX}"
    SAFE="$(slugify "$NOTE")"

    if [ "$ENABLE_SS" = true ] && [ -n "$SS_PORT" ]; then
      SS_USERINFO="${SS_METHOD}:${SS_PASSWORD}"
      SS_B64="$(b64 "$SS_USERINFO")"
      SS_URI="ss://${SS_B64}@${SERVER_HOST}:${SS_PORT}#$(url_encode "ss-${TAG}")"
      {
        echo "=== Shadowsocks | $NOTE ==="
        echo "$SS_URI"
        echo
      } >> "$URI_FILE"
      emit_qr "${SAFE}_ss" "$SS_URI"
    fi

    if [ "$ENABLE_HY2" = true ] && [ -n "$HY2_PASSWORD" ]; then
      HY2_URI="hy2://$(url_encode "$HY2_PASSWORD")@${SERVER_HOST}:${PORT_HY2}/?sni=${TLS_SERVER_NAME}&alpn=h3#$(url_encode "hy2-${TAG}")"
      {
        echo "=== Hysteria2 | $NOTE ==="
        echo "$HY2_URI"
        echo
      } >> "$URI_FILE"
      emit_qr "${SAFE}_hy2" "$HY2_URI"
    fi

    if [ "$ENABLE_TUIC" = true ] && [ -n "$TUIC_UUID" ]; then
      TUIC_URI="tuic://${TUIC_UUID}:$(url_encode "$TUIC_PASSWORD")@${SERVER_HOST}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=${TLS_SERVER_NAME}#$(url_encode "tuic-${TAG}")"
      {
        echo "=== TUIC | $NOTE ==="
        echo "$TUIC_URI"
        echo
      } >> "$URI_FILE"
      emit_qr "${SAFE}_tuic" "$TUIC_URI"
    fi

    if [ "$ENABLE_REALITY" = true ] && [ -n "$REALITY_UUID" ]; then
      REALITY_URI="vless://${REALITY_UUID}@${SERVER_HOST}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#$(url_encode "reality-${TAG}")"
      {
        echo "=== VLESS Reality | $NOTE ==="
        echo "$REALITY_URI"
        echo
      } >> "$URI_FILE"
      emit_qr "${SAFE}_reality" "$REALITY_URI"
    fi
  done < "$USER_DB"

  chmod 600 "$URI_FILE"
  find "$QR_DIR" -type f -exec chmod 600 {} \; 2>/dev/null || true
}

create_sb() {
  cat > /usr/local/bin/sb <<'EOSB'
#!/bin/bash
set -eu
set -o pipefail 2>/dev/null || true

CONFIG_DIR="/etc/sing-box"
URI_FILE="$CONFIG_DIR/uris.txt"
QR_DIR="$CONFIG_DIR/qrcodes"

service_cmd() {
  if command -v rc-service >/dev/null 2>&1 && [ -f /etc/alpine-release ]; then
    rc-service sing-box "$1"
  else
    systemctl "$1" sing-box
  fi
}

case "${1:-menu}" in
  start) service_cmd start ;;
  stop) service_cmd stop ;;
  restart) service_cmd restart ;;
  status)
    if command -v rc-service >/dev/null 2>&1 && [ -f /etc/alpine-release ]; then
      rc-service sing-box status
    else
      systemctl status sing-box --no-pager
    fi
    ;;
  uri|uris) cat "$URI_FILE" ;;
  qr) ls -1 "$QR_DIR" 2>/dev/null || true ;;
  *)
    echo "用法: sb {start|stop|restart|status|uri|qr}"
    ;;
esac
EOSB
  chmod +x /usr/local/bin/sb
}

main() {
  [ "$(id -u)" = "0" ] || { err "请以 root 运行"; exit 1; }
  info "DMIT 自建 HTTPS 站 Reality 安装脚本"
  mkdir -p "$CONFIG_DIR" "$QR_DIR" "$CERT_DIR"
  install_deps
  install_singbox
  prompt_basic
  prompt_ports
  collect_users
  generate_reality_keys
  generate_cert
  build_config
  setup_service
  create_sb
  generate_outputs

  echo
  echo "=========================================="
  info "部署完成"
  echo "服务器入口: $SERVER_HOST"
  if [ "$ENABLE_HY2" = true ] || [ "$ENABLE_TUIC" = true ]; then
    echo "HY2/TUIC TLS 域名: $TLS_SERVER_NAME"
  fi
  [ "$ENABLE_HY2" = true ] && echo "HY2 端口(全部 HY2 用户共用): $PORT_HY2"
  [ "$ENABLE_TUIC" = true ] && echo "TUIC 端口(全部 TUIC 用户共用): $PORT_TUIC"
  [ "$ENABLE_REALITY" = true ] && echo "Reality 端口(全部 Reality 用户共用): $PORT_REALITY"
  [ "$ENABLE_REALITY" = true ] && echo "Reality SNI: $REALITY_SNI"
  [ "$ENABLE_REALITY" = true ] && echo "Reality 本机后端: $REALITY_HANDSHAKE_SERVER:$REALITY_HANDSHAKE_PORT"
  echo "用户表: $USER_DB"
  echo "配置文件: $CONFIG_PATH"
  echo "链接汇总: $URI_FILE"
  echo "二维码目录: $QR_DIR"
  echo "管理命令: sb uri | sb qr | sb restart | sb status"
  echo "=========================================="
  echo
  cat "$URI_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
