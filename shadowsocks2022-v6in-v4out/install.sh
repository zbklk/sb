#!/usr/bin/env bash
# Independent SS2022 IPv6-in / IPv4-out deployment using an existing Xray-core.
# Does NOT modify xray-v6v4.service, /etc/xray-v6v4 or other proxy services.
set -Eeuo pipefail
umask 077

VERSION=1.0.0
NAME=ss2022-v6v4
DIR=/etc/$NAME
CONF=$DIR/config.json
CLIENT=$DIR/client.txt
UNIT=/etc/systemd/system/$NAME.service
SERVICE=$NAME.service
PORT=38444
METHOD=2022-blake3-aes-256-gcm
IPV6=
IPV4=

info() { printf '[信息] %s\n' "$*"; }
warn() { printf '[提醒] %s\n' "$*" >&2; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }
need_root() { (( EUID == 0 )) || die '请使用 root 执行'; }
installed() { [[ -f "$CONF" && -f "$CLIENT" && -f "$UNIT" ]]; }
require_commands() {
  local command_name
  for command_name in xray python3 openssl curl ip ss systemctl tar; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少依赖：$command_name（请先安装；Xray 可复用现有核心）"
  done
}
valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 ))
}
auto_ipv6() {
  ip -6 -o addr show scope global | python3 -c '
import ipaddress,sys
for line in sys.stdin:
    fields=line.split()
    if any(flag in fields for flag in ("tentative","deprecated","dadfailed","temporary")):
        continue
    try:
        value=str(ipaddress.ip_interface(fields[fields.index("inet6")+1]).ip)
        if ipaddress.ip_address(value).is_global:
            print(value)
            break
    except (ValueError, IndexError): pass
'
}
auto_ipv4() {
  ip -4 route get 1.1.1.1 | python3 -c '
import sys
fields=sys.stdin.read().split()
print(fields[fields.index("src")+1] if "src" in fields else "")
'
}
validate_addresses() {
  python3 - "$IPV6" "$IPV4" <<'PY'
import ipaddress,sys
v6=ipaddress.IPv6Address(sys.argv[1])
v4=ipaddress.IPv4Address(sys.argv[2])
assert v6.is_global, "IPv6 必须是公网全局单播地址"
assert not any((v4.is_loopback,v4.is_link_local,v4.is_multicast,v4.is_unspecified)), "IPv4 地址无效"
PY
  ip -6 -o addr show | grep -Fq " $IPV6/" || die "IPv6 未绑定到本机网卡：$IPV6"
  ip -4 -o addr show | grep -Fq " $IPV4/" || die "IPv4 未绑定到本机网卡：$IPV4"
}
check_free_port() {
  if [[ -n "$(ss -H -ltn "sport = :$PORT")" || -n "$(ss -H -lun "sport = :$PORT")" ]]; then
    die "TCP 或 UDP $PORT 已被占用，请改用 --port"
  fi
}
create_user() {
  getent group "$NAME" >/dev/null 2>&1 || groupadd --system "$NAME" || die '创建系统组失败'
  id "$NAME" >/dev/null 2>&1 || useradd --system --no-create-home --gid "$NAME" --shell /usr/sbin/nologin "$NAME" || die '创建系统用户失败'
}
make_config() {
  # arguments: output-file IPv6 IPv4 port SS2022-base64-PSK
  python3 - "$@" <<'PY'
import json,sys
output,v6,v4,port,password=sys.argv[1:]
conf={
  "log":{"loglevel":"warning"},
  "dns":{"servers":["1.1.1.1","8.8.8.8"],"queryStrategy":"UseIPv4"},
  "inbounds":[{
    "tag":"ss2022-v6-in","listen":v6,"port":int(port),
    "protocol":"shadowsocks",
    "settings":{"method":"2022-blake3-aes-256-gcm","password":password,"network":"tcp,udp"}
  }],
  "outbounds":[{
    "tag":"ipv4-direct","protocol":"freedom","sendThrough":v4,
    "settings":{"domainStrategy":"AsIs"},
    "streamSettings":{"sockopt":{"domainStrategy":"ForceIPv4"}}
  }],
  "routing":{"domainStrategy":"AsIs","rules":[{
    "type":"field","inboundTag":["ss2022-v6-in"],"outboundTag":"ipv4-direct"
  }]}
}
with open(output,"w",encoding="utf-8") as f:
    json.dump(conf,f,indent=2)
    f.write("\n")
PY
}
make_client() {
  # arguments: server-config output-client
  python3 - "$1" "$2" <<'PY'
import base64,json,sys,urllib.parse
conf=json.load(open(sys.argv[1],encoding="utf-8"))
inbound=conf["inbounds"][0]
settings=inbound["settings"]
raw=f'{settings["method"]}:{settings["password"]}'.encode()
userinfo=base64.urlsafe_b64encode(raw).decode().rstrip("=")
v6=inbound["listen"]
port=inbound["port"]
uri=f'ss://{userinfo}@[{v6}]:{port}#SS2022-IPv6-to-IPv4'
with open(sys.argv[2],"w",encoding="utf-8") as f:
    f.write(f'Shadowsocks 2022 | IPv6 入站 / IPv4 出站\n')
    f.write(f'IPv6 服务端: [{v6}]:{port} (TCP+UDP)\n')
    f.write(f'加密算法: {settings["method"]}\n')
    f.write(f'绑定本机 IPv4 出站: {conf["outbounds"][0]["sendThrough"]}\n')
    f.write('Shadowrocket 扫码导入链接:\n'+uri+'\n')
PY
}
create_unit() {
  local bin
  bin=$(command -v xray) || die '找不到 Xray-core'
  cat > "$UNIT" <<EOF
[Unit]
Description=Shadowsocks 2022 (IPv6 in / IPv4 out) - independent Xray service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NAME
Group=$NAME
ExecStart=$bin run -config $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
}
show_link() {
  installed || die 'SS2022 尚未安装'
  printf '\n'
  cat "$CLIENT"
  if command -v qrencode >/dev/null 2>&1; then
    local link
    link=$(grep -m 1 '^ss://' "$CLIENT") || die '没有找到 SS2022 链接'
    printf '\n'
    printf '%s' "$link" | qrencode -t UTF8 -m 1 || warn '二维码生成失败，请复制 ss:// 链接'
  else
    warn '未安装 qrencode；可执行 apt-get install -y qrencode 后再运行 show'
  fi
  warn '请保护 ss:// 节点链接；里面包含完整预共享密钥，不要公开分享'
}
do_install() (
  set -Eeuo pipefail
  need_root
  require_commands
  [[ ! -e "$CONF" && ! -e "$UNIT" && ! -e "$CLIENT" ]] || die "发现已有 $NAME 节点，拒绝覆盖；可使用 show/test/status"
  valid_port "$PORT" || die '端口需要在 1024–65535 范围内'
  [[ -n "$IPV6" ]] || IPV6=$(auto_ipv6)
  [[ -n "$IPV4" ]] || IPV4=$(auto_ipv4)
  [[ -n "$IPV6" && -n "$IPV4" ]] || die '无法自动识别全局 IPv6 / 本机 IPv4，请用 --ipv6 与 --ipv4 指定'
  validate_addresses || die 'IPv6/IPv4 地址检查失败'
  check_free_port
  info "独立 SS2022 监听：[$IPV6]:$PORT （TCP+UDP）"
  info "绑定本机 IPv4 出站：$IPV4"
  curl -4fsS --interface "$IPV4" --connect-timeout 5 --max-time 12 https://api.ipify.org >/dev/null || die '指定 IPv4 无法访问公网，请先检查网络'
  if command -v timedatectl >/dev/null 2>&1; then
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" != 'no' ]] || warn '系统时间未同步：SS2022 需校准时间，客户端与服务器偏差过大会失败'
  fi
  local stage password created=0
  stage=$(mktemp -d /tmp/ss2022-v6v4-install.XXXXXXXX) || die '无法建立暂存目录'
  chmod 700 "$stage"
  cleanup() {
    local rc=$?
    rm -rf -- "$stage"
    if (( rc != 0 && created == 1 )); then
      systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
      rm -f -- "$UNIT"
      systemctl daemon-reload >/dev/null 2>&1 || true
      rm -rf -- "$DIR"
      warn '本次 SS2022 安装未成功，已清理新建服务；原 VLESS 服务未更改'
    fi
  }
  trap cleanup EXIT
  password=$(openssl rand -base64 32 | tr -d '\n') || die '生成预共享密钥失败'
  make_config "$stage/config.json" "$IPV6" "$IPV4" "$PORT" "$password" || die '生成配置失败'
  make_client "$stage/config.json" "$stage/client.txt" || die '生成客户端链接失败'
  xray run -test -format json -config "$stage/config.json" || die 'Xray-core 拒绝 SS2022 服务端配置'
  create_user
  mkdir -p "$DIR"
  created=1
  install -o root -g "$NAME" -m 640 "$stage/config.json" "$CONF" || die '安装服务端配置失败'
  install -o root -g root -m 600 "$stage/client.txt" "$CLIENT" || die '安装客户端链接失败'
  create_unit
  systemctl daemon-reload || die 'systemd reload 失败'
  systemctl enable --now "$SERVICE" || die 'SS2022 服务启动失败'
  sleep 1
  systemctl is-active --quiet "$SERVICE" || die 'SS2022 服务未保持运行'
  info "SS2022 节点已启动。请在防火墙/商家安全组允许 IPv6 TCP 和 UDP $PORT"
  if self_test; then
    info '本机 Shadowsocks 2022 → IPv4 完整自检通过'
  else
    warn '服务已启动，但本机完整代理测试失败；需查看 journalctl，不代表手机一定无法连接'
  fi
  show_link
  warn '本机自检走 VPS 本地 IPv6，不证明手机外部 IPv6 网络与防火墙可达'
)
do_status() {
  installed || die 'SS2022 尚未安装'
  systemctl --no-pager --full status "$SERVICE" || true
  ss -6 -lntup | grep -F "$PORT" || true
  info '原有 xray-v6v4.service 不受此服务影响'
}
self_test() (
  set -Eeuo pipefail
  need_root
  installed || die 'SS2022 尚未安装'
  require_commands
  local tmp pid='' port expected observed n=0
  tmp=$(mktemp -d /tmp/ss2022-v6v4-test.XXXXXXXX) || die '创建自检临时目录失败'
  chmod 700 "$tmp"
  trap '[[ -z "$pid" ]] || { kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; }; rm -rf -- "$tmp"' EXIT
  port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1",0))
    print(s.getsockname()[1])
PY
)
  python3 - "$CONF" "$tmp/client.json" "$port" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
i=c["inbounds"][0];s=i["settings"]
client={
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "tag":"local-socks","listen":"127.0.0.1","port":int(sys.argv[3]),
    "protocol":"socks","settings":{"auth":"noauth","udp":False}
  }],
  "outbounds":[{
    "tag":"ss2022-proxy","protocol":"shadowsocks",
    "settings":{"address":i["listen"],"port":i["port"],"method":s["method"],"password":s["password"]}
  }]
}
with open(sys.argv[2],"w") as f:json.dump(client,f)
PY
  xray run -test -format json -config "$tmp/client.json" > "$tmp/check.log" 2>&1 || {
    warn '临时 Xray SS2022 客户端配置校验失败'
    tail -n 12 "$tmp/check.log"
    exit 1
  }
  xray run -config "$tmp/client.json" > "$tmp/xray.log" 2>&1 & pid=$!
  while (( n < 25 )); do
    kill -0 "$pid" >/dev/null 2>&1 || { warn '临时 Xray 客户端提前退出'; tail -n 10 "$tmp/xray.log"; exit 1; }
    if [[ -n "$(ss -H -ltn "sport = :$port")" ]]; then break; fi
    sleep 0.2
    n=$((n+1))
  done
  expected=$(python3 - "$CONF" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["outbounds"][0]["sendThrough"])
PY
)
  info '正在经临时本机 SOCKS5 → SS2022 IPv6 入站 → Freedom IPv4 出站访问 api.ipify.org ...'
  observed=$(curl -fsS --socks5-hostname "127.0.0.1:$port" --connect-timeout 8 --max-time 20 https://api.ipify.org) || {
    warn '完整代理测试失败（请检查监听、密钥、DNS 与 Xray 运行日志）'
    tail -n 12 "$tmp/xray.log"
    exit 1
  }
  [[ "$observed" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "代理出口不是 IPv4：$observed"
  local direct
  direct=$(curl -4fsS --interface "$expected" --connect-timeout 5 --max-time 12 https://api.ipify.org) || die '无法检测绑定 IPv4 的公网出口'
  [[ "$observed" == "$direct" ]] || die "代理出口 $observed 与绑定 IPv4 的公网出口 $direct 不一致"
  info "SS2022 完整自检通过：公网 IPv4 出口 $observed"
)
do_backup() {
  need_root
  installed || die 'SS2022 尚未安装'
  local file
  file=$(mktemp "/root/ss2022-v6v4-backup-$(date +%Y%m%d-%H%M%S)-XXXXXXXX.tar.gz") || die '备份路径创建失败'
  tar -czf "$file" -C "$DIR" config.json client.txt || die '备份失败'
  chmod 600 "$file"
  info "备份完成（内含预共享密钥，请妥善保存）：$file"
}
do_uninstall() {
  need_root
  installed || die 'SS2022 尚未安装'
  local answer
  read -r -p '只卸载 SS2022，保留 VLESS 和 Xray 核心。输入 YES 确认：' answer
  [[ "$answer" == 'YES' ]] || { info '已取消'; return 0; }
  do_backup
  systemctl disable --now "$SERVICE" || warn '停止服务失败'
  rm -f -- "$UNIT"
  systemctl daemon-reload || warn 'systemd reload 失败'
  rm -rf -- "$DIR"
  info 'SS2022 独立服务已卸载；原有 VLESS 服务与 Xray 核心保持不变'
}
show_menu() {
  while true; do
    printf '\n=== SS2022 IPv6 入站 / IPv4 出站 V%s ===\n' "$VERSION"
    printf '1) 安装独立 SS2022 节点（默认 38444）\n2) 查看配置与二维码\n3) 状态\n4) 完整代理自检\n5) 备份\n6) 卸载独立节点\n0) 退出\n'
    local choice
    read -r -p '请选择 [0-6]：' choice || return 0
    case "$choice" in
      1) do_install || warn '安装失败' ;;
      2) show_link || warn '查看失败' ;;
      3) do_status || warn '查询失败' ;;
      4) self_test || warn '自检失败' ;;
      5) do_backup || warn '备份失败' ;;
      6) do_uninstall || warn '卸载失败' ;;
      0) return 0 ;;
      *) warn '无效选项' ;;
    esac
  done
}
usage() {
  cat <<'USAGE'
SS2022 IPv6-in / IPv4-out v1.0.0
  bash install.sh install [--port 38444] [--ipv6 <public-v6>] [--ipv4 <local-v4>]
  bash install.sh show | status | test | backup | uninstall | menu
默认安装独立 ss2022-v6v4.service，不会修改 xray-v6v4.service。
USAGE
}
main() {
  local command_name=menu
  if (( $# > 0 )); then command_name=$1; shift; fi
  while (( $# > 0 )); do
    case "$1" in
      --port|--ipv6|--ipv4)
        (( $# >= 2 )) || die "参数 $1 缺少值"
        case "$1" in
          --port) PORT=$2 ;;
          --ipv6) IPV6=$2 ;;
          --ipv4) IPV4=$2 ;;
        esac
        shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  case "$command_name" in
    install) do_install ;;
    show|qr) need_root; show_link ;;
    status) need_root; do_status ;;
    test|selftest) self_test ;;
    backup) do_backup ;;
    uninstall) do_uninstall ;;
    menu) need_root; show_menu ;;
    help|-h|--help) usage ;;
    *) usage; die "未知命令：$command_name" ;;
  esac
}
main "$@"
