
#!/usr/bin/env bash
# VLESS + REALITY + XTLS Vision: IPv6 inbound -> local IPv4 outbound
# Debian / Ubuntu, systemd. Does not overwrite existing Xray configurations.
set -Eeuo pipefail
umask 077

NAME="xray-v6v4"
DIR="/etc/${NAME}"
CONF="${DIR}/config.json"
CLIENT="${DIR}/client.txt"
UNIT="/etc/systemd/system/${NAME}.service"
SERVICE="${NAME}.service"
PORT="8443"
SNI="www.microsoft.com"
IPV6=""
IPV4=""
ACTION="install"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
help_msg() {
  cat <<'EOF'
Usage: bash install.sh [install|status|show|backup|uninstall] [options]
  --ipv6 ADDRESS     Bind to this local public IPv6 (auto-detect by default)
  --ipv4 ADDRESS     Bind outbound to this LOCAL IPv4, including NAT private IPv4
  --port PORT        TCP listen port (default 8443)
  --sni HOSTNAME     REALITY target & SNI (default www.microsoft.com)
  -h, --help         Show this help

Does NOT configure domain/DNS, enable UFW, or touch other Xray config files.
Existing installation will NOT be overwritten. Uninstall backs up before removal.
EOF
}

if [[ $# -gt 0 && "$1" != --* && "$1" != "-h" ]]; then ACTION="$1"; shift; fi
while (($#)); do
  case "$1" in
    --ipv6|--ipv4|--port|--sni)
      (($# >= 2)) || die "Missing value for $1"
      case "$1" in
        --ipv6) IPV6="$2" ;; --ipv4) IPV4="$2" ;;
        --port) PORT="$2" ;; --sni) SNI="$2" ;;
      esac; shift 2 ;;
    -h|--help) help_msg; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ $EUID -eq 0 ]] || die 'Please run as root (sudo -i).'

case "$ACTION" in
  show)
    [[ -f "$CLIENT" ]] || die 'Not installed or client file missing.'
    cat "$CLIENT"; exit 0 ;;
  status)
    systemctl --no-pager --full status "$SERVICE" || true
    [[ -f "$CONF" ]] && info "Config: $CONF"
    exit 0 ;;
  backup)
    [[ -f "$CONF" ]] || die 'No installation to back up.'
    FILE="/root/${NAME}-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -C /etc -czf "$FILE" "$NAME"
    chmod 600 "$FILE"
    info "Backup stored in $FILE (contains private credentials)."; exit 0 ;;
  uninstall)
    [[ -f "$UNIT" || -d "$DIR" ]] || die 'No installation to uninstall.'
    if [[ -d "$DIR" ]]; then
      FILE="/root/${NAME}-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
      tar -C /etc -czf "$FILE" "$NAME"
      chmod 600 "$FILE"
      info "Backup retained: $FILE"
    fi
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT"
    rm -rf "$DIR"
    systemctl daemon-reload
    info 'Dedicated service and its config removed. Shared Xray binary untouched.'
    exit 0 ;;
  install) ;;
  *) die "Unknown action: $ACTION" ;;
esac

[[ -e "$UNIT" || -e "$CONF" || -e "$CLIENT" ]] && {
  warn 'An installation already exists; nothing was overwritten.'
  [[ -f "$CLIENT" ]] && cat "$CLIENT"
  exit 0
}
[[ -r /etc/os-release ]] || die 'Only Debian/Ubuntu supported.'
# shellcheck source=/dev/null
. /etc/os-release
case "$ID" in debian|ubuntu) ;; *) die "Unsupported OS: $ID" ;; esac
command -v systemctl >/dev/null || die 'systemd is required.'

PACKAGES=()
command -v curl >/dev/null || PACKAGES+=(curl)
command -v openssl >/dev/null || PACKAGES+=(openssl)
command -v python3 >/dev/null || PACKAGES+=(python3)
command -v ip >/dev/null || PACKAGES+=(iproute2)
command -v ss >/dev/null || PACKAGES+=(iproute2)
if ((${#PACKAGES[@]})); then
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates "${PACKAGES[@]}"
fi

[[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) || die 'Invalid port.'
PORT="$((10#$PORT))"

if [[ -z "$IPV6" ]]; then
  IPV6="$(ip -6 -o addr show scope global | python3 -c '
import sys, ipaddress
for line in sys.stdin:
    fields = line.split()
    if any(flag in fields for flag in ("temporary", "deprecated", "tentative")):
        continue
    try:
        address = ipaddress.ip_interface(fields[fields.index("inet6") + 1]).ip
        if address.is_global:
            print(address)
            break
    except (ValueError, IndexError):
        pass
')"
fi
[[ -n "$IPV6" ]] || die 'No globally routable local IPv6 found. Use --ipv6 if appropriate.'

if [[ -z "$IPV4" ]]; then
  IPV4="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n 1)"
fi
[[ -n "$IPV4" ]] || die 'No local IPv4 route found (IPv6-only VPS needs an IPv4 egress).'

python3 - "$IPV6" "$IPV4" "$SNI" <<'PY' || die 'IP address or SNI validation failed.'
import ipaddress, re, sys
v6, v4, sni = sys.argv[1:]
assert ipaddress.IPv6Address(v6).is_global, 'IPv6 must be public/global'
assert not ipaddress.IPv4Address(v4).is_loopback, 'IPv4 cannot be loopback'
assert len(sni) <= 253 and all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', l) for l in sni.split('.')), 'Invalid SNI'
PY
ip -6 -o addr show | awk '{split($4,a,"/");print a[1]}' | grep -Fxq "$IPV6" || die 'IPv6 is not assigned to this VPS.'
ip -4 -o addr show | awk '{split($4,a,"/");print a[1]}' | grep -Fxq "$IPV4" || die 'IPv4 must be an actual LOCAL interface address (NAT inner IP is OK).'
if [[ -n "$(ss -H -ltn "sport = :$PORT")" ]]; then
  die "TCP port $PORT is already used. Choose --port with another value."
fi

info "IPv6 inbound: [$IPV6]:$PORT"
info "Local IPv4 outbound: $IPV4"
PUBLIC_IPV4="$(curl -4fsS --connect-timeout 6 --max-time 12 https://api.ipify.org || true)"
[[ "$PUBLIC_IPV4" =~ ^[0-9.]+$ ]] || die 'Could not verify IPv4 Internet egress with curl -4.'
info "Public IPv4 egress check: $PUBLIC_IPV4"

if ! command -v xray >/dev/null 2>&1; then
  info 'Installing Xray-core via official XTLS/Xray-install...'
  tmp_installer="$(mktemp)"
  trap 'rm -f "${tmp_installer:-}"' EXIT
  curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh -o "$tmp_installer"
  bash "$tmp_installer" install --without-geodata
  rm -f "$tmp_installer"
  trap - EXIT
fi
XRAY_BIN="$(command -v xray || true)"
[[ -n "$XRAY_BIN" ]] || die 'Xray was not found after installation.'

UUID="$($XRAY_BIN uuid | tr -d '\r\n')"
KEYS="$($XRAY_BIN x25519)"
PRIVATE="$(printf '%s\n' "$KEYS" | sed -nE '/^[[:space:]]*Private[Kk]ey:/ {s/^[^:]*:[[:space:]]*//;p;q;}')"
PUBLIC="$(printf '%s\n' "$KEYS" | sed -nE '/^[[:space:]]*(Password|Public[Kk]ey):/ {s/^[^:]*:[[:space:]]*//;p;q;}')"
SHORT="$(openssl rand -hex 8)"
[[ -n "$UUID" && -n "$PRIVATE" && -n "$PUBLIC" && -n "$SHORT" ]] || die 'Key/UUID generation failed.'

mkdir -p "$DIR"
TMP_CONF="$(mktemp)"
trap 'rm -f "${TMP_CONF:-}"' EXIT
python3 - "$IPV6" "$IPV4" "$PORT" "$UUID" "$PRIVATE" "$SHORT" "$SNI" > "$TMP_CONF" <<'PY'
import json, sys
ipv6, ipv4, port, uuid, private, short, sni = sys.argv[1:]
obj = {
  'log': {'loglevel': 'warning'},
  'dns': {'servers': ['1.1.1.1', '8.8.8.8'], 'queryStrategy': 'UseIPv4'},
  'inbounds': [{
    'tag': 'v6-reality-in', 'listen': ipv6, 'port': int(port), 'protocol': 'vless',
    'settings': {'users': [{'id': uuid, 'flow': 'xtls-rprx-vision'}], 'decryption': 'none'},
    'streamSettings': {
      'network': 'tcp', 'security': 'reality',
      'realitySettings': {
        'show': False, 'target': sni + ':443', 'xver': 0,
        'serverNames': [sni], 'privateKey': private, 'shortIds': [short],
        'limitFallbackUpload': {'afterBytes': 0, 'bytesPerSec': 16384, 'burstBytesPerSec': 16384},
        'limitFallbackDownload': {'afterBytes': 0, 'bytesPerSec': 16384, 'burstBytesPerSec': 16384}
      }
    }
  }],
  'outbounds': [{
    'tag': 'ipv4-direct', 'protocol': 'freedom', 'sendThrough': ipv4,
    'settings': {'domainStrategy': 'AsIs'},
    'streamSettings': {'sockopt': {'domainStrategy': 'ForceIPv4'}}
  }],
  'routing': {'domainStrategy': 'AsIs', 'rules': [
    {'type': 'field', 'inboundTag': ['v6-reality-in'], 'outboundTag': 'ipv4-direct'}
  ]}
}
print(json.dumps(obj, ensure_ascii=False, indent=2))
PY
"$XRAY_BIN" run -test -config "$TMP_CONF" || die 'Xray config validation failed.'

if ! getent group "$NAME" >/dev/null 2>&1; then
  groupadd --system "$NAME"
fi
if ! id "$NAME" >/dev/null 2>&1; then
  useradd --system --no-create-home --gid "$NAME" --shell /usr/sbin/nologin "$NAME"
fi
chown "root:$NAME" "$DIR"
chmod 750 "$DIR"
install -m 640 -o root -g "$NAME" "$TMP_CONF" "$CONF"
rm -f "$TMP_CONF"
trap - EXIT

python3 - "$IPV6" "$PORT" "$UUID" "$PUBLIC" "$SHORT" "$SNI" "$IPV4" "$PUBLIC_IPV4" > "$CLIENT" <<'PY'
import sys, urllib.parse
ipv6, port, uuid, pbk, sid, sni, local4, public4 = sys.argv[1:]
params = urllib.parse.urlencode({
    'encryption':'none', 'security':'reality', 'sni':sni,
    'fp':'chrome', 'pbk':pbk, 'sid':sid, 'type':'tcp',
    'flow':'xtls-rprx-vision'
})
print('VLESS + REALITY + Vision | IPv6 inbound / IPv4 outbound')
print('IPv6 inbound: [' + ipv6 + ']:' + port)
print('Local IPv4 outbound: ' + local4)
print('Observed public IPv4: ' + public4)
print('SNI: ' + sni)
print('VLESS link:')
print('vless://' + uuid + '@[' + ipv6 + ']:' + port + '?' + params + '#IPv6-in-IPv4-out')
PY
chmod 600 "$CLIENT"

cat > "$UNIT" <<EOF
[Unit]
Description=Xray VLESS REALITY Vision (IPv6 in, IPv4 out)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NAME
Group=$NAME
ExecStart=$XRAY_BIN run -config $CONF
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$UNIT"
systemctl daemon-reload
systemctl enable --now "$SERVICE"
sleep 1
if ! systemctl is-active --quiet "$SERVICE"; then
  journalctl -u "$SERVICE" --no-pager -n 30 >&2 || true
  die "Service failed to start. Inspect: journalctl -u $SERVICE -n 50 --no-pager"
fi
info "Installed successfully; config: $CONF"
cat "$CLIENT"
warn "Open TCP $PORT for IPv6 in cloud firewall/security groups. UFW is NOT changed automatically."
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'; then
  warn "UFW active: check IPv6=yes and permit inbound TCP $PORT (e.g. ufw allow in to $IPV6 port $PORT proto tcp)."
fi
warn 'Keep /etc/xray-v6v4/client.txt private. Running bash install.sh show prints it again.'