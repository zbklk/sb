#!/bin/bash
set -eu
set -o pipefail 2>/dev/null || true

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" = "0" ] || { err "请以 root 运行"; exit 1; }

CONFIG_DIR="/etc/sing-box"
CONFIG_PATH="$CONFIG_DIR/config.json"
CACHE_FILE="$CONFIG_DIR/.config_cache"
URI_FILE="$CONFIG_DIR/uris.txt"
QR_DIR="$CONFIG_DIR/qrcodes"
CERT_DIR="$CONFIG_DIR/certs"
PROTOCOL_FILE="$CONFIG_DIR/.protocols"
NODE_SUFFIX_FILE="/root/node_names.txt"
USER_DB="$CONFIG_DIR/users.csv"

mkdir -p "$CONFIG_DIR" "$QR_DIR" "$CERT_DIR"

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
      apk add --no-cache bash curl ca-certificates openssl jq qrencode coreutils grep sed gawk
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y bash curl ca-certificates openssl jq qrencode coreutils grep sed gawk
      ;;
    redhat)
      yum install -y bash curl ca-certificates openssl jq qrencode coreutils grep sed gawk || \
      dnf install -y bash curl ca-certificates openssl jq qrencode coreutils grep sed gawk
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
  if [ "$ENABLE_HY2" != "true" ] && [ "$ENABLE_TUIC" != "true" ]; then
    return 0
  fi

  if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
    info "生成自签证书..."
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$CERT_DIR/privkey.pem" \
      -out "$CERT_DIR/fullchain.pem" \
      -days 3650 \
      -subj "/CN=${TLS_SERVER_NAME}" >/dev/null 2>&1 || {
        err "证书生成失败"
        exit 1
      }
  fi
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
    rc-service sing-box restart
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
    systemctl restart sing-box
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

  echo "请输入 TLS / 伪装域名 / 证书名(留空默认 www.bing.com):"
  read -r TLS_SERVER_NAME
  TLS_SERVER_NAME="$(echo "${TLS_SERVER_NAME:-www.bing.com}" | tr -d '[:space:]')"

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
    echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
    read -r REALITY_SNI
    REALITY_SNI="$(echo "${REALITY_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
  else
    REALITY_SNI="addons.mozilla.org"
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

  if [ "$ENABLE_HY2" = true ]; then
    read -r -p "HY2 端口(留空随机，所有 HY2 用户共用同一端口): " PORT_HY2
    PORT_HY2="${PORT_HY2:-$(rand_port)}"
  fi
  if [ "$ENABLE_TUIC" = true ]; then
    read -r -p "TUIC 端口(留空随机，所有 TUIC 用户共用同一端口): " PORT_TUIC
    PORT_TUIC="${PORT_TUIC:-$(rand_port)}"
  fi
  if [ "$ENABLE_REALITY" = true ]; then
    read -r -p "Reality 端口(留空随机，所有 Reality 用户共用同一端口): " PORT_REALITY
    PORT_REALITY="${PORT_REALITY:-$(rand_port)}"
  fi
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
      read -r -p "[$NOTE] SS 端口(留空随机，每个 SS 用户单独端口): " SS_PORT
      SS_PORT="${SS_PORT:-$(rand_port)}"
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
  local comma

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
    append_line "        \"certificate_path\": \"$CERT_DIR/fullchain.pem\","
    append_line "        \"key_path\": \"$CERT_DIR/privkey.pem\""
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
    append_line "        \"certificate_path\": \"$CERT_DIR/fullchain.pem\","
    append_line "        \"key_path\": \"$CERT_DIR/privkey.pem\""
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
    append_line "          \"handshake\": { \"server\": \"$REALITY_SNI\", \"server_port\": 443 },"
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

  mv "$TMP_CONFIG" "$CONFIG_PATH"

  cat > "$CACHE_FILE" <<EOF
CUSTOM_IP=$CUSTOM_IP
SERVER_HOST=$SERVER_HOST
TLS_SERVER_NAME=$TLS_SERVER_NAME
REALITY_SNI=$REALITY_SNI
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

  if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
    info "配置校验通过"
  else
    err "配置校验失败，请检查 $CONFIG_PATH"
    sing-box check -c "$CONFIG_PATH" || true
    exit 1
  fi
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
      HY2_URI="hy2://$(url_encode "$HY2_PASSWORD")@${SERVER_HOST}:${PORT_HY2}/?sni=${TLS_SERVER_NAME}&alpn=h3&insecure=1#$(url_encode "hy2-${TAG}")"
      {
        echo "=== Hysteria2 | $NOTE ==="
        echo "$HY2_URI"
        echo
      } >> "$URI_FILE"
      emit_qr "${SAFE}_hy2" "$HY2_URI"
    fi

    if [ "$ENABLE_TUIC" = true ] && [ -n "$TUIC_UUID" ]; then
      TUIC_URI="tuic://${TUIC_UUID}:$(url_encode "$TUIC_PASSWORD")@${SERVER_HOST}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=${TLS_SERVER_NAME}&insecure=1#$(url_encode "tuic-${TAG}")"
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
  echo "TLS/伪装域名: $TLS_SERVER_NAME"
  [ "$ENABLE_HY2" = true ] && echo "HY2 端口(全部 HY2 用户共用): $PORT_HY2"
  [ "$ENABLE_TUIC" = true ] && echo "TUIC 端口(全部 TUIC 用户共用): $PORT_TUIC"
  [ "$ENABLE_REALITY" = true ] && echo "Reality 端口(全部 Reality 用户共用): $PORT_REALITY"
  [ "$ENABLE_REALITY" = true ] && echo "Reality SNI: $REALITY_SNI"
  echo "用户表: $USER_DB"
  echo "配置文件: $CONFIG_PATH"
  echo "链接汇总: $URI_FILE"
  echo "二维码目录: $QR_DIR"
  echo "管理命令: sb uri | sb qr | sb restart | sb status"
  echo "=========================================="
  echo
  cat "$URI_FILE"
}

main "$@"