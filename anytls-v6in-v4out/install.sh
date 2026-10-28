#!/usr/bin/env bash
# Independent sing-box AnyTLS service. No changes to other proxy services/firewall.
set -Eeuo pipefail
umask 077

VERSION=1.1.0
CORE_VERSION=1.14.4
BASE_NAME=anytls-v6v4
CONFIG_ROOT=/etc
BINARY_ROOT=/opt
UNIT_ROOT=/etc/systemd/system
NAME=$BASE_NAME
DIR=$CONFIG_ROOT/$NAME
BIN_DIR=$BINARY_ROOT/$NAME
BIN=$BIN_DIR/sing-box
CONF=$DIR/config.json
UNIT=$UNIT_ROOT/$NAME.service
SERVICE=$NAME.service
PORT=38445
PORT_SET=0
NODE_ID=default
NODE_LABEL=
ALLOW_INSECURE=0
IPV6=
IPV4=
SERVER_NAME=anytls.invalid
CERT=
KEY=
YES=0

info() { printf '[信息] %s\n' "$*"; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }
need_root() { (( EUID == 0 )) || die '请使用 root 执行'; }
installed() { [[ -f "$CONF" && -x "$BIN" && -f "$UNIT" ]]; }
select_node() {
  local id=$1
  [[ "$id" =~ ^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$ ]] || die '节点 ID 须为 1–20 位小写字母/数字/中间连字符'
  NODE_ID=$id
  NAME=$BASE_NAME
  [[ "$id" == default ]] || NAME=$BASE_NAME-$id
  DIR=$CONFIG_ROOT/$NAME
  BIN_DIR=$BINARY_ROOT/$NAME
  BIN=$BIN_DIR/sing-box
  CONF=$DIR/config.json
  UNIT=$UNIT_ROOT/$NAME.service
  SERVICE=$NAME.service
}
suggest_port() {
  python3 - "$CONFIG_ROOT" "$BASE_NAME" <<'PY'
import json,pathlib,sys
ports=[]
for p in pathlib.Path(sys.argv[1]).glob(sys.argv[2]+"*/config.json"):
    try: ports.extend(i["listen_port"] for i in json.loads(p.read_text())["inbounds"])
    except (OSError,ValueError,KeyError,TypeError): pass
print(max([38444]+ports)+1 if max([38444]+ports)<65535 else 38446)
PY
}
list_nodes() {
  python3 - "$CONFIG_ROOT" "$BASE_NAME" <<'PY'
import json,pathlib,re,subprocess,sys
root,base=pathlib.Path(sys.argv[1]),sys.argv[2]
print("ID\t名称\tIPv6:端口\t服务状态")
count=0
for folder in sorted(root.glob(base+"*")):
    identifier="default" if folder.name==base else folder.name.removeprefix(base+"-")
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,18}[a-z0-9])?",identifier): continue
    try:
        c=json.loads((folder/"config.json").read_text());i=c["inbounds"][0]
        if i["type"]!="anytls": continue
        label=(folder/"node-name").read_text().strip() if (folder/"node-name").is_file() else "AnyTLS-"+identifier
        label="".join(ch if ch.isprintable() else " " for ch in label)
        state=subprocess.run(["systemctl","is-active",folder.name+".service"],capture_output=True,text=True).stdout.strip()
        print(f'{identifier}\t{label}\t[{i["listen"]}]:{i["listen_port"]}\t{state or "unknown"}')
        count+=1
    except (OSError,ValueError,KeyError,TypeError): continue
if not count: print("尚未发现已安装节点。")
PY
}
require_install_deps() {
  [[ -d /run/systemd/system ]] || die '需要已启动 systemd 的 Debian/Ubuntu VPS'
  local command_name missing=0
  for command_name in curl openssl python3 ip ss tar gzip sha256sum; do
    command -v "$command_name" >/dev/null 2>&1 || missing=1
  done
  if (( missing )); then
    command -v apt-get >/dev/null 2>&1 || die '缺少依赖且无 apt-get，请使用 Debian/Ubuntu'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl python3 iproute2 tar gzip coreutils
  fi
}
auto_ipv6() {
  ip -6 -j addr show scope global | python3 -c '
import ipaddress,json,sys
for interface in json.load(sys.stdin):
    for a in interface.get("addr_info",[]):
        if a.get("family")!="inet6" or any(a.get(f) for f in ("temporary","tentative","deprecated","dadfailed")):
            continue
        if ipaddress.IPv6Address(a["local"]).is_global:
            print(a["local"]);sys.exit(0)
'
}
auto_ipv4() {
  ip -4 -j route get 1.1.1.1 | python3 -c 'import json,sys;print(json.load(sys.stdin)[0].get("prefsrc",""))'
}
validate_options() {
  python3 - "$IPV6" "$IPV4" "$PORT" "$SERVER_NAME" <<'PY'
import ipaddress,re,subprocess,sys
v6=ipaddress.IPv6Address(sys.argv[1]);v4=ipaddress.IPv4Address(sys.argv[2])
if not v6.is_global or v6.is_multicast: sys.exit("IPv6 必须是公网全局单播地址")
if v4.is_unspecified or v4.is_loopback or v4.is_multicast or v4.is_link_local: sys.exit("本机 IPv4 地址无效")
if not re.fullmatch(r"[0-9]{1,5}",sys.argv[3]) or not 1<=int(sys.argv[3])<=65535: sys.exit("端口范围为 1–65535")
sni=sys.argv[4]
if len(sni)>253 or "." not in sni or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?",s) for s in sni.split(".")):
    sys.exit("server-name 必须是合法 DNS 名称，如 node.example.com")
for flag,address in (("-6",v6),("-4",v4)):
    import json
    interfaces=json.loads(subprocess.check_output(["ip",flag,"-j","addr","show"]))
    if not any(ipaddress.ip_address(a["local"])==address for i in interfaces for a in i.get("addr_info",[])):
        sys.exit(f"地址未配置到本机网卡：{address}")
PY
  python3 - "${NODE_LABEL:-AnyTLS-$NODE_ID}" <<'PY'
import sys
label=sys.argv[1]
if not 1<=len(label)<=64 or not all(ch.isprintable() for ch in label):
    sys.exit("节点名称须为 1–64 个可打印字符")
PY
  [[ -z "$CERT" && -z "$KEY" || -n "$CERT" && -n "$KEY" ]] || die '--cert 和 --key 必须一起提供'
  if [[ -n "$CERT" ]]; then
    [[ -r "$CERT" && -r "$KEY" ]] || die '证书/私钥不可读'
  fi
}
download_core() {
  local stage=$1 arch digest filename
  case "$(uname -m)" in
    x86_64) arch=amd64; digest=699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968 ;;
    aarch64|arm64) arch=arm64; digest=436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26 ;;
    *) die '目前支持 Linux x86_64 / aarch64' ;;
  esac
  filename=sing-box-$CORE_VERSION-linux-$arch.tar.gz
  curl -4fSL --retry 3 --connect-timeout 10 --max-time 180 \
    "https://github.com/SagerNet/sing-box/releases/download/v$CORE_VERSION/$filename" -o "$stage/core.tar.gz"
  printf '%s  %s\n' "$digest" "$stage/core.tar.gz" | sha256sum -c -
  tar -xzf "$stage/core.tar.gz" -C "$stage" "sing-box-$CORE_VERSION-linux-$arch/sing-box"
  install -m 755 "$stage/sing-box-$CORE_VERSION-linux-$arch/sing-box" "$stage/sing-box"
}
make_certificate() {
  local stage=$1 cert_pub key_pub
  if [[ -n "$CERT" ]]; then
    cp -- "$CERT" "$stage/server.crt"
    cp -- "$KEY" "$stage/server.key"
  else
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -nodes \
      -days 825 -subj "/CN=$SERVER_NAME" -addext "subjectAltName=DNS:$SERVER_NAME" \
      -addext 'basicConstraints=critical,CA:TRUE' \
      -keyout "$stage/server.key" -out "$stage/server.crt" >/dev/null 2>&1
  fi
  openssl x509 -in "$stage/server.crt" -noout -checkend 86400 >/dev/null || die '证书已过期或将在一天内到期'
  # x509 -checkhost only prints a result on OpenSSL 3.0; verify returns failure.
  openssl verify -partial_chain -trusted "$stage/server.crt" -verify_hostname "$SERVER_NAME" \
    "$stage/server.crt" >/dev/null || die '证书不匹配 server-name 或证书校验失败'
  cert_pub=$(openssl x509 -in "$stage/server.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)
  key_pub=$(openssl pkey -in "$stage/server.key" -passin pass: -pubout -outform DER | sha256sum)
  [[ "$cert_pub" == "$key_pub" ]] || die '证书与私钥不匹配（私钥必须无口令）'
}
make_bundle() {
  # output-dir, IPv6, local-IPv4, port, password, SNI, cert-path, key-path, self-signed(0/1)
  python3 - "$@" <<'PY'
import json,pathlib,sys,urllib.parse
output,v6,v4,port,password,sni,cert,key,self_signed=sys.argv[1:]
output=pathlib.Path(output);port=int(port)
server={
 "log":{"level":"warn","timestamp":True},
 "dns":{"servers":[{"type":"https","tag":"dns4","server":"1.1.1.1","server_port":443,
   "path":"/dns-query","tls":{"enabled":True,"server_name":"cloudflare-dns.com"},
   "inet4_bind_address":v4}],"strategy":"ipv4_only","final":"dns4"},
 "inbounds":[{"type":"anytls","tag":"anytls-in","listen":v6,"listen_port":port,
   "users":[{"name":"owner","password":password}],
   "tls":{"enabled":True,"server_name":sni,"min_version":"1.2","certificate_path":cert,"key_path":key}}],
 "outbounds":[{"type":"direct","tag":"ipv4-direct","inet4_bind_address":v4,
   "domain_resolver":{"server":"dns4","strategy":"ipv4_only"}}],
 "route":{"rules":[{"action":"resolve","server":"dns4","strategy":"ipv4_only"},
   {"ip_version":6,"action":"reject"},
   {"ip_is_private":True,"action":"reject"},
   {"ip_cidr":["0.0.0.0/8","100.64.0.0/10","224.0.0.0/4","240.0.0.0/4"],"action":"reject"}],
   "final":"ipv4-direct","default_domain_resolver":{"server":"dns4","strategy":"ipv4_only"}}
}
tls={"enabled":True,"server_name":sni,"insecure":False,"min_version":"1.2"}
if self_signed=="1": tls["certificate"]=pathlib.Path(cert).read_text(encoding="utf-8").splitlines()
client={"log":{"level":"warn"},
 "inbounds":[{"type":"mixed","tag":"local","listen":"127.0.0.1","listen_port":1080}],
 "outbounds":[{"type":"anytls","tag":"proxy","server":v6,"server_port":port,"password":password,"tls":tls}],
 "route":{"final":"proxy"}}
for name,config in (("config.json",server),("client.json",client)):
    (output/name).write_text(json.dumps(config,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
# URI cannot portably carry custom certificate trust. Do not emit an insecure URI.
uri="anytls://"+urllib.parse.quote(password,safe="")+f"@[{v6}]:{port}?"+urllib.parse.urlencode({"sni":sni})+"#AnyTLS-IPv6-to-IPv4"
text=f"AnyTLS | IPv6 入站 / IPv4 出站\n服务器: {v6}\n端口: {port} (TCP)\n密码: {password}\nSNI: {sni}\n绑定本机 IPv4 出站: {v4}\n"
if self_signed=="1":
    text+="自签证书模式：请使用 client.json（已嵌入信任证书），或在客户端显式信任 server.crt。\n二维码请使用 qr 命令；自签兼容扫码须明确添加 --allow-insecure。\n"
else:
    text+="公开 CA 证书模式；请核对客户端支持 AnyTLS 和完整证书校验。\n"+uri+"\n"
(output/"client.txt").write_text(text,encoding="utf-8")
PY
}
create_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=AnyTLS IPv6 in / IPv4 out (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NAME
Group=$NAME
WorkingDirectory=$DIR
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
# sing-box uses netlink to inspect network interfaces/routes during startup.
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
}
save_failure_diagnostics() {
  local report
  report=$(mktemp "/root/$NAME-failure-$(date +%Y%m%d-%H%M%S)-XXXXXXXX.log") || return 1
  {
    printf 'AnyTLS installer %s / sing-box %s\n' "$VERSION" "$CORE_VERSION"
    systemctl --no-pager --full status "$SERVICE" || true
    systemctl show "$SERVICE" -p Result -p ExecMainCode -p ExecMainStatus || true
    journalctl -u "$SERVICE" -n 60 --no-pager || true
  } > "$report" 2>&1
  chmod 600 "$report"
  cat "$report" >&2
  printf '[诊断] 本次失败日志已保留：%s\n' "$report" >&2
}
do_install() (
  need_root
  info "AnyTLS 安装器 $VERSION / sing-box $CORE_VERSION / 节点 $NODE_ID"
  [[ ! -e "$DIR" && ! -e "$BIN_DIR" && ! -e "$UNIT" ]] || die '检测到已有 AnyTLS 文件，拒绝覆盖；请使用 show/status/test'
  require_install_deps
  if systemctl cat "$SERVICE" >/dev/null 2>&1; then die '已有同名服务，拒绝覆盖'; fi
  [[ -n "$IPV6" ]] || IPV6=$(auto_ipv6)
  [[ -n "$IPV4" ]] || IPV4=$(auto_ipv4)
  [[ -n "$IPV6" && -n "$IPV4" ]] || die '无法自动识别地址，请指定 --ipv6 / --ipv4'
  validate_options
  PORT=$((10#$PORT))
  [[ -z "$(ss -H -ltn "sport = :$PORT")" ]] || die "TCP $PORT 已占用，请指定其他 --port"
  curl -4fsS --noproxy '*' --interface "$IPV4" --connect-timeout 5 --max-time 15 https://api.ipify.org >/dev/null
  local stage created=0 password self_signed=1
  stage=$(mktemp -d /tmp/anytls-v6v4-install.XXXXXXXX)
  # shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap.
  cleanup() {
    local rc=$?
    if (( rc != 0 && created == 1 )); then
      save_failure_diagnostics || true
      systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
      rm -f -- "$UNIT"
      rm -rf -- "$DIR" "$BIN_DIR"
      systemctl daemon-reload >/dev/null 2>&1 || true
      printf '[错误] 安装失败，已清理本次 AnyTLS 服务。\n' >&2
    fi
    rm -rf -- "$stage"
  }
  trap cleanup EXIT
  download_core "$stage"
  make_certificate "$stage"
  [[ -z "$CERT" ]] || self_signed=0
  password=$(openssl rand -hex 32)
  make_bundle "$stage" "$IPV6" "$IPV4" "$PORT" "$password" "$SERVER_NAME" "$stage/server.crt" "$stage/server.key" "$self_signed"
  "$stage/sing-box" check -c "$stage/config.json"
  "$stage/sing-box" check -c "$stage/client.json"
  getent group "$NAME" >/dev/null || groupadd --system "$NAME"
  id "$NAME" >/dev/null 2>&1 || useradd --system --no-create-home --gid "$NAME" --shell /usr/sbin/nologin "$NAME"
  created=1
  install -d -o root -g "$NAME" -m 750 "$DIR"
  install -d -o root -g root -m 755 "$BIN_DIR"
  install -o root -g root -m 755 "$stage/sing-box" "$BIN"
  install -o root -g "$NAME" -m 640 "$stage/server.crt" "$DIR/server.crt"
  install -o root -g "$NAME" -m 640 "$stage/server.key" "$DIR/server.key"
  make_bundle "$stage" "$IPV6" "$IPV4" "$PORT" "$password" "$SERVER_NAME" "$DIR/server.crt" "$DIR/server.key" "$self_signed"
  install -o root -g "$NAME" -m 640 "$stage/config.json" "$CONF"
  install -o root -g root -m 600 "$stage/client.json" "$DIR/client.json"
  install -o root -g root -m 600 "$stage/client.txt" "$DIR/client.txt"
  printf '%s\n' "${NODE_LABEL:-AnyTLS-$NODE_ID}" > "$DIR/node-name"
  chmod 600 "$DIR/node-name"
  "$BIN" check -c "$CONF"
  create_unit
  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  sleep 1
  systemctl is-active --quiet "$SERVICE" || die '服务启动失败'
  self_test
  info "安装成功：[$IPV6]:$PORT (TCP)。请在商家安全组和主机防火墙放通该 IPv6 TCP 端口。"
  show_config
)
show_config() {
  installed || die '尚未安装 AnyTLS'
  # Suppress the obsolete 1.0.x QR limitation without rewriting existing credentials.
  sed '/^不提供跳过证书验证的导入链接。$/d' "$DIR/client.txt"
  info "sing-box 客户端完整配置：$DIR/client.json；请私下复制到客户端"
  openssl x509 -in "$DIR/server.crt" -noout -dates -fingerprint -sha256
  info '严格校验导入链接（自签证书需客户端先显式信任证书）：'
  share_uri 0
}
share_uri() {
  # Standard AnyTLS URI. Custom CA trust cannot be encoded in the URI.
  python3 - "$CONF" "$DIR/client.json" "$DIR/node-name" "$NODE_ID" "${1:-0}" <<'PY'
import json,pathlib,sys,urllib.parse
config,client,label_file,identifier,insecure=sys.argv[1:]
c=json.loads(pathlib.Path(config).read_text(encoding="utf-8"))
json.loads(pathlib.Path(client).read_text(encoding="utf-8"))
i=c["inbounds"][0]
if i["type"]!="anytls": sys.exit("不是受支持的 AnyTLS 节点")
label=pathlib.Path(label_file).read_text(encoding="utf-8").strip() if pathlib.Path(label_file).is_file() else "AnyTLS-"+identifier
query=urllib.parse.urlencode({"sni":i["tls"]["server_name"],"insecure":"1" if insecure=="1" else "0"})
password=urllib.parse.quote(i["users"][0]["password"],safe="")
print(f'anytls://{password}@[{i["listen"]}]:{i["listen_port"]}/?{query}#'+urllib.parse.quote(label,safe=""))
PY
}
ensure_qrencode() {
  if ! command -v qrencode >/dev/null 2>&1; then
    info '正在安装二维码工具 qrencode ...'
    command -v apt-get >/dev/null 2>&1 || die '请先安装 qrencode'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode
  fi
}
show_qr() {
  installed || die '尚未安装此节点'
  local uri mode=strict file
  if (( ALLOW_INSECURE == 1 )); then
    mode=insecure
    info '自签兼容模式：导入链接包含 insecure=1，会关闭客户端 TLS 证书身份校验。'
  else
    info '严格校验模式：自签证书需客户端先信任 server.crt；公开 CA 证书可直接导入。'
  fi
  ensure_qrencode
  uri=$(share_uri "$ALLOW_INSECURE")
  file=$DIR/qr-$mode.png
  printf '%s' "$uri" | qrencode -t PNG -m 2 -o "$file.tmp"
  chmod 600 "$file.tmp"
  mv -f -- "$file.tmp" "$file"
  printf '\n%s\n\n' "$uri"
  printf '%s' "$uri" | qrencode -t UTF8 -m 1
  info "节点 $NODE_ID 二维码 PNG：$file（含节点密码，请私下保存）"
}
self_test() (
  installed || die '尚未安装 AnyTLS'
  local tmp pid='' port expected observed direct n
  tmp=$(mktemp -d /tmp/anytls-v6v4-test.XXXXXXXX)
  # shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap.
  cleanup_test() {
    [[ -z "$pid" ]] || { kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; }
    rm -rf -- "$tmp"
  }
  trap cleanup_test EXIT
  port=$(python3 - "$DIR/client.json" "$tmp/client.json" <<'PY'
import json,socket,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
with socket.socket() as s:
    s.bind(("127.0.0.1",0));port=s.getsockname()[1]
c["inbounds"][0]["listen_port"]=port
with open(sys.argv[2],"w",encoding="utf-8") as f: json.dump(c,f)
print(port)
PY
  ) || die '生成自检客户端失败'
  "$BIN" check -c "$tmp/client.json" || die '客户端配置校验失败'
  "$BIN" run -c "$tmp/client.json" > "$tmp/client.log" 2>&1 & pid=$!
  for (( n=0; n<30; n++ )); do
    kill -0 "$pid" 2>/dev/null || die '自检客户端启动失败'
    [[ -z "$(ss -H -ltn "sport = :$port")" ]] || break
    sleep 0.1
  done
  observed=$(curl -fsS --noproxy '' --socks5-hostname "127.0.0.1:$port" --connect-timeout 8 --max-time 30 https://api.ipify.org) || {
    tail -n 12 "$tmp/client.log" >&2
    die 'AnyTLS 完整代理测试失败，请检查证书、IPv4 DNS/网络与服务日志'
  }
  python3 - "$observed" <<'PY'
import ipaddress,sys
ipaddress.IPv4Address(sys.argv[1])
PY
  expected=$(python3 - "$CONF" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding="utf-8"))["outbounds"][0]["inet4_bind_address"])
PY
  ) || die '读取 IPv4 出站地址失败'
  direct=$(curl -4fsS --noproxy '*' --interface "$expected" --connect-timeout 5 --max-time 15 https://api.ipify.org) || die '直接 IPv4 出站测试失败'
  [[ "$observed" == "$direct" ]] || die "代理出口 $observed 与本机 IPv4 公网出口 $direct 不符"
  info "本机 SOCKS → AnyTLS IPv6 → IPv4 自检通过：$observed"
  info '还需用手机/外部 IPv6 网络验证安全组、路由与客户端可达性。'
)
do_backup() {
  installed || die '尚未安装 AnyTLS'
  local file
  file=$(mktemp "/root/$NAME-backup-$(date +%Y%m%d-%H%M%S)-XXXXXXXX.tar.gz")
  tar -czf "$file" -C / "etc/$NAME" "etc/systemd/system/$NAME.service"
  chmod 600 "$file"
  info "备份（含密码和私钥）：$file；核心版本 $CORE_VERSION"
}
do_uninstall() {
  installed || die '尚未安装 AnyTLS'
  (( YES == 1 )) || die '请添加 --yes 确认卸载；脚本先备份，再删除此 AnyTLS 服务'
  do_backup
  systemctl disable --now "$SERVICE"
  rm -f -- "$UNIT"
  systemctl daemon-reload
  rm -rf -- "$DIR" "$BIN_DIR"
  info "节点 $NODE_ID 已卸载；系统账户和备份保留，其他节点不受影响。"
}
show_menu() {
  local script_path=${BASH_SOURCE[0]} choice id label port mode answer
  [[ "$script_path" == /* ]] || script_path=$PWD/$script_path
  while true; do
    printf '\n=== AnyTLS 节点管理 %s | IPv6 入站 / IPv4 出站 ===\n' "$VERSION"
    printf '1) 安装默认节点\n2) 列出节点\n3) 添加独立节点\n4) 节点二维码/导入链接\n5) 查看节点配置\n6) 节点完整自检\n7) 节点状态\n8) 备份节点\n9) 卸载指定节点\n0) 退出\n'
    read -r -p '请选择 [0-9]：' choice || return 0
    case "$choice" in
      0) return 0 ;;
      1) if bash "$script_path" install; then :; else info '安装失败，菜单继续可用。'; fi ;;
      2) if bash "$script_path" list; then :; else info '列表查询失败。'; fi ;;
      3)
        read -r -p '新节点 ID（小写字母/数字/连字符，例如 phone2）：' id || return 0
        read -r -p "显示名称 [AnyTLS-$id]：" label || return 0
        port=$(suggest_port)
        read -r -p "TCP 端口 [$port]：" answer || return 0
        port=${answer:-$port}
        if bash "$script_path" add --node "$id" --name "${label:-AnyTLS-$id}" --port "$port"; then
          info '节点已添加。可选菜单 4 显示二维码；请放通新端口。'
        else info '添加失败，已有节点保留。'; fi ;;
      4|5|6|7|8|9)
        read -r -p '节点 ID [default]：' id || return 0
        id=${id:-default}
        case "$choice" in
          4)
            printf '1) 严格证书校验（自签需先信任证书）\n2) 自签兼容扫码（跳过证书校验）\n0) 返回\n'
            read -r -p '请选择 [0-2]：' mode || return 0
            case "$mode" in
              1) if bash "$script_path" qr --node "$id"; then :; else info '二维码生成失败。'; fi ;;
              2) if bash "$script_path" qr --node "$id" --allow-insecure; then :; else info '二维码生成失败。'; fi ;;
              0) : ;; *) info '无效选项。' ;;
            esac ;;
          5) if bash "$script_path" show --node "$id"; then :; else info '查看失败。'; fi ;;
          6) if bash "$script_path" test --node "$id"; then :; else info '自检失败。'; fi ;;
          7) if bash "$script_path" status --node "$id"; then :; else info '状态查询失败。'; fi ;;
          8) if bash "$script_path" backup --node "$id"; then :; else info '备份失败。'; fi ;;
          9)
            read -r -p "仅卸载节点 $id，输入 YES 确认：" answer || return 0
            if [[ "$answer" == YES ]]; then
              if bash "$script_path" uninstall --node "$id" --yes; then :; else info '卸载失败。'; fi
            else info '已取消。'; fi ;;
        esac ;;
      *) info '无效选项。' ;;
    esac
  done
}
usage() {
  cat <<'HELP'
AnyTLS IPv6-in / IPv4-out v1.1.0 (sing-box 1.14.4)
  bash install.sh                         # 交互菜单，已有节点无需重装
  bash install.sh install [--port 38445] [--ipv6 <public-v6>] [--ipv4 <local-v4>]
                          [--server-name node.example.com --cert /path/fullchain.pem --key /path/key.pem]
  bash install.sh add --node phone2 [--name 手机2] [--port 38446] [证书/地址参数]
  bash install.sh list | menu
  bash install.sh show | status | test | backup [--node default]
  bash install.sh qr [--node default] [--allow-insecure]
  bash install.sh uninstall [--node default] --yes
每个节点有独立的目录、端口、密码和服务。default 兼容 1.0.x 的现有节点。
默认二维码严格校验证书；--allow-insecure 明确选择自签兼容扫码，关闭客户端证书校验。
HELP
}
main() {
  local command_name=${1:-menu}
  (( $# == 0 )) || shift
  while (( $# )); do
    case "$1" in
      --port|--ipv6|--ipv4|--server-name|--cert|--key|--node|--name)
        if (( $# < 2 )) || [[ -z "$2" ]]; then die "参数 $1 缺少值"; fi
        case "$1" in
          --port) PORT=$2; PORT_SET=1 ;; --ipv6) IPV6=$2 ;; --ipv4) IPV4=$2 ;;
          --server-name) SERVER_NAME=$2 ;; --cert) CERT=$2 ;; --key) KEY=$2 ;;
          --node) NODE_ID=$2 ;; --name) NODE_LABEL=$2 ;;
        esac
        shift 2 ;;
      --yes) YES=1; shift ;;
      --allow-insecure) ALLOW_INSECURE=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done
  select_node "$NODE_ID"
  if (( ALLOW_INSECURE == 1 )) && [[ "$command_name" != qr ]]; then die '--allow-insecure 仅用于 qr 命令'; fi
  case "$command_name" in
    help|-h|--help) usage ;;
    install) do_install ;;
    add)
      [[ "$NODE_ID" != default ]] || die '新增节点请指定 --node ID；default 保留给原有节点'
      if (( PORT_SET == 0 )); then PORT=$(suggest_port); fi
      do_install ;;
    menu) need_root; show_menu ;;
    list) need_root; list_nodes ;;
    qr) need_root; show_qr ;;
    show) need_root; show_config ;;
    test|selftest) need_root; self_test ;;
    status) need_root; installed || die '尚未安装'; systemctl --no-pager --full status "$SERVICE" ;;
    backup) need_root; do_backup ;;
    uninstall) need_root; do_uninstall ;;
    *) usage; die "未知命令：$command_name" ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
