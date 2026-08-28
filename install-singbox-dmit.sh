#!/bin/bash
# DMIT 专用版：在部署 VLESS Reality 前自动优选安全的 SNI/handshake target。
# 通用机器请继续使用 install-singbox-yyds.sh。
set -eu
set -o pipefail 2>/dev/null || true

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

# ---------- DMIT Reality SNI 优选 ----------
SNI_TOP_N="${SNI_TOP_N:-5}"
SNI_SAMPLES=3
SNI_CONNECT_TIMEOUT="${SNI_CONNECT_TIMEOUT:-4}"
SNI_TOTAL_TIMEOUT="${SNI_TOTAL_TIMEOUT:-8}"

DMIT_LOCAL_IPV4=""
DMIT_LOCAL_IPV6=""
DMIT_LOCAL_ASN="?"
DMIT_LOCAL_ASN_NAME="UNKNOWN"
DMIT_LOCAL_ASNS=""
declare -a DMIT_LOCAL_IPS=()

get_public_ipv4() {
  local ip="" url
  for url in https://api4.ipify.org https://v4.ident.me https://icanhazip.com; do
    ip="$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

get_public_ipv6() {
  local ip="" url
  for url in https://api6.ipify.org https://v6.ident.me https://icanhazip.com; do
    ip="$(curl -6 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" == *:* ]] && [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

reverse_ipv4() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  printf '%s.%s.%s.%s' "$d" "$c" "$b" "$a"
}

get_ip_asn() {
  local ip="$1" result asn org
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    result="$(dig +short TXT "$(reverse_ipv4 "$ip").origin.asn.cymru.com" 2>/dev/null | head -n1 | tr -d '"' || true)"
    asn="$(printf '%s' "$result" | awk -F'|' '{gsub(/[[:space:]]/,"",$1); print $1}')"
  fi
  if ! [[ "${asn:-}" =~ ^[0-9]+$ ]]; then
    org="$(curl -fsS --max-time 5 "https://ipinfo.io/${ip}/json" 2>/dev/null | jq -r '.org // empty' 2>/dev/null || true)"
    asn="$(printf '%s' "$org" | sed -nE 's/^AS([0-9]+).*/\1/p')"
  fi
  [[ "$asn" =~ ^[0-9]+$ ]] && printf '%s' "$asn" || printf '?'
}

get_asn_name() {
  local asn="$1" result name
  [ "$asn" != "?" ] || { printf 'UNKNOWN'; return 0; }
  result="$(dig +short TXT "AS${asn}.asn.cymru.com" 2>/dev/null | head -n1 | tr -d '"' || true)"
  name="$(printf '%s' "$result" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $5); print $5}')"
  [ -n "$name" ] && printf '%s' "$name" || printf 'UNKNOWN'
}

get_ip_org() {
  local ip="$1" org
  org="$(curl -fsS --max-time 5 "https://ipinfo.io/${ip}/json" 2>/dev/null | jq -r '.org // empty' 2>/dev/null || true)"
  printf '%s' "$org" | sed -E 's/^AS[0-9]+[[:space:]]*//'
}

sanitize_sni() {
  printf '%s' "$1" | sed -E 's#^[[:space:]]*https?://##I; s#/.*$##; s/:443$//; s/[[:space:]]//g' | tr '[:upper:]' '[:lower:]'
}

valid_sni() {
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

is_shared_asn() {
  case "$1" in
    8075|12222|12989|13335|14061|14618|15133|15169|16276|16509|16625|19551|20473|20940|21342|24940|28753|31898|32787|33905|37963|396982|45090|45102|54113|60068|60781|63949|132203|199524|209242|212238) return 0 ;;
    *) return 1 ;;
  esac
}

has_shared_network_marker() {
  local text
  text="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$text" | grep -Eqi \
    'cloudflare|fastly|akamai|cloudfront|amazon|amazonaws|google cloud|googleusercontent|microsoft|azure|vercel|netlify|edgecast|imperva|incapsula|stackpath|bunnycdn|bunny\.net|gcore|cdn77|cdnetworks|alibaba|aliyun|tencent cloud|oracle cloud|digitalocean|hetzner|linode|akamai connected cloud|ovh|vultr|leaseweb cdn'
}

append_unique_word() {
  local list="$1" value="$2"
  [ -n "$value" ] || { printf '%s' "$list"; return 0; }
  case " $list " in
    *" $value "*) printf '%s' "$list" ;;
    *) printf '%s%s%s' "$list" "${list:+ }" "$value" ;;
  esac
}

is_local_ip() {
  local candidate="$1" local_ip
  for local_ip in "${DMIT_LOCAL_IPS[@]}"; do
    [ "$candidate" != "$local_ip" ] || return 0
  done
  return 1
}

is_local_asn() {
  [ "$1" != "?" ] || return 1
  case " $DMIT_LOCAL_ASNS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

collect_interface_ips() {
  local ip
  command -v ip >/dev/null 2>&1 || return 0
  while read -r ip; do
    [ -n "$ip" ] && ! is_local_ip "$ip" && DMIT_LOCAL_IPS+=("$ip")
  done < <(ip -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}')
}

show_local_ip_metadata() {
  local family="$1" ip="$2" asn name asn_label
  if [ -z "$ip" ]; then
    printf '  %-4s %s\n' "$family:" "不可用或未检测到"
    return 0
  fi

  asn="$(get_ip_asn "$ip")"
  name="$(get_asn_name "$asn")"
  if [ "$name" = "UNKNOWN" ]; then
    name="$(get_ip_org "$ip")"
    [ -n "$name" ] || name="UNKNOWN"
  fi
  asn_label="ASN 查询失败"
  [ "$asn" = "?" ] || asn_label="AS${asn}"
  printf '  %-5s %s / %s / %s\n' "$family:" "$ip" "$asn_label" "$name"
  if [ "$asn" != "?" ]; then
    DMIT_LOCAL_ASNS="$(append_unique_word "$DMIT_LOCAL_ASNS" "$asn")"
    if [ "$DMIT_LOCAL_ASN" = "?" ]; then
      DMIT_LOCAL_ASN="$asn"
      DMIT_LOCAL_ASN_NAME="$name"
    fi
  fi
}

detect_dmit_network() {
  DMIT_LOCAL_IPV4="$(get_public_ipv4 || true)"
  DMIT_LOCAL_IPV6="$(get_public_ipv6 || true)"
  DMIT_LOCAL_ASN="?"
  DMIT_LOCAL_ASN_NAME="UNKNOWN"
  DMIT_LOCAL_ASNS=""
  DMIT_LOCAL_IPS=()
  [ -n "$DMIT_LOCAL_IPV4" ] && DMIT_LOCAL_IPS+=("$DMIT_LOCAL_IPV4")
  [ -n "$DMIT_LOCAL_IPV6" ] && DMIT_LOCAL_IPS+=("$DMIT_LOCAL_IPV6")
  collect_interface_ips

  echo
  info "当前 VPS 公网网络信息:"
  show_local_ip_metadata "IPv4" "$DMIT_LOCAL_IPV4"
  show_local_ip_metadata "IPv6" "$DMIT_LOCAL_IPV6"

  if [ -z "$DMIT_LOCAL_IPV4" ] && [ -z "$DMIT_LOCAL_IPV6" ]; then
    warn "公网 IP 检测失败；将使用本机接口地址排除回环目标，安装继续"
  fi
  if [ -z "$DMIT_LOCAL_ASNS" ]; then
    warn "ASN/组织查询失败：同 ASN 加分自动停用，安全检测和安装不会中断"
  elif ! printf '%s' "$DMIT_LOCAL_ASN_NAME" | grep -Eqi 'DMIT|DMITCLOUD|DMIT-CLOUD'; then
    warn "当前 ASN 名称未识别为 DMIT；仍按实际 ASN 检测，但建议只在 DMIT VPS 使用本脚本"
  fi
  return 0
}

median_and_jitter_ms() {
  LC_ALL=C sort -n | awk '
    { values[NR]=$1; sum+=$1 }
    END {
      if (NR == 0) exit 1
      if (NR % 2) median=values[(NR+1)/2]
      else median=(values[NR/2]+values[NR/2+1])/2
      printf "%.1f|%.1f", median*1000, (values[NR]-values[1])*1000
    }'
}

evaluate_reality_domain() {
  local domain="$1" cname_text ip asn asn_name tls_output curl_output rc
  local sample sec http_code verify_result metrics failures failure_rate
  local stability_score jitter_score latency_score score same_asn h2 tls13 cert_match
  local -a ips all_dns_ips samples
  local -A candidate_asns candidate_asn_names

  SNI_TEST_REASON=""
  SNI_TEST_DOMAIN="$(sanitize_sni "$domain")"
  valid_sni "$SNI_TEST_DOMAIN" || { SNI_TEST_REASON="域名格式无效"; return 1; }

  mapfile -t ips < <(dig +short A "$SNI_TEST_DOMAIN" 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u)
  mapfile -t all_dns_ips < <({ printf '%s\n' "${ips[@]}"; dig +short AAAA "$SNI_TEST_DOMAIN" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$'; } | sed '/^$/d' | sort -u)
  [ "${#ips[@]}" -gt 0 ] || { SNI_TEST_REASON="DNS A 记录失败"; return 1; }
  for ip in "${all_dns_ips[@]}"; do
    if is_local_ip "$ip"; then
      SNI_TEST_REASON="域名解析到本机 IP（$ip），已阻止回环"
      return 1
    fi
  done

  cname_text="$(dig +short CNAME "$SNI_TEST_DOMAIN" 2>/dev/null | tr '\n' ' ' || true)"
  if has_shared_network_marker "$SNI_TEST_DOMAIN $cname_text"; then
    SNI_TEST_REASON="域名或 CNAME 命中共享 CDN/云网络"
    return 1
  fi

  for ip in "${ips[@]}"; do
    asn="$(get_ip_asn "$ip")"
    asn_name="$(get_asn_name "$asn")"
    candidate_asns["$ip"]="$asn"
    candidate_asn_names["$ip"]="$asn_name"
    if { [ "$asn" != "?" ] && is_shared_asn "$asn"; } || has_shared_network_marker "$asn_name"; then
      SNI_TEST_REASON="解析 IP $ip 命中共享 CDN/云网络（AS${asn} ${asn_name}）"
      return 1
    fi
  done

  SNI_TEST_IP=""
  SNI_TEST_ASN="?"
  SNI_TEST_ASN_NAME="UNKNOWN"
  SNI_TEST_TLS_MS=""
  SNI_TEST_JITTER_MS=""
  SNI_TEST_FAILURE_RATE="100.0"
  SNI_TEST_HTTP="000"
  SNI_TEST_H2="NO"
  SNI_TEST_TLS13="NO"
  SNI_TEST_CERT_MATCH="NO"
  SNI_TEST_SAME_ASN="NO"
  SNI_TEST_SCORE=0

  for ip in "${ips[@]:0:3}"; do
    asn="${candidate_asns[$ip]}"
    asn_name="${candidate_asn_names[$ip]}"

    tls_output="$(timeout "${SNI_TOTAL_TIMEOUT}s" openssl s_client \
      -connect "${ip}:443" -servername "$SNI_TEST_DOMAIN" \
      -alpn 'h2,http/1.1' </dev/null 2>/dev/null || true)"
    printf '%s' "$tls_output" | grep -Eqi 'TLSv1\.[23]|Protocol *: *TLSv1\.[23]' || continue

    h2="NO"
    tls13="NO"
    printf '%s' "$tls_output" | grep -qi 'ALPN protocol: h2' && h2="YES"
    printf '%s' "$tls_output" | grep -Eqi 'TLSv1\.3|Protocol *: *TLSv1\.3|New, TLSv1\.3' && tls13="YES"

    samples=()
    http_code="000"
    cert_match="NO"
    for ((sample=1; sample<=SNI_SAMPLES; sample++)); do
      rc=0
      curl_output="$(curl -4 -sS -o /dev/null \
        --resolve "${SNI_TEST_DOMAIN}:443:${ip}" \
        --connect-timeout "$SNI_CONNECT_TIMEOUT" --max-time "$SNI_TOTAL_TIMEOUT" \
        -w '%{time_appconnect}|%{http_code}|%{ssl_verify_result}' "https://${SNI_TEST_DOMAIN}/" 2>/dev/null)" || rc=$?
      [ "$rc" -eq 0 ] || continue
      IFS='|' read -r sec http_code verify_result <<< "$curl_output"
      [ "$verify_result" = "0" ] || continue
      if awk -v value="$sec" 'BEGIN {exit !(value > 0)}'; then
        samples+=("$sec")
        cert_match="YES"
      fi
    done

    [ "${#samples[@]}" -ge 2 ] || continue
    metrics="$(printf '%s\n' "${samples[@]}" | median_and_jitter_ms)" || continue
    failures=$((SNI_SAMPLES - ${#samples[@]}))
    failure_rate="$(awk -v failed="$failures" -v count="$SNI_SAMPLES" 'BEGIN {printf "%.1f", failed*100/count}')"

    if [ -z "$SNI_TEST_IP" ] || awk -v af="$failure_rate" -v bf="$SNI_TEST_FAILURE_RATE" -v am="${metrics%%|*}" -v bm="$SNI_TEST_TLS_MS" 'BEGIN {exit !((af < bf) || (af == bf && am < bm))}'; then
      SNI_TEST_IP="$ip"
      SNI_TEST_ASN="$asn"
      SNI_TEST_ASN_NAME="$asn_name"
      SNI_TEST_TLS_MS="${metrics%%|*}"
      SNI_TEST_JITTER_MS="${metrics##*|}"
      SNI_TEST_FAILURE_RATE="$failure_rate"
      SNI_TEST_HTTP="$http_code"
      SNI_TEST_H2="$h2"
      SNI_TEST_TLS13="$tls13"
      SNI_TEST_CERT_MATCH="$cert_match"
    fi
  done

  [ -n "$SNI_TEST_IP" ] || {
    SNI_TEST_REASON="443/TLS/证书校验失败、3 次握手成功不足 2 次，或目标属于共享 CDN/云网络"
    return 1
  }

  same_asn="NO"
  is_local_asn "$SNI_TEST_ASN" && same_asn="YES"
  SNI_TEST_SAME_ASN="$same_asn"

  if awk -v rate="$SNI_TEST_FAILURE_RATE" 'BEGIN {exit !(rate == 0)}'; then stability_score=400; else stability_score=200; fi
  jitter_score="$(awk -v ms="$SNI_TEST_JITTER_MS" 'BEGIN {
    if (ms <= 5) print 40; else if (ms <= 15) print 30; else if (ms <= 30) print 20;
    else if (ms <= 60) print 10; else print 0
  }')"
  latency_score="$(awk -v ms="$SNI_TEST_TLS_MS" 'BEGIN {
    if (ms <= 10) print 80; else if (ms <= 20) print 70; else if (ms <= 40) print 60;
    else if (ms <= 60) print 50; else if (ms <= 100) print 40; else if (ms <= 150) print 25;
    else if (ms <= 250) print 10; else print 0
  }')"
  score=$((1000 + stability_score + jitter_score + latency_score + 5))
  [ "$same_asn" = "YES" ] && score=$((score + 100))
  [ "$SNI_TEST_TLS13" = "YES" ] && score=$((score + 10))
  [ "$SNI_TEST_H2" = "YES" ] && score=$((score + 2))
  SNI_TEST_SCORE="$score"
  return 0
}

select_reality_sni() {
  local result_file domain choice selected line i
  local -a default_domains top_rows

  default_domains=(
    www.gnu.org www.openbsd.org www.netbsd.org www.sqlite.org www.vim.org
    www.ffmpeg.org www.openssh.com www.freebsd.org www.gentoo.org www.samba.org
    www.postgresql.org www.perl.org www.ruby-lang.org www.ietf.org www.iana.org
    www.isc.org www.eff.org www.kernel.org www.debian.org www.archlinux.org
    www.python.org www.apache.org
  )

  detect_dmit_network
  result_file="$(mktemp)"
  : > "$result_file"

  echo
  info "开始检测 ${#default_domains[@]} 个候选；每个候选连续进行 3 次 TLS 握手..."
  info "评分顺序：安全/非 CDN > TLS 稳定性 > 同 ASN > TLS 延迟 > TLS1.3/证书 > H2"
  for domain in "${default_domains[@]}"; do
    printf '  %-28s ' "$domain"
    if evaluate_reality_domain "$domain"; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$SNI_TEST_SCORE" "$SNI_TEST_TLS_MS" "$SNI_TEST_DOMAIN" "$SNI_TEST_IP" \
        "$SNI_TEST_ASN" "$SNI_TEST_SAME_ASN" "$SNI_TEST_H2" "$SNI_TEST_ASN_NAME" \
        "$SNI_TEST_JITTER_MS" "$SNI_TEST_FAILURE_RATE" "$SNI_TEST_TLS13" "$SNI_TEST_CERT_MATCH" >> "$result_file"
      echo "通过  中位 ${SNI_TEST_TLS_MS} ms  抖动 ${SNI_TEST_JITTER_MS} ms  失败 ${SNI_TEST_FAILURE_RATE}%  AS${SNI_TEST_ASN}"
    else
      echo "排除  $SNI_TEST_REASON"
    fi
  done

  mapfile -t top_rows < <(sort -t $'\t' -k1,1nr -k2,2n "$result_file" | head -n "$SNI_TOP_N")
  rm -f "$result_file"

  echo
  if [ "${#top_rows[@]}" -gt 0 ]; then
    echo "Reality SNI Top ${#top_rows[@]}（共享 CDN/云网络及本机 IP 已排除）:"
    printf '  %-3s %-25s %-5s %-8s %-8s %-7s %-9s %-5s %-6s %-5s %s\n' \
      "序号" "域名" "评分" "中位ms" "抖动ms" "失败率" "ASN" "同ASN" "TLS1.3" "证书" "H2"
    i=1
    for line in "${top_rows[@]}"; do
      IFS=$'\t' read -r score SNI_TEST_TLS_MS domain _ SNI_TEST_ASN SNI_TEST_SAME_ASN SNI_TEST_H2 _ SNI_TEST_JITTER_MS SNI_TEST_FAILURE_RATE SNI_TEST_TLS13 SNI_TEST_CERT_MATCH <<< "$line"
      printf '  %-3s %-25s %-5s %-8s %-8s %-7s %-9s %-5s %-6s %-5s %s\n' \
        "$i" "$domain" "$score" "$SNI_TEST_TLS_MS" "$SNI_TEST_JITTER_MS" "${SNI_TEST_FAILURE_RATE}%" \
        "AS${SNI_TEST_ASN}" "$SNI_TEST_SAME_ASN" "$SNI_TEST_TLS13" "$SNI_TEST_CERT_MATCH" "$SNI_TEST_H2"
      i=$((i + 1))
    done
    echo "  m)  手动输入自定义 SNI（执行完全相同的严格校验）"
  else
    warn "默认候选池没有找到安全候选；不会偷偷使用任何公共默认 SNI"
    echo "只能手动输入一个自定义 SNI 并通过严格校验，或输入 q 终止安装。"
  fi

  while true; do
    if [ "${#top_rows[@]}" -gt 0 ]; then
      read -r -p "请选择 Reality SNI [1-${#top_rows[@]}/m，默认 1]: " choice
      choice="${choice:-1}"
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#top_rows[@]}" ]; then
        selected="${top_rows[$((choice - 1))]}"
        REALITY_SNI="$(printf '%s' "$selected" | cut -f3)"
        break
      fi
    else
      read -r -p "输入 m 手动检测，或 q 终止安装: " choice
    fi

    case "${choice,,}" in
      m)
        read -r -p "请输入自定义 Reality SNI（不含协议和端口）: " domain
        printf '  正在严格校验 %s ... ' "$(sanitize_sni "$domain")"
        if evaluate_reality_domain "$domain"; then
          REALITY_SNI="$SNI_TEST_DOMAIN"
          echo "通过  中位 ${SNI_TEST_TLS_MS} ms  抖动 ${SNI_TEST_JITTER_MS} ms  失败 ${SNI_TEST_FAILURE_RATE}%  AS${SNI_TEST_ASN}"
          break
        fi
        echo "未通过：$SNI_TEST_REASON"
        ;;
      q)
        err "未选择通过严格校验的 Reality SNI，安装已安全终止"
        return 1
        ;;
      *) warn "无效选择" ;;
    esac
  done

  info "已选择 Reality SNI / handshake target: $REALITY_SNI:443"
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
    echo
    warn "REALITY 会把未认证连接转发到 handshake target；DMIT 流量计费机器必须避开共享 CDN/云网络。"
    select_reality_sni || exit 1
  else
    REALITY_SNI=""
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
  [ "$(id -u)" = "0" ] || { err "请以 root 运行"; exit 1; }
  info "DMIT 专用 sing-box 安装脚本"
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
