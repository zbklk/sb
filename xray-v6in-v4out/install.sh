#!/usr/bin/env bash
# Xray VLESS + REALITY + Vision — IPv6 inbound, local IPv4 outbound
# V2: interactive menu, QR, safe updates, backup / restore.
# Debian/Ubuntu + systemd only. Never modifies existing Xray instance configs.
set -Eeuo pipefail
umask 077

NAME=xray-v6v4
DIR=/etc/$NAME
CONF=$DIR/config.json
CLIENT=$DIR/client.txt
UNIT=/etc/systemd/system/$NAME.service
SERVICE=$NAME.service
PORT=8443
SNI=www.microsoft.com
IPV6=
IPV4=
RESTORE_FILE=
YES=0
ACTION=
PORT_SET=0
SNI_SET=0
SCRIPT_VERSION=2.0.3

info() { printf '\033[32m[信息]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[提醒]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }
exists() { [[ -f "$CONF" && -f "$CLIENT" && -f "$UNIT" ]]; }
need_root() { (( EUID == 0 )) || die '请先 sudo -i 切换 root。'; }
help_msg() {
  cat <<'EOF'
Xray IPv6 入站 / IPv4 出站 V2 交互管理脚本
用法：bash install.sh [menu|install|show|qr|status|port|sni|rotate|restart|backup|restore|uninstall] [选项]
无参数且为交互终端：显示中文菜单；无交互终端：按默认参数安装（已安装则保持不变）。
  --ipv6 地址     安装时绑定的本机公网 IPv6（默认自动检测）
  --ipv4 地址     本机出站 IPv4（NAT VPS 填内网 IPv4；默认从路由检测）
  --port 端口     安装时端口，或 port 命令的新端口（默认 8443）
  --sni 域名      安装时 REALITY SNI，或 sni 命令的新 SNI
  --file 文件     restore 命令指定备份 .tar.gz
  --yes           确认 rotate、restore 或 uninstall 等操作
  -h, --help      显示帮助
注意：不修改 UFW 或其它现有 Xray/sing-box 配置，不申请证书，不需要域名解析。
EOF
}

# Prompt requires a real TTY. Commands invoked via "bash <(curl ...)" retain it.
prompt() {
  local __var=$1 message=$2 fallback=${3:-} answer
  if [[ -t 0 ]]; then
    read -r -p "$message" answer || return 1
  elif [[ -e /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then
    read -r -p "$message" answer </dev/tty || return 1
  else
    return 1
  fi
  printf -v "$__var" '%s' "${answer:-$fallback}"
}
confirm() {
  (( YES == 1 )) && return 0
  local choice=''
  prompt choice "${1}（输入 YES 确认）：" '' || die '无交互终端，拒绝危险操作；明确需要时可加 --yes。'
  [[ "$choice" == YES ]]
}
pause_menu() { local answer; prompt answer '按回车继续...' '' || true; }

need_system() {
  [[ -r /etc/os-release ]] || die '找不到 /etc/os-release。'
  # /etc/os-release defines NAME="Debian GNU/Linux" or NAME="Ubuntu".
  # Keep its variables local so they cannot overwrite our service NAME.
  local ID NAME
  # shellcheck source=/dev/null
  . /etc/os-release
  case "$ID" in debian|ubuntu) ;; *) die "仅支持 Debian/Ubuntu，目前为 ${ID}。";; esac
  command -v systemctl >/dev/null || die '需要 systemd 环境。'
}
ensure_dependencies() {
  local pkgs=()
  command -v curl >/dev/null || pkgs+=(curl)
  command -v openssl >/dev/null || pkgs+=(openssl)
  command -v python3 >/dev/null || pkgs+=(python3)
  command -v ip >/dev/null || pkgs+=(iproute2)
  command -v ss >/dev/null || pkgs+=(iproute2)
  if ((${#pkgs[@]})); then
    info "安装依赖：${pkgs[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates "${pkgs[@]}"
  fi
  if ! command -v qrencode >/dev/null; then
    info '安装 qrencode，用于在 SSH 终端显示节点二维码...'
    if ! (apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode); then
      warn 'qrencode 安装失败，节点仍可使用链接导入；稍后执行 apt install qrencode。'
    fi
  fi
}
valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}
normal_port() { printf '%d' "$((10#$1))"; }
valid_sni() {
  python3 - "$1" <<'PY'
import re,sys
s=sys.argv[1]
if not (1 <= len(s) <= 253 and '.' in s and all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', p) for p in s.split('.'))):
    sys.exit(1)
PY
}
validate_addresses() {
  python3 - "$1" "$2" <<'PY'
import ipaddress,sys
v6=ipaddress.IPv6Address(sys.argv[1]); v4=ipaddress.IPv4Address(sys.argv[2])
assert v6.is_global, 'IPv6 必须是公网地址'
assert not (v4.is_loopback or v4.is_unspecified or v4.is_multicast), 'IPv4 地址不可用'
PY
  ip -6 -o addr show | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$1" || die "本机网卡未配置 IPv6：$1"
  ip -4 -o addr show | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$2" || die "本机网卡未配置 IPv4：$2（NAT VPS 应填本机内网地址）"
}
auto_ipv6() {
  ip -6 -o addr show scope global | python3 -c '
import sys,ipaddress
for line in sys.stdin:
    parts=line.split()
    if any(x in parts for x in ("temporary","deprecated","tentative","dadfailed")): continue
    try:
        address=ipaddress.ip_interface(parts[parts.index("inet6")+1]).ip
        if address.is_global:
            print(address); break
    except (ValueError,IndexError): pass
'
}
auto_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -n 1
}
port_occupied() { [[ -n "$(ss -H -ltn "sport = :$1")" ]]; }
public_ipv4() { curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org; }
ensure_xray() {
  if ! command -v xray >/dev/null; then
    info '尚未找到 Xray，调用 XTLS 官方 Xray-install 安装核心。'
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh -o "$tmp"; then
      rm -f "$tmp"; die '下载官方安装脚本失败。'
    fi
    if ! bash "$tmp" install --without-geodata; then
      rm -f "$tmp"; die '官方 Xray 安装失败。'
    fi
    rm -f "$tmp"
  fi
  command -v xray >/dev/null || die '未找到 xray 可执行文件。'
}
keys() {
  local output parsed
  local -a pair=()
  UUID="$(xray uuid | tr -d '\r\n')" || die 'Xray UUID 命令执行失败。'
  [[ "$UUID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || die 'Xray 返回的 UUID 格式无效。'
  output="$(xray x25519)" || die 'Xray REALITY 密钥生成命令执行失败。'
  # Xray versions use Private key / Public key, PrivateKey / Password,
  # or PrivateKey / Password (PublicKey). Parse labels, not line positions.
  if ! parsed="$(printf '%s\n' "$output" | python3 -c '
import base64, re, sys
values = {}
for line in sys.stdin:
    match = re.match(r"^\s*([^:]+):\s*(\S+)\s*$", line)
    if not match:
        continue
    label = re.sub(r"[^a-z]", "", match.group(1).lower())
    if label.startswith("privatekey"):
        values["private"] = match.group(2)
    elif label.startswith("password") or label.startswith("publickey"):
        values["public"] = match.group(2)
for name in ("private", "public"):
    key = values.get(name, "")
    try:
        raw = base64.b64decode(key.replace("-", "+").replace("_", "/") + "=" * (-len(key) % 4), validate=True)
    except (ValueError, base64.binascii.Error):
        sys.exit("invalid REALITY key " + name)
    if len(raw) != 32:
        sys.exit("invalid REALITY key length " + name)
print(values["private"])
print(values["public"])
')"; then
    die '无法识别 Xray REALITY 密钥输出格式。请检查 xray x25519 的字段名称（不要公开私钥）。'
  fi
  mapfile -t pair <<< "$parsed"
  ((${#pair[@]} == 2)) || die 'REALITY 密钥字段数量错误。'
  PRIVATE="${pair[0]}"
  PUBLIC="${pair[1]}"
  SHORT="$(openssl rand -hex 8)" || die '生成 Short ID 失败。'
  [[ "$SHORT" =~ ^[[:xdigit:]]{16}$ ]] || die '生成的 Short ID 格式错误。'
}

# The public REALITY key is embedded in the previously generated client link.
client_public() {
  python3 - "$CLIENT" <<'PY'
from urllib.parse import urlsplit,parse_qs
import sys
for line in open(sys.argv[1],encoding='utf-8'):
    if line.startswith('vless://'):
        p=parse_qs(urlsplit(line.strip()).query).get('pbk',[])
        if p: print(p[0]); break
else: sys.exit('client.txt 缺少 PBK，无法安全重建客户端链接')
PY
}
write_config() {
  # $1 output, following parameters are IPv6, IPv4, port, UUID, private, short, SNI.
  python3 - "$@" <<'PY'
import json,sys
out,v6,v4,port,uid,private,short,sni=sys.argv[1:]
obj={
  'log':{'loglevel':'warning'},
  'dns':{'servers':['1.1.1.1','8.8.8.8'],'queryStrategy':'UseIPv4'},
  'inbounds':[{'tag':'v6-reality-in','listen':v6,'port':int(port),'protocol':'vless',
    'settings':{'users':[{'id':uid,'flow':'xtls-rprx-vision'}],'decryption':'none'},
    'streamSettings':{'network':'tcp','security':'reality','realitySettings':{
      'show':False,'target':sni+':443','xver':0,'serverNames':[sni],
      'privateKey':private,'shortIds':[short],
      'limitFallbackUpload':{'afterBytes':0,'bytesPerSec':16384,'burstBytesPerSec':16384},
      'limitFallbackDownload':{'afterBytes':0,'bytesPerSec':16384,'burstBytesPerSec':16384}
    }}}],
  'outbounds':[{'tag':'ipv4-direct','protocol':'freedom','sendThrough':v4,
    'settings':{'domainStrategy':'AsIs'},
    'streamSettings':{'sockopt':{'domainStrategy':'ForceIPv4'}}}],
  'routing':{'domainStrategy':'AsIs','rules':[
    {'type':'field','inboundTag':['v6-reality-in'],'outboundTag':'ipv4-direct'}]}
}
with open(out,'w',encoding='utf-8') as f: json.dump(obj,f,indent=2,ensure_ascii=False);f.write('\n')
PY
}
# $1 config $2 public key $3 output file
write_client() {
  local observed='未检测'; observed="$(public_ipv4 2>/dev/null || true)"; observed=${observed:-'未检测'}
  python3 - "$1" "$2" "$3" "$observed" <<'PY'
import json,sys,urllib.parse
cfg,pub,out,public4=sys.argv[1:]
c=json.load(open(cfg,encoding='utf-8'))
i=c['inbounds'][0]; r=i['streamSettings']['realitySettings']; u=i['settings']['users'][0]['id']
v6,port,sni=i['listen'],str(i['port']),r['serverNames'][0]
params=urllib.parse.urlencode(dict(encryption='none',security='reality',sni=sni,fp='chrome',pbk=pub,
                                  sid=r['shortIds'][0],type='tcp',flow='xtls-rprx-vision'))
link=f'vless://{u}@[{v6}]:{port}?{params}#IPv6-in-IPv4-out'
with open(out,'w',encoding='utf-8') as f:
    f.write('VLESS + REALITY + Vision | IPv6 入站 / IPv4 出站\n')
    f.write(f'IPv6 入站: [{v6}]:{port}\n')
    f.write(f'本机 IPv4 出站: {c["outbounds"][0]["sendThrough"]}\n')
    f.write(f'外网 IPv4 检测: {public4}\n')
    f.write(f'SNI: {sni}\n')
    f.write('VLESS 链接:\n'+link+'\n')
PY
}
show_qr() {
  [[ -r "$CLIENT" ]] || die '没有找到节点文件，请先安装。'
  local link
  link="$(grep -m1 '^vless://' "$CLIENT" || true)"
  [[ -n "$link" ]] || die '节点文件不含 VLESS 链接。'
  printf '\n'
  if command -v qrencode >/dev/null; then
    info '手机可直接使用 Shadowrocket 等客户端扫描下方二维码：'
    printf '%s' "$link" | qrencode -t UTF8 -m 1 || warn '终端二维码输出失败，请复制下面的链接。'
  else
    warn '尚未安装 qrencode，执行 apt install -y qrencode 即可显示二维码。'
  fi
  printf '\n'
}
show_info() {
  [[ -f "$CLIENT" ]] || die '尚未安装节点。'
  cat "$CLIENT"
  show_qr
}
read_config() {
  [[ -f "$CONF" ]] || die '找不到服务端配置，请先安装。'
  mapfile -t C < <(python3 - "$CONF" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
i=c['inbounds'][0];r=i['streamSettings']['realitySettings'];u=i['settings']['users'][0]
for v in (i['listen'],c['outbounds'][0]['sendThrough'],i['port'],u['id'],r['privateKey'],r['shortIds'][0],r['serverNames'][0]): print(v)
PY
)
  ((${#C[@]} == 7)) || die '配置格式不完整。'
}
check_config() { xray run -test -config "$1" >/dev/null; }
check_installed() { exists || die '尚未完整安装；请先运行 install。'; }
create_user() {
  [[ "$NAME" == 'xray-v6v4' ]] || die '内部服务名称异常，拒绝创建系统账户。'
  if ! getent group "$NAME" >/dev/null 2>&1; then
    groupadd --system "$NAME" || die "创建系统组 $NAME 失败，安装中止。"
  fi
  if ! id "$NAME" >/dev/null 2>&1; then
    useradd --system --no-create-home --gid "$NAME" --shell /usr/sbin/nologin "$NAME" || die "创建服务账户 $NAME 失败，安装中止。"
  fi
  getent group "$NAME" >/dev/null 2>&1 || die "系统组 $NAME 不存在。"
  id "$NAME" >/dev/null 2>&1 || die "服务账户 $NAME 不存在。"
}
unit_create() {
  local bin
  bin=$(command -v xray)
  cat > "$UNIT" <<EOF
[Unit]
Description=Xray VLESS REALITY Vision (IPv6 in, IPv4 out)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NAME
Group=$NAME
ExecStart=$bin run -config $CONF
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
}
firewall_hint() {
  local port=$1 ipv6=$2
  warn "请在服务商安全组/防火墙开放 IPv6 TCP ${port}；无需开放 TCP 80。"
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    warn "检测到 UFW 已启用；确认 SSH 已放行后，可执行：ufw allow in to $ipv6 port $port proto tcp"
  fi
  warn '脚本不会自动更改 UFW，避免误断 SSH。'
}
backup_now() {
  [[ -f "$CONF" && -f "$CLIENT" ]] || die '没有可备份的节点。'
  local outfile
  outfile="$(mktemp "/root/${NAME}-backup-$(date +%Y%m%d-%H%M%S)-XXXXXX.tar.gz")"
  if ! tar -C /etc -czf "$outfile" "$NAME/config.json" "$NAME/client.txt"; then
    rm -f "$outfile"; die '备份失败。'
  fi
  chmod 600 "$outfile"
  info "已备份到：${outfile}（含 REALITY 私钥，禁止公开上传）"
}
do_install() {
  if [[ -e "$UNIT" || -e "$CONF" || -e "$CLIENT" ]]; then
    warn '检测到已有独立节点，拒绝覆盖；可进入菜单修改或查看。'
    [[ -f "$CLIENT" ]] && show_info
    return 0
  fi
  need_system
  ensure_dependencies
  valid_port "$PORT" || die '端口必须在 1–65535 范围内。'
  PORT=$(normal_port "$PORT")
  valid_sni "$SNI" || die 'SNI 必须是正常的主机域名。'
  [[ -n "$IPV6" ]] || IPV6=$(auto_ipv6)
  [[ -n "$IPV4" ]] || IPV4=$(auto_ipv4)
  [[ -n "$IPV6" && -n "$IPV4" ]] || die 'IPv6 或本机 IPv4 未检测到。请用 --ipv6 / --ipv4 指定。'
  validate_addresses "$IPV6" "$IPV4"
  port_occupied "$PORT" && die "端口 $PORT 已被占用，请改用 --port 指定其它端口。"
  local observed
  observed=$(public_ipv4) || die 'IPv4 网络出口验证失败，服务器必须能够通过 IPv4 访问互联网。'
  info "IPv6 入站：[$IPV6]:$PORT"
  info "IPv4 出站：$IPV4 → 公网 $observed"
  ensure_xray
  keys
  create_user
  mkdir -p "$DIR" || die '无法创建节点配置目录。'
  chown "root:$NAME" "$DIR" || die '节点目录属组设置失败。'
  chmod 750 "$DIR" || die '节点目录权限设置失败。' 
  local stage
  stage=$(mktemp -d "$DIR/.stage.XXXXXXXX")
  trap "rm -rf -- '$stage'" EXIT
  write_config "$stage/config.json" "$IPV6" "$IPV4" "$PORT" "$UUID" "$PRIVATE" "$SHORT" "$SNI"
  check_config "$stage/config.json" || die 'Xray-core 不接受当前配置，请检查版本和 SNI。'
  write_client "$stage/config.json" "$PUBLIC" "$stage/client.txt"
  install -o root -g "$NAME" -m 640 "$stage/config.json" "$CONF" || die '写入 Xray 服务配置失败。'
  install -o root -g root -m 600 "$stage/client.txt" "$CLIENT" || die '写入客户端配置失败。' 
  unit_create || die '写入 systemd 服务文件失败。'
  systemctl daemon-reload || die 'systemd 重新加载失败。'
  if ! systemctl enable --now "$SERVICE" || ! systemctl is-active --quiet "$SERVICE"; then
    journalctl -u "$SERVICE" --no-pager -n 30 >&2 || true
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT" "$CONF" "$CLIENT"
    systemctl daemon-reload
    die '服务启动失败，已删除本次创建的服务及节点配置；Xray 核心未删除。'
  fi
  rm -rf -- "$stage"
  trap - EXIT
  info '部署成功！下面自动展示节点链接和二维码。'
  show_info
  firewall_hint "$PORT" "$IPV6"
}
# Safe atomic-ish replace with a saved original and restart rollback.
apply_config() {
  local staged_config=$1 staged_public=$2 staged_client dir
  check_installed
  check_config "$staged_config" || die '新配置检查未通过，旧节点保持不变。'
  dir=$(mktemp -d "$DIR/.rollback.XXXXXXXX")
  cp -p "$CONF" "$dir/config.json"
  cp -p "$CLIENT" "$dir/client.txt"
  staged_client="$dir/new-client.txt"
  write_client "$staged_config" "$staged_public" "$staged_client"
  backup_now
  install -o root -g "$NAME" -m 640 "$staged_config" "$CONF"
  install -o root -g root -m 600 "$staged_client" "$CLIENT"
  if ! systemctl restart "$SERVICE" || { sleep 1; ! systemctl is-active --quiet "$SERVICE"; }; then
    warn '新节点启动失败，正在恢复上次配置。'
    cp -p "$dir/config.json" "$CONF"
    cp -p "$dir/client.txt" "$CLIENT"
    systemctl restart "$SERVICE" || warn '回滚后服务仍未正常运行，请查看 journalctl。'
    rm -rf "$dir"
    die '新配置未生效，已尝试回滚。'
  fi
  rm -rf "$dir"
  info '修改已成功生效，客户端配置如下：'
  show_info
}
change_port() {
  check_installed; read_config
  local new="${1:-}" tmp public
  [[ -n "$new" ]] || prompt new "新端口（当前 ${C[2]}）：" "${C[2]}" || die '无法读取输入。'
  valid_port "$new" || die '无效端口。'
  new=$(normal_port "$new")
  if [[ "$new" == "${C[2]}" ]]; then info '端口未变化。'; return 0; fi
  port_occupied "$new" && die "TCP $new 已被占用。"
  public=$(client_public)
  tmp=$(mktemp "$DIR/.newconfig.XXXXXXXX")
  write_config "$tmp" "${C[0]}" "${C[1]}" "$new" "${C[3]}" "${C[4]}" "${C[5]}" "${C[6]}"
  apply_config "$tmp" "$public"
  rm -f "$tmp"
  firewall_hint "$new" "${C[0]}"
}
change_sni() {
  check_installed; read_config
  local new="${1:-}" tmp public
  [[ -n "$new" ]] || prompt new "新 SNI（当前 ${C[6]}）：" "${C[6]}" || die '无法读取输入。'
  valid_sni "$new" || die 'SNI 不是有效域名。'
  if [[ "$new" == "${C[6]}" ]]; then info 'SNI 未变化。'; return 0; fi
  warn '新 SNI 必须可从 VPS 访问且支持 TLS 1.3；可用 xray tls ping 域名 检查。'
  public=$(client_public)
  tmp=$(mktemp "$DIR/.newconfig.XXXXXXXX")
  write_config "$tmp" "${C[0]}" "${C[1]}" "${C[2]}" "${C[3]}" "${C[4]}" "${C[5]}" "$new"
  apply_config "$tmp" "$public"
  rm -f "$tmp"
}
rotate_keys() {
  check_installed; read_config
  confirm '密钥与 UUID 都将更换，原客户端连接会失效，确定继续吗？' || { info '已取消。'; return 0; }
  keys
  local tmp
  tmp=$(mktemp "$DIR/.newconfig.XXXXXXXX")
  write_config "$tmp" "${C[0]}" "${C[1]}" "${C[2]}" "$UUID" "$PRIVATE" "$SHORT" "${C[6]}"
  apply_config "$tmp" "$PUBLIC"
  rm -f "$tmp"
}
do_status() {
  command -v systemctl >/dev/null || die 'systemctl 不可用。'
  systemctl --no-pager --full status "$SERVICE" || true
  if [[ -f "$CONF" ]]; then
    read_config
    info "监听：IPv6 [${C[0]}]:${C[2]}；指定出站本机 IPv4 ${C[1]}；SNI ${C[6]}"
    ss -H -ltn "sport = :${C[2]}" || true
    if command -v curl >/dev/null; then
      local observed
      observed=$(public_ipv4 2>/dev/null || true)
      [[ -n "$observed" ]] && info "本机 IPv4 公网出口：$observed" || warn '当前未能检测本机 IPv4 公网出口。'
    fi
    warn '这是服务端检测；仍需在客户端通过代理访问 api.ipify.org 验证最终 IPv4 出站。'
  fi
}
do_restart() { check_installed; systemctl restart "$SERVICE"; systemctl is-active --quiet "$SERVICE" || die '服务未运行，请查看 journalctl。'; info '节点服务已重启。'; }
# Restore only on an already installed service; archive paths are strictly validated.
do_restore() {
  check_installed
  local archive="${1:-}" extracted newport
  if [[ -z "$archive" ]]; then
    archive=$(find /root -maxdepth 1 -type f -name "${NAME}-backup-*.tar.gz" -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
    [[ -n "$archive" ]] || die '未找到备份，请传入 restore --file 文件。'
    info "找到最近备份：$archive"
  fi
  [[ -r "$archive" ]] || die "无法读取备份：$archive"
  confirm "将用备份覆盖当前 $NAME 节点（自动保存旧配置），确定恢复吗？" || { info '已取消。'; return 0; }
  extracted=$(mktemp -d "$DIR/.restore.XXXXXXXX")
  # Avoid tar path traversal, links, and unpacking arbitrary untrusted content as root.
  python3 - "$archive" "$extracted" <<'PY'
import os,sys,tarfile
archive,dest=sys.argv[1:]
allowed={'xray-v6v4/config.json':'config.json','xray-v6v4/client.txt':'client.txt'}
with tarfile.open(archive,'r:gz') as tf:
    found=set()
    for member in tf.getmembers():
        if member.name in ('xray-v6v4','xray-v6v4/') and member.isdir(): continue
        if member.name not in allowed or not member.isfile() or member.size>1_000_000:
            sys.exit('不安全或不兼容的备份文件')
        if member.name in found: sys.exit('备份文件有重复路径')
        found.add(member.name)
        with tf.extractfile(member) as inp, open(os.path.join(dest,allowed[member.name]),'wb') as out:
            out.write(inp.read())
    if found!=set(allowed): sys.exit('备份不包含预期的两个文件')
PY
  check_config "$extracted/config.json" || die '备份配置无法通过 Xray 校验。'
  # Ensure archived client and config agree (avoid applying mismatched credentials).
  python3 - "$extracted/config.json" "$extracted/client.txt" <<'PY'
import json,sys,urllib.parse
c=json.load(open(sys.argv[1]));s=open(sys.argv[2]).read().splitlines(); links=[x for x in s if x.startswith('vless://')]
assert len(links)==1,'备份节点链接不合法'
p=urllib.parse.urlsplit(links[0]);q=urllib.parse.parse_qs(p.query)
i=c['inbounds'][0];r=i['streamSettings']['realitySettings'];u=i['settings']['users'][0]
assert p.username==u['id'] and p.hostname==i['listen'] and p.port==i['port'],'备份客户端与服务端地址/UUID不一致'
assert q.get('sni')==r['serverNames'] and q.get('sid')==r['shortIds'],'备份客户端与服务端 SNI/ShortID 不一致'
PY
  read_config
  newport=$(python3 - "$extracted/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]));print(c['inbounds'][0]['port'])
PY
)
  [[ "$newport" == "${C[2]}" ]] || { port_occupied "$newport" && die "备份端口 $newport 已被占用。"; }
  # Validate archived interface addresses still exist on this machine.
  python3 - "$extracted/config.json" <<'PY' > "$extracted/addresses"
import json,sys
c=json.load(open(sys.argv[1]));print(c['inbounds'][0]['listen']);print(c['outbounds'][0]['sendThrough'])
PY
  mapfile -t ADDRS < "$extracted/addresses"
  validate_addresses "${ADDRS[0]}" "${ADDRS[1]}"
  backup_now
  local olddir
  olddir=$(mktemp -d "$DIR/.before-restore.XXXXXXXX")
  cp -p "$CONF" "$olddir/config.json"; cp -p "$CLIENT" "$olddir/client.txt"
  install -o root -g "$NAME" -m 640 "$extracted/config.json" "$CONF"
  install -o root -g root -m 600 "$extracted/client.txt" "$CLIENT"
  if ! systemctl restart "$SERVICE" || { sleep 1; ! systemctl is-active --quiet "$SERVICE"; }; then
    warn '备份恢复后服务未启动，执行回滚。'
    cp -p "$olddir/config.json" "$CONF"; cp -p "$olddir/client.txt" "$CLIENT"
    systemctl restart "$SERVICE" || warn '回滚后的服务重启失败，请手动检查。'
    rm -rf "$extracted" "$olddir"
    die '恢复失败，已尝试回滚。'
  fi
  rm -rf "$extracted" "$olddir"
  info '恢复成功。'; show_info
  firewall_hint "$newport" "${ADDRS[0]}"
}
do_uninstall() {
  [[ -f "$UNIT" || -d "$DIR" ]] || die '未发现本工具安装的节点。'
  confirm '将移除独立节点及配置（会自动备份），确定卸载吗？' || { info '已取消。'; return 0; }
  if [[ -f "$CONF" && -f "$CLIENT" ]]; then backup_now; fi
  if [[ -f "$UNIT" ]]; then
    systemctl disable --now "$SERVICE" || die '停止服务失败，卸载已中止。'
    if systemctl is-active --quiet "$SERVICE"; then die '服务仍在运行，拒绝继续删除。'; fi
    rm -f "$UNIT"
    systemctl daemon-reload
  fi
  rm -rf -- "$DIR"
  info '已移除本项目独立服务与配置，未删除共享 Xray 核心、UFW 规则或其它节点。'
}
interactive_install() {
  local proposed
  prompt proposed "监听 TCP 端口 [$PORT]：" "$PORT" || die '无法读取端口。'; PORT=$proposed
  prompt proposed "REALITY SNI [$SNI]：" "$SNI" || die '无法读取 SNI。'; SNI=$proposed
  info '公网 IPv6 和本机 IPv4 默认为自动检测，留空表示自动。'
  prompt proposed '指定公网 IPv6（回车自动检测）：' "$IPV6" || die '无法读取 IPv6。'; IPV6=$proposed
  prompt proposed '指定本机 IPv4（回车自动检测）：' "$IPV4" || die '无法读取 IPv4。'; IPV4=$proposed
  do_install
}
menu() {
  need_root
  local option sub
  while true; do
    printf '\n\033[36m======= Xray IPv6 入站 → IPv4 出站 V%s =======\033[0m\n' "$SCRIPT_VERSION"
    cat <<'EOF'
 1) 一键安装节点（安装成功自动显示二维码）
 2) 查看节点信息及二维码
 3) 修改监听端口
 4) 修改 REALITY SNI
 5) 重置 UUID / REALITY 密钥
 6) 查看运行状态 / IPv4 出口
 7) 重启节点服务
 8) 备份或恢复配置
 9) 卸载节点（自动备份）
 0) 退出
EOF
    prompt option '请选择 [0-9]：' '' || { warn '无法读取交互输入。'; return 1; }
    case "$option" in
      1) (interactive_install) || warn '安装未完成。' ;;
      2) (show_info) || warn '读取失败。' ;;
      3) (change_port) || warn '修改端口未完成。' ;;
      4) (change_sni) || warn '修改 SNI 未完成。' ;;
      5) (rotate_keys) || warn '更新密钥未完成。' ;;
      6) (do_status) || warn '状态查询失败。' ;;
      7) (do_restart) || warn '重启失败。' ;;
      8)
        printf '  1) 创建备份\n  2) 恢复备份（需已有安装）\n'
        prompt sub '请选择 [1-2]：' '' || continue
        case "$sub" in
          1) (backup_now) || warn '备份失败。' ;;
          2) (local_file=''; prompt local_file '备份 tar.gz 文件路径（留空选最近的）：' '' && do_restore "$local_file") || warn '恢复未完成。' ;;
          *) warn '无效选项。' ;;
        esac ;;
      9) (do_uninstall) || warn '卸载未完成。' ;;
      0) return 0 ;;
      *) warn '请输入 0–9。' ;;
    esac
    pause_menu
  done
}

main() {
  [[ $# -eq 0 ]] && {
    need_root
    if [[ -t 0 || -t 1 ]]; then menu; else do_install; fi
    return
  }
  if [[ "$1" != --* && "$1" != -h ]]; then ACTION=$1; shift; else ACTION=install; fi
  while (($#)); do
    case "$1" in
      --ipv6|--ipv4|--port|--sni|--file)
        (($# >= 2)) || die "缺少参数 $1 的值。"
        case "$1" in
          --ipv6) IPV6=$2;; --ipv4) IPV4=$2;; --port) PORT=$2; PORT_SET=1;;
          --sni) SNI=$2; SNI_SET=1;; --file) RESTORE_FILE=$2;;
        esac; shift 2 ;;
      --yes) YES=1; shift;;
      -h|--help) help_msg; return 0;;
      *) die "未知参数：$1";;
    esac
  done
  [[ "$ACTION" == help ]] && { help_msg; return 0; }
  need_root
  case "$ACTION" in
    menu) menu;;
    install) do_install;;
    show|qr) show_info;;
    status) do_status;;
    port) if ((PORT_SET)); then change_port "$PORT"; else change_port; fi;;
    sni) if ((SNI_SET)); then change_sni "$SNI"; else change_sni; fi;;
    rotate) rotate_keys;;
    restart) do_restart;;
    backup) backup_now;;
    restore) do_restore "$RESTORE_FILE";;
    uninstall) do_uninstall;;
    *) die "未知命令：$ACTION";;
  esac
}
main "$@"