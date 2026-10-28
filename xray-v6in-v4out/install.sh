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
SCRIPT_VERSION=2.1.2

info() { printf '\033[32m[信息]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[提醒]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }
exists() { [[ -f "$CONF" && -f "$CLIENT" && -f "$UNIT" ]]; }
need_root() { (( EUID == 0 )) || die '请先 sudo -i 切换 root。'; }
help_msg() {
  cat <<'EOF'
Xray IPv6 入站 / IPv4 出站 V2 交互管理脚本
用法：bash install.sh [menu|install|show|qr|status|port|sni|rotate|restart|backup|restore|uninstall|diagnose|selftest|dns|log] [选项]
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
import json,sys,os
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
# Preserve runtime DNS/log settings when changing SNI, port or credentials.
# Existing config is user-controlled and no external path is accepted.
if os.path.isfile('/etc/xray-v6v4/config.json'):
    with open('/etc/xray-v6v4/config.json',encoding='utf-8') as prev_file:
        prev=json.load(prev_file)
    for field in ('dns','log'):
        if field in prev: obj[field]=prev[field]
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
# Xray defaults to format=auto and identifies configs by extension.
# Our atomic staging files (.change.XXXX etc.) intentionally have no .json suffix.
# Explicit JSON format is mandatory for both DNS/log changes and restores.
# Xray v26.10.21 validates the actual file extension in its external loader
# even when -format json is specified. All staged configs must end in .json.
# Preserve Xray's real error output on validation failure for troubleshooting.
check_config() {
  local output
  if output="$(xray run -test -format json -config "$1" 2>&1)"; then
    return 0
  fi
  warn 'Xray 配置校验的原始错误信息：'
  printf '%s\n' "$output" >&2
  return 1
}
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
  reality_probe "$SNI" || warn 'REALITY 目标检测失败，安装后必须进行完整代理自检'
  keys
  create_user
  mkdir -p "$DIR" || die '无法创建节点配置目录。'
  chown "root:$NAME" "$DIR" || die '节点目录属组设置失败。'
  chmod 750 "$DIR" || die '节点目录权限设置失败。' 
  local stage
  stage=$(mktemp -d "$DIR/.stage.XXXXXXXX")
  trap "rm -rf -- '$stage'" EXIT
  write_config "$stage/config.json" "$IPV6" "$IPV4" "$PORT" "$UUID" "$PRIVATE" "$SHORT" "$SNI" || die '生成服务端配置失败'
  check_config "$stage/config.json" || die 'Xray-core 不接受当前配置，请检查版本和 SNI。'
  write_client "$stage/config.json" "$PUBLIC" "$stage/client.txt" || die '生成客户端链接失败'
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
  info '服务已启动，现在进行完整代理端到端自检...'
  if self_test; then info '本机端到端检测通过；请另外检查外部 IPv6 可达性'; else warn '节点已启动但代理端到端检测失败，请使用菜单 10 诊断'; fi
  info '下面显示节点链接和二维码（请勿公开分享）'
  show_info
  firewall_hint "$PORT" "$IPV6"
}
# Safe atomic-ish replace with a saved original and restart rollback.
apply_config() {
  local staged_config=$1 staged_public=$2 staged_client dir
  check_installed
  check_config "$staged_config" || die '新配置检查未通过，旧节点保持不变。'
  dir=$(mktemp -d "$DIR/.rollback.XXXXXXXX")
  cp -p "$CONF" "$dir/config.json" || die '备份旧配置失败，拒绝修改'
  cp -p "$CLIENT" "$dir/client.txt" || die '备份客户端配置失败，拒绝修改'
  staged_client="$dir/new-client.txt"
  write_client "$staged_config" "$staged_public" "$staged_client" || die '生成新的客户端链接失败'
  backup_now || die '修改前备份失败，拒绝修改'
  install -o root -g "$NAME" -m 640 "$staged_config" "$CONF" || die '更新服务端配置失败'
  if ! install -o root -g root -m 600 "$staged_client" "$CLIENT"; then
    cp -p "$dir/config.json" "$CONF" || warn '旧配置恢复失败'
    cp -p "$dir/client.txt" "$CLIENT" || warn '旧客户端配置恢复失败'
    die '客户端文件写入失败，已尝试恢复原配置'
  fi
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
  tmp=$(mktemp "$DIR/.newconfig.XXXXXXXX.json")
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
  reality_probe "$new" || warn '目标预检查未通过，仍允许修改，但建议执行完整代理自检'
  public=$(client_public)
  tmp=$(mktemp "$DIR/.newconfig.XXXXXXXX.json")
  write_config "$tmp" "${C[0]}" "${C[1]}" "${C[2]}" "${C[3]}" "${C[4]}" "${C[5]}" "$new"
  apply_config "$tmp" "$public"
  rm -f "$tmp"
}
rotate_keys() {
  check_installed; read_config
  confirm '密钥与 UUID 都将更换，原客户端连接会失效，确定继续吗？' || { info '已取消。'; return 0; }
  keys
  local tmp
  tmp=$(mktemp "$DIR/.newconfig.XXXXXXXX.json")
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
  backup_now || die '恢复前备份失败，拒绝覆盖'
  local olddir
  olddir=$(mktemp -d "$DIR/.before-restore.XXXXXXXX")
  cp -p "$CONF" "$olddir/config.json"; cp -p "$CLIENT" "$olddir/client.txt"
  install -o root -g "$NAME" -m 640 "$extracted/config.json" "$CONF" || die '恢复服务端配置写入失败'
  if ! install -o root -g root -m 600 "$extracted/client.txt" "$CLIENT"; then
    cp -p "$olddir/config.json" "$CONF" || warn '恢复旧服务端配置失败'
    cp -p "$olddir/client.txt" "$CLIENT" || warn '恢复旧客户端配置失败'
    die '恢复客户端链接文件失败，已尝试回滚'
  fi
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
  prompt proposed '指定公网 IPv6（回车自动选择）：' "$IPV6" || die '无法读取 IPv6。'; IPV6=$proposed
  [[ -n "$IPV6" ]] || show_ipv6_choices
  prompt proposed '指定本机 IPv4（回车自动检测）：' "$IPV4" || die '无法读取 IPv4。'; IPV4=$proposed
  do_install
}
# --- V2.1: non-destructive diagnostics, REALITY and DNS probes ---
net_probe() {
  local v4=${1:-} v6=${2:-} name=${3:-api.ipify.org}
  info '检查 IPv4 出站和路由：'
  ip -4 route get 1.1.1.1 || warn '无 IPv4 默认可用路由'
  if [[ -n "$v4" ]]; then
    local observed=''
    observed=$(curl -4fsS --interface "$v4" --max-time 12 https://api.ipify.org 2>/dev/null || true)
    [[ "$observed" =~ ^[0-9.]+$ ]] && info "绑定 IPv4 源地址的出口：$observed" || warn "绑定 IPv4 $v4 出站失败"
  fi
  info '检查 IPv6 默认路由和地址：'
  ip -6 route show default || true
  ip -6 -o addr show scope global || true
  [[ -z "$v6" ]] || ip -6 route get 2606:4700:4700::1111 from "$v6" 2>/dev/null || warn '所选 IPv6 的出站路由检查失败'
  if getent ahostsv4 "$name" >/dev/null 2>&1; then info "域名 $name 的 IPv4 DNS 查询成功"; else warn "域名 $name 的 IPv4 DNS 查询失败"; fi
  if curl -4fsS --max-time 9 -H 'accept: application/dns-json' -o /dev/null 'https://1.1.1.1/dns-query?name=example.com&type=A' 2>/dev/null; then
    info 'DoH (1.1.1.1) HTTPS 连接可达（不代表 DNS 查询结果已验证）'
  else
    warn 'DoH (1.1.1.1) 不可达，若选择 DoH 模式可能无法解析'
  fi
}
reality_probe() {
  local target=$1 result
  info "检测 REALITY 目标：${target}（IPv4 TLS 1.3、ALPN）"
  if ! command -v timeout >/dev/null || ! command -v openssl >/dev/null; then
    warn '缺少 timeout 或 openssl，跳过目标探测'; return 2
  fi
  result=$(timeout 12 openssl s_client -4 -connect "${target}:443" -servername "$target" -tls1_3 -alpn 'h2,http/1.1' -brief < /dev/null 2>&1) || {
    warn "目标 $target 的 TLS 连接失败（只做告警，不阻止安装）"; return 1;
  }
  if grep -Eqi 'Protocol version: TLSv1\.3|Protocol *: TLSv1\.3' <<< "$result"; then
    info 'TLS 1.3 握手成功'
  else
    warn '没有检测到 TLS 1.3，建议换目标'; return 1
  fi
  if grep -Eqi 'ALPN protocol: h2' <<< "$result"; then info 'ALPN h2 已协商'; else warn '未协商 h2，需通过完整代理自检确认可用'; fi
  return 0
}
show_ipv6_choices() {
  local -a choices=()
  local candidate ans n=0
  mapfile -t choices < <(ip -6 -o addr show scope global | python3 -c '
import ipaddress,sys
seen=set()
for line in sys.stdin:
    cols=line.split()
    if any(x in cols for x in ("temporary", "tentative", "dadfailed", "deprecated")): continue
    try:
        addr=str(ipaddress.ip_interface(cols[cols.index("inet6")+1]).ip)
        if ipaddress.IPv6Address(addr).is_global and addr not in seen:
            print(addr);seen.add(addr)
    except (ValueError,IndexError):pass
')
  (( ${#choices[@]} > 0 )) || die '没有可选的公网 IPv6'
  if (( ${#choices[@]} == 1 )); then IPV6=${choices[0]}; info "自动选择 IPv6：$IPV6"; return; fi
  info '检测到多个公网 IPv6，请选入站地址（需外部可达）：'
  for candidate in "${choices[@]}"; do n=$((n+1)); printf ' %s) %s\n' "$n" "$candidate"; done
  prompt ans "选择 [1-${#choices[@]}，回车默认 1]：" '1' || die '无法读取 IPv6 选项'
  [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#choices[@]} )) || die '无效 IPv6 选项'
  IPV6=${choices[$((ans-1))]}
}
self_test() (
  set -Eeuo pipefail
  check_installed
  local tmp pid='' socks port expected result attempts=0
  tmp=$(mktemp -d /tmp/xray-v6v4-test.XXXXXXXX) || die '无法创建临时测试目录'
  chmod 700 "$tmp"
  trap '[[ -z "${pid:-}" ]] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }; rm -rf -- "$tmp"' EXIT
  port=$(python3 - <<'PY'
import socket
s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()
PY
)
  python3 - "$CONF" "$CLIENT" "$tmp/client.json" "$port" <<'PY'
import json,sys,urllib.parse
conf,client,out,port=sys.argv[1:]
c=json.load(open(conf,encoding='utf-8'))
links=[x.strip() for x in open(client,encoding='utf-8') if x.startswith('vless://')]
assert len(links)==1,'节点链接数量异常'
p=urllib.parse.urlsplit(links[0]);q=urllib.parse.parse_qs(p.query)
i=c['inbounds'][0];r=i['streamSettings']['realitySettings'];u=i['settings']['users'][0]
assert p.username==u['id'] and p.hostname==i['listen'] and p.port==i['port'],'客户端与服务端参数不一致'
assert q.get('sni')==r['serverNames'] and q.get('sid')==r['shortIds'],'SNI/Short ID 不一致'
key=q.get('pbk',[''])[0]
assert key,'节点缺少 REALITY 公钥'
obj={'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':int(port),'protocol':'socks','settings':{'auth':'noauth','udp':False}}],
'outbounds':[{'tag':'proxy','protocol':'vless','settings':{'address':i['listen'],'port':i['port'],'id':u['id'],'encryption':'none','flow':'xtls-rprx-vision'},'streamSettings':{'network':'tcp','security':'reality','realitySettings':{'fingerprint':'chrome','serverName':r['serverNames'][0],'password':key,'shortId':r['shortIds'][0]}}}]}
with open(out,'w') as f:json.dump(obj,f)
PY
  xray run -test -config "$tmp/client.json" > "$tmp/check.log" 2>&1 || { warn '临时客户端配置校验失败'; tail -n 12 "$tmp/check.log"; exit 1; }
  xray run -config "$tmp/client.json" > "$tmp/xray.log" 2>&1 & pid=$!
  while (( attempts < 20 )); do
    kill -0 "$pid" 2>/dev/null || { warn '临时客户端进程退出'; tail -n 12 "$tmp/xray.log"; exit 1; }
    ss -H -ltn "sport = :$port" | grep -q '127.0.0.1' && break
    sleep 0.2; attempts=$((attempts+1))
  done
  if (( attempts == 20 )); then warn '临时 SOCKS5 端口没有启动'; tail -n 12 "$tmp/xray.log"; exit 1; fi
  info '通过临时 SOCKS5 → REALITY → Freedom 发起完整 HTTPS 请求...'
  expected=$(curl -4fsS --max-time 12 --noproxy '*' https://api.ipify.org 2>/dev/null || true)
  result=$(curl -fsS --max-time 18 --proxy "socks5h://127.0.0.1:$port" --noproxy '' https://api.ipify.org 2> "$tmp/curl.log") || {
    warn '代理端到端请求失败；可能是 REALITY 握手、DNS、IPv4 绑定或目标访问问题'
    sed -n '1,8p' "$tmp/curl.log" | sed -E 's/[0-9a-fA-F:]{20,}/[REDACTED]/g'
    tail -n 12 "$tmp/xray.log" | sed -E 's/[0-9a-fA-F:]{20,}/[REDACTED]/g'
    exit 1
  }
  [[ "$result" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn '代理返回结果不是 IPv4 地址'; exit 1; }
  if [[ "$result" != "$expected" ]]; then
    warn "代理出口为 ${result}，但 VPS 直连出口为 ${expected:-未知}，需核实 NAT/路由"; exit 1
  fi
  info "本机端到端代理测试成功；代理公网出口：$result"
  warn '仅证明 VPS 本机经 IPv6 回环/本地路由可连接；不证明手机从公网 IPv6 可以连接'
)
full_diagnose() {
  check_installed
  read_config
  info '========== IPv6→IPv4 一键诊断 =========='
  systemctl is-active --quiet "$SERVICE" && info 'systemd 服务运行正常' || warn 'Xray 服务不在运行'
  ss -6 -H -ltn "sport = :${C[2]}" | grep -q "${C[0]}" && info "IPv6 监听存在：${C[0]}:${C[2]}" || warn '没有发现预期 IPv6 监听'
  net_probe "${C[1]}" "${C[0]}"
  reality_probe "${C[6]}" || true
  if ! self_test; then warn '端到端代理测试失败，请检查日志和手机网络'; fi
  info '外部测试：使用具备 IPv6 的客户端访问 VPS IPv6 TCP 端口；本机测试无法替代公网验证'
  warn '外网全红需检查 VPS 商家防火墙、nftables 和客户端 IPv6 路由；不要清空防火墙'
}
update_config_field() {
  check_installed
  local mode=$1 value=$2 tmp prev
  tmp=$(mktemp "$DIR/.change.XXXXXXXX.json") || die '无法创建配置暂存文件'
  python3 - "$CONF" "$tmp" "$mode" "$value" <<'PY'
import json,sys
src,dst,mode,value=sys.argv[1:]
c=json.load(open(src))
if mode=='dns':
    if value=='udp': c['dns']={'servers':['1.1.1.1','8.8.8.8'],'queryStrategy':'UseIPv4'}
    elif value=='doh':c['dns']={'servers':['https+local://1.1.1.1/dns-query','https+local://8.8.8.8/dns-query'],'queryStrategy':'UseIPv4'}
    else:raise ValueError('unknown DNS mode')
elif mode=='log':
    if value=='info':c['log']={'loglevel':'info','dnsLog':True,'maskAddress':'quarter'}
    elif value=='warning':c['log']={'loglevel':'warning','dnsLog':False}
    else:raise ValueError('unknown log level')
else:raise ValueError('unknown setting')
with open(dst,'w') as f:json.dump(c,f,indent=2);f.write('\n')
PY
  if ! check_config "$tmp"; then rm -f "$tmp"; die '新配置未通过 Xray 检查，保持原配置'; fi
  backup_now || { rm -f "$tmp"; die '备份失败，拒绝修改'; }
  prev=$(mktemp "$DIR/.previous.XXXXXXXX")
  cp -p "$CONF" "$prev" || die '无法保存旧配置'
  install -o root -g "$NAME" -m 640 "$tmp" "$CONF" || die '无法更新服务配置'
  if ! systemctl restart "$SERVICE" || { sleep 1; ! systemctl is-active --quiet "$SERVICE"; }; then
    warn '修改后服务失败，尝试回滚'
    cp -p "$prev" "$CONF"; systemctl restart "$SERVICE" || warn '回滚重启失败'
    rm -f "$tmp" "$prev"; return 1
  fi
  rm -f "$tmp" "$prev"
  info "$mode 已切换为 ${value}，节点凭据和二维码保持不变"
}
choose_dns() {
  local mode
  printf ' 1) UDP DNS（1.1.1.1 / 8.8.8.8）\n 2) DoH（HTTPS+local，端口 443）\n'
  prompt mode '选择 DNS 模式 [1-2]：' '1' || return 1
  case "$mode" in 1) update_config_field dns udp;; 2) update_config_field dns doh;; *) warn '无效选项';return 1;; esac
}
choose_log() {
  local mode
  printf ' 1) 正常日志 warning（推荐）\n 2) 诊断日志 info + dnsLog + 地址脱敏\n'
  prompt mode '选择日志模式 [1-2]：' '1' || return 1
  case "$mode" in 1) update_config_field log warning;; 2) update_config_field log info;; *) warn '无效选项';return 1;; esac
}
# --- End V2.1 module ---

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
10) 一键诊断（包含 REALITY 完整代理自检）
11) 单独执行完整代理自检
12) 切换 DNS（UDP / DoH）
13) 设置诊断日志（info / warning）
 0) 退出
EOF
    prompt option '请选择 [0-13]：' '' || { warn '无法读取交互输入。'; return 1; }
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
      10) (full_diagnose) || warn '诊断部分未完成。' ;;
      11) (self_test) || warn '代理自检未通过。' ;;
      12) (choose_dns) || warn 'DNS 切换失败。' ;;
      13) (choose_log) || warn '日志模式切换失败。' ;;
      0) return 0 ;;
      *) warn '请输入 0–13。' ;;
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
    diagnose) full_diagnose;;
    selftest) self_test;;
    dns) choose_dns;;
    log) choose_log;;
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