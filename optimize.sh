#!/bin/sh
# VPS Network Optimizer
# Conservative, adaptive Linux network tuning for common VPS workloads.
# Supports Debian/Ubuntu, RHEL-compatible, Fedora, Alpine and Arch Linux.
# POSIX sh compatible: dash / ash / bash.

set -u

SCRIPT_VERSION="2.0.0"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

CONFIG_FILE="/etc/sysctl.d/99-zz-vps-optimize.conf"
LEGACY_CONFIG="/etc/sysctl.d/99-bbr-optimize.conf"
LIMITS_FILE="/etc/security/limits.d/99-vps-optimize.conf"
SYSTEMD_SYSTEM_LIMITS="/etc/systemd/system.conf.d/99-vps-optimize.conf"
SYSTEMD_USER_LIMITS="/etc/systemd/user.conf.d/99-vps-optimize.conf"
PROFILE_FILE="/etc/profile.d/99-vps-optimize.sh"
STATE_DIR="/var/lib/vps-optimize"
BACKUP_DIR="$STATE_DIR/backups"

ACTION="apply"
PROFILE="auto"
BANDWIDTH_MBPS=""
RTT_MS=""
BUFFER_OVERRIDE_MIB=""
DRY_RUN="0"
NO_LIMITS="0"

GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
RED="$(printf '\033[31m')"
RESET="$(printf '\033[0m')"

info() { printf "%s[INFO]%s %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"; }
error() { printf "%s[ERROR]%s %s\n" "$RED" "$RESET" "$*" >&2; }

usage() {
    cat <<'USAGE'
VPS Network Optimizer 2.0

用法：
  sh optimize.sh [选项]

常用方式：
  sh optimize.sh
      自动识别内存和 CPU，使用适合大多数 VPS 的平衡配置。

  sh optimize.sh --bandwidth 1000 --rtt 180
      根据 iperf3 单流带宽（Mbps）和实际 RTT（ms）计算 TCP 缓冲区。

  sh optimize.sh --profile small
      强制使用小内存配置。

选项：
  --profile auto|small|balanced|performance
  --bandwidth N       iperf3 单流有效带宽，单位 Mbps
  --rtt N             实际使用路径的往返延迟，单位 ms
  --buffer-mib N      手动指定最大 socket/TCP 缓冲区，4-512 MiB
  --no-limits         不修改文件句柄限制
  --dry-run           仅显示将采用的配置，不写入系统
  --status            显示当前状态
  --restore           恢复最近一次运行前的配置
  -h, --help          显示帮助

说明：
  --bandwidth 和 --rtt 必须同时使用。
  本脚本不会更换内核，也不会强制修改容器宿主机参数。
USAGE
}

is_uint() {
    case "${1:-}" in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --profile)
                [ "$#" -ge 2 ] || { error "--profile 缺少参数"; exit 2; }
                PROFILE="$2"
                shift 2
                ;;
            --bandwidth)
                [ "$#" -ge 2 ] || { error "--bandwidth 缺少参数"; exit 2; }
                BANDWIDTH_MBPS="$2"
                shift 2
                ;;
            --rtt)
                [ "$#" -ge 2 ] || { error "--rtt 缺少参数"; exit 2; }
                RTT_MS="$2"
                shift 2
                ;;
            --buffer-mib)
                [ "$#" -ge 2 ] || { error "--buffer-mib 缺少参数"; exit 2; }
                BUFFER_OVERRIDE_MIB="$2"
                shift 2
                ;;
            --no-limits)
                NO_LIMITS="1"
                shift
                ;;
            --dry-run)
                DRY_RUN="1"
                shift
                ;;
            --status)
                ACTION="status"
                shift
                ;;
            --restore)
                ACTION="restore"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "未知参数：$1"
                usage
                exit 2
                ;;
        esac
    done

    case "$PROFILE" in
        auto|small|balanced|performance) : ;;
        *) error "无效 profile：$PROFILE"; exit 2 ;;
    esac

    if [ -n "$BANDWIDTH_MBPS" ] || [ -n "$RTT_MS" ]; then
        if [ -z "$BANDWIDTH_MBPS" ] || [ -z "$RTT_MS" ]; then
            error "--bandwidth 和 --rtt 必须同时使用。"
            exit 2
        fi
        is_uint "$BANDWIDTH_MBPS" || { error "带宽必须是正整数 Mbps。"; exit 2; }
        is_uint "$RTT_MS" || { error "RTT 必须是正整数 ms。"; exit 2; }
        [ "$BANDWIDTH_MBPS" -gt 0 ] || { error "带宽必须大于 0。"; exit 2; }
        [ "$RTT_MS" -gt 0 ] || { error "RTT 必须大于 0。"; exit 2; }
    fi

    if [ -n "$BUFFER_OVERRIDE_MIB" ]; then
        is_uint "$BUFFER_OVERRIDE_MIB" || { error "--buffer-mib 必须是整数。"; exit 2; }
        if [ "$BUFFER_OVERRIDE_MIB" -lt 4 ] || [ "$BUFFER_OVERRIDE_MIB" -gt 512 ]; then
            error "--buffer-mib 范围为 4-512 MiB。"
            exit 2
        fi
    fi
}

trim() {
    printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

detect_os() {
    OS_ID="unknown"
    OS_NAME="Unknown Linux"
    OS_LIKE=""
    OS_FAMILY="unknown"

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-${NAME:-Unknown Linux}}"
        OS_LIKE="${ID_LIKE:-}"
    fi

    case "$OS_ID $OS_LIKE" in
        *debian*|*ubuntu*) OS_FAMILY="debian" ;;
        *rhel*|*centos*|*rocky*|*almalinux*|*fedora*) OS_FAMILY="rhel" ;;
        *alpine*) OS_FAMILY="alpine" ;;
        *arch*) OS_FAMILY="arch" ;;
        *) OS_FAMILY="unknown" ;;
    esac
}

detect_init() {
    INIT_SYSTEM="unknown"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    fi
}

detect_container() {
    IS_CONTAINER="0"
    CONTAINER_TYPE="none"

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        detected="$(systemd-detect-virt --container 2>/dev/null || true)"
        if [ -n "$detected" ] && [ "$detected" != "none" ]; then
            IS_CONTAINER="1"
            CONTAINER_TYPE="$detected"
            return
        fi
    fi

    if grep -qaE 'docker|lxc|kubepods|containerd|podman|openvz' /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER="1"
        CONTAINER_TYPE="container"
    elif [ -f /.dockerenv ]; then
        IS_CONTAINER="1"
        CONTAINER_TYPE="docker"
    fi
}

detect_pkg_manager() {
    PKG_MANAGER="none"
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    fi
}

detect_resources() {
    MEM_KB="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    is_uint "$MEM_KB" || MEM_KB=0
    MEM_MB=$((MEM_KB / 1024))

    if command -v getconf >/dev/null 2>&1; then
        CPU_COUNT="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    else
        CPU_COUNT=""
    fi
    if ! is_uint "$CPU_COUNT" || [ "$CPU_COUNT" -lt 1 ]; then
        CPU_COUNT="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
    fi
    if ! is_uint "$CPU_COUNT" || [ "$CPU_COUNT" -lt 1 ]; then
        CPU_COUNT=1
    fi
}

APT_UPDATED="0"
install_pkg() {
    pkg="$1"
    [ "$DRY_RUN" = "0" ] || return 1

    case "$PKG_MANAGER" in
        apt)
            if [ "$APT_UPDATED" = "0" ]; then
                DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
                APT_UPDATED="1"
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" >/dev/null 2>&1
            ;;
        dnf) dnf install -y "$pkg" >/dev/null 2>&1 ;;
        yum) yum install -y "$pkg" >/dev/null 2>&1 ;;
        apk) apk add --no-cache "$pkg" >/dev/null 2>&1 ;;
        pacman) pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

ensure_tools() {
    if ! command -v sysctl >/dev/null 2>&1; then
        warn "未找到 sysctl，尝试安装。"
        case "$OS_FAMILY" in
            debian|alpine) install_pkg procps || true ;;
            rhel|arch) install_pkg procps-ng || true ;;
            *) install_pkg procps || true ;;
        esac
    fi

    if ! command -v modprobe >/dev/null 2>&1; then
        install_pkg kmod || true
    fi

    if ! command -v ss >/dev/null 2>&1; then
        case "$OS_FAMILY" in
            rhel) install_pkg iproute || true ;;
            *) install_pkg iproute2 || true ;;
        esac
    fi

    if ! command -v sysctl >/dev/null 2>&1; then
        error "sysctl 不可用，无法继续。"
        exit 1
    fi
}

kernel_version_ok() {
    major="$(uname -r | cut -d. -f1 | sed 's/[^0-9].*$//')"
    minor="$(uname -r | cut -d. -f2 | sed 's/[^0-9].*$//')"
    is_uint "$major" || major=0
    is_uint "$minor" || minor=0
    [ "$major" -gt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -ge 9 ]; }
}

detect_bbr() {
    BBR_AVAILABLE="0"
    if [ "$DRY_RUN" = "0" ] && command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi

    if [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ] && \
       grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        BBR_AVAILABLE="1"
    fi
}

choose_qdisc() {
    QDISC=""

    if [ "$DRY_RUN" = "1" ]; then
        QDISC="fq"
        return
    fi

    if command -v modprobe >/dev/null 2>&1; then
        modprobe sch_fq >/dev/null 2>&1 || true
    fi
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        QDISC="fq"
        return
    fi

    if command -v modprobe >/dev/null 2>&1; then
        modprobe sch_fq_codel >/dev/null 2>&1 || true
    fi
    if sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1; then
        QDISC="fq_codel"
        warn "内核不支持 fq，已回退到 fq_codel。"
        return
    fi

    warn "无法修改默认 qdisc；可能受容器权限或内核限制。"
}

select_profile() {
    EFFECTIVE_PROFILE="$PROFILE"
    if [ "$PROFILE" = "auto" ]; then
        if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -lt 768 ]; then
            EFFECTIVE_PROFILE="small"
        elif [ "$MEM_MB" -ge 4096 ] && [ "$CPU_COUNT" -ge 4 ]; then
            EFFECTIVE_PROFILE="performance"
        else
            EFFECTIVE_PROFILE="balanced"
        fi
    fi

    case "$EFFECTIVE_PROFILE" in
        small)
            BASE_BUFFER_MIB=16
            PROFILE_BUFFER_CAP_MIB=32
            SOMAXCONN=4096
            SYN_BACKLOG=4096
            NETDEV_BACKLOG=4096
            FILE_MAX=262144
            NOFILE_LIMIT=131072
            TCP_WMEM_DEFAULT=32768
            ;;
        balanced)
            BASE_BUFFER_MIB=32
            PROFILE_BUFFER_CAP_MIB=64
            SOMAXCONN=8192
            SYN_BACKLOG=8192
            if [ "$CPU_COUNT" -ge 2 ]; then NETDEV_BACKLOG=16384; else NETDEV_BACKLOG=8192; fi
            FILE_MAX=524288
            NOFILE_LIMIT=262144
            TCP_WMEM_DEFAULT=65536
            ;;
        performance)
            BASE_BUFFER_MIB=64
            PROFILE_BUFFER_CAP_MIB=128
            SOMAXCONN=16384
            SYN_BACKLOG=16384
            if [ "$CPU_COUNT" -ge 4 ]; then NETDEV_BACKLOG=32768; else NETDEV_BACKLOG=16384; fi
            FILE_MAX=1048576
            NOFILE_LIMIT=524288
            TCP_WMEM_DEFAULT=65536
            ;;
    esac

    # Memory safety cap. This limits the maximum per-socket ceiling, not an immediate allocation.
    if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -le 512 ]; then
        MEMORY_BUFFER_CAP_MIB=16
    elif [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -le 1024 ]; then
        MEMORY_BUFFER_CAP_MIB=32
    elif [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -le 2048 ]; then
        MEMORY_BUFFER_CAP_MIB=64
    else
        MEMORY_BUFFER_CAP_MIB=128
    fi

    BUFFER_CAP_MIB="$PROFILE_BUFFER_CAP_MIB"
    if [ "$MEMORY_BUFFER_CAP_MIB" -lt "$BUFFER_CAP_MIB" ]; then
        BUFFER_CAP_MIB="$MEMORY_BUFFER_CAP_MIB"
    fi
}

next_buffer_tier() {
    requested="$1"
    for tier in 4 8 16 32 64 128 256 512; do
        if [ "$requested" -le "$tier" ]; then
            printf "%s" "$tier"
            return
        fi
    done
    printf "512"
}

calculate_buffer() {
    BUFFER_SOURCE="profile default"
    BUFFER_MIB="$BASE_BUFFER_MIB"
    REQUIRED_BUFFER_MIB=""

    if [ -n "$BANDWIDTH_MBPS" ] && [ -n "$RTT_MS" ]; then
        # BDP bytes = Mbps * ms * 125. Use 2x BDP as a practical ceiling target.
        REQUIRED_BUFFER_MIB="$(awk -v bw="$BANDWIDTH_MBPS" -v rtt="$RTT_MS" 'BEGIN {
            bytes = bw * rtt * 250;
            mib = int((bytes + 1048575) / 1048576);
            if (mib < 4) mib = 4;
            printf "%d", mib;
        }')"
        BUFFER_MIB="$(next_buffer_tier "$REQUIRED_BUFFER_MIB")"
        BUFFER_SOURCE="bandwidth/RTT calculation"
    fi

    if [ -n "$BUFFER_OVERRIDE_MIB" ]; then
        BUFFER_MIB="$BUFFER_OVERRIDE_MIB"
        BUFFER_SOURCE="manual override"
    elif [ "$BUFFER_MIB" -gt "$BUFFER_CAP_MIB" ]; then
        warn "计算值 ${BUFFER_MIB} MiB 超过当前内存/配置档位的安全上限 ${BUFFER_CAP_MIB} MiB，已限制。"
        BUFFER_MIB="$BUFFER_CAP_MIB"
    fi

    BUFFER_BYTES=$((BUFFER_MIB * 1024 * 1024))
}

sysctl_exists() {
    key_path="$(printf "%s" "$1" | tr '.' '/')"
    [ -e "/proc/sys/$key_path" ]
}

emit_sysctl() {
    key="$1"
    value="$2"
    file="$3"
    if sysctl_exists "$key"; then
        printf "%s = %s\n" "$key" "$value" >> "$file"
    else
        warn "内核不存在参数，跳过：$key"
    fi
}

backup_one() {
    path="$1"
    rel="${path#/}"
    if [ -e "$path" ]; then
        mkdir -p "$RUN_BACKUP/$(dirname "$rel")"
        cp -p "$path" "$RUN_BACKUP/$rel"
        printf "%s|present\n" "$path" >> "$RUN_BACKUP/manifest"
    else
        printf "%s|absent\n" "$path" >> "$RUN_BACKUP/manifest"
    fi
}

snapshot_runtime_sysctls() {
    : > "$RUN_BACKUP/runtime-sysctl"
    for key in \
        net.core.default_qdisc \
        net.ipv4.tcp_congestion_control \
        net.ipv4.tcp_fastopen \
        net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_mtu_probing \
        net.ipv4.tcp_syncookies \
        net.ipv4.tcp_window_scaling \
        net.ipv4.tcp_moderate_rcvbuf \
        net.ipv4.tcp_keepalive_time \
        net.ipv4.tcp_keepalive_intvl \
        net.ipv4.tcp_keepalive_probes \
        net.ipv4.tcp_fin_timeout \
        net.core.somaxconn \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_max_syn_backlog \
        net.ipv4.ip_local_port_range \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        fs.file-max; do
        if sysctl_exists "$key"; then
            value="$(sysctl -n "$key" 2>/dev/null || true)"
            [ -n "$value" ] && printf "%s|%s\n" "$key" "$value" >> "$RUN_BACKUP/runtime-sysctl"
        fi
    done
}

create_backup() {
    timestamp="$(date +%Y%m%d-%H%M%S)"
    RUN_BACKUP="$BACKUP_DIR/${timestamp}-$$"
    mkdir -p "$RUN_BACKUP"
    : > "$RUN_BACKUP/manifest"

    backup_one "$CONFIG_FILE"
    backup_one "$LEGACY_CONFIG"
    backup_one "/etc/sysctl.conf"
    backup_one "$LIMITS_FILE"
    backup_one "$SYSTEMD_SYSTEM_LIMITS"
    backup_one "$SYSTEMD_USER_LIMITS"
    backup_one "$PROFILE_FILE"
    snapshot_runtime_sysctls

    printf "%s\n" "$SCRIPT_VERSION" > "$RUN_BACKUP/version"
    info "已备份原配置和运行时参数：$RUN_BACKUP"
}

remove_marked_block() {
    file="$1"
    begin="$2"
    end="$3"
    [ -f "$file" ] || return 0

    tmp="/tmp/vps-optimize.$$.tmp"
    sed "/$begin/,/$end/d" "$file" > "$tmp" 2>/dev/null || return 1
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

prepare_legacy_cleanup() {
    # Remove the legacy duplicate block created by the previous script.
    remove_marked_block "/etc/sysctl.conf" "# BEGIN CHATGPT_BBR_OPTIMIZE" "# END CHATGPT_BBR_OPTIMIZE" || true
    remove_marked_block "/etc/sysctl.conf" "# BEGIN VPS_NETWORK_OPTIMIZE" "# END VPS_NETWORK_OPTIMIZE" || true

    # A later, adaptive config replaces this fixed legacy file.
    rm -f "$LEGACY_CONFIG"
}

write_sysctl_config() {
    mkdir -p /etc/sysctl.d
    tmp="/tmp/vps-optimize.sysctl.$$"
    : > "$tmp"

    {
        echo "# VPS Network Optimizer $SCRIPT_VERSION"
        echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# OS: $OS_NAME"
        echo "# Profile: $EFFECTIVE_PROFILE"
        echo "# RAM: ${MEM_MB} MiB; CPU: $CPU_COUNT"
        echo "# Buffer: ${BUFFER_MIB} MiB ($BUFFER_SOURCE)"
        if [ -n "$BANDWIDTH_MBPS" ]; then
            echo "# Input: ${BANDWIDTH_MBPS} Mbps, RTT ${RTT_MS} ms, raw target ${REQUIRED_BUFFER_MIB} MiB"
        fi
        echo
    } >> "$tmp"

    if [ -n "$QDISC" ]; then
        emit_sysctl "net.core.default_qdisc" "$QDISC" "$tmp"
    fi
    if [ "$BBR_AVAILABLE" = "1" ]; then
        emit_sysctl "net.ipv4.tcp_congestion_control" "bbr" "$tmp"
    fi

    {
        echo
        echo "# TCP features"
    } >> "$tmp"
    emit_sysctl "net.ipv4.tcp_fastopen" "3" "$tmp"
    emit_sysctl "net.ipv4.tcp_slow_start_after_idle" "0" "$tmp"
    emit_sysctl "net.ipv4.tcp_mtu_probing" "1" "$tmp"
    emit_sysctl "net.ipv4.tcp_syncookies" "1" "$tmp"
    emit_sysctl "net.ipv4.tcp_window_scaling" "1" "$tmp"
    emit_sysctl "net.ipv4.tcp_moderate_rcvbuf" "1" "$tmp"

    {
        echo
        echo "# Keepalive and stale connection cleanup"
    } >> "$tmp"
    emit_sysctl "net.ipv4.tcp_keepalive_time" "600" "$tmp"
    emit_sysctl "net.ipv4.tcp_keepalive_intvl" "30" "$tmp"
    emit_sysctl "net.ipv4.tcp_keepalive_probes" "5" "$tmp"
    emit_sysctl "net.ipv4.tcp_fin_timeout" "30" "$tmp"

    {
        echo
        echo "# Connection queues: deliberately bounded for common VPS sizes"
    } >> "$tmp"
    emit_sysctl "net.core.somaxconn" "$SOMAXCONN" "$tmp"
    emit_sysctl "net.core.netdev_max_backlog" "$NETDEV_BACKLOG" "$tmp"
    emit_sysctl "net.ipv4.tcp_max_syn_backlog" "$SYN_BACKLOG" "$tmp"
    emit_sysctl "net.ipv4.ip_local_port_range" "10240 65535" "$tmp"

    {
        echo
        echo "# Socket/TCP buffer ceilings; TCP receive auto-tuning remains enabled"
    } >> "$tmp"
    emit_sysctl "net.core.rmem_max" "$BUFFER_BYTES" "$tmp"
    emit_sysctl "net.core.wmem_max" "$BUFFER_BYTES" "$tmp"
    emit_sysctl "net.ipv4.tcp_rmem" "4096 131072 $BUFFER_BYTES" "$tmp"
    emit_sysctl "net.ipv4.tcp_wmem" "4096 $TCP_WMEM_DEFAULT $BUFFER_BYTES" "$tmp"

    {
        echo
        echo "# File handle ceiling"
    } >> "$tmp"
    emit_sysctl "fs.file-max" "$FILE_MAX" "$tmp"

    mv "$tmp" "$CONFIG_FILE"
    chmod 0644 "$CONFIG_FILE"
    info "已写入：$CONFIG_FILE"
}

write_openrc_fallback() {
    case "$OS_FAMILY:$INIT_SYSTEM" in
        alpine:*|*:openrc|unknown:*)
            [ -f /etc/sysctl.conf ] || : > /etc/sysctl.conf
            {
                echo
                echo "# BEGIN VPS_NETWORK_OPTIMIZE"
                cat "$CONFIG_FILE"
                echo "# END VPS_NETWORK_OPTIMIZE"
            } >> /etc/sysctl.conf
            info "已同步到 /etc/sysctl.conf，确保 OpenRC/精简系统重启后加载。"
            ;;
    esac
}

apply_sysctl_file() {
    file="$1"
    FAILED_KEYS=0

    while IFS= read -r raw || [ -n "$raw" ]; do
        line="$(printf "%s" "$raw" | sed 's/#.*$//')"
        case "$line" in
            *"="*)
                key="$(trim "$(printf "%s" "$line" | cut -d= -f1)")"
                value="$(trim "$(printf "%s" "$line" | sed 's/^[^=]*=//')")"
                [ -n "$key" ] || continue
                [ -n "$value" ] || continue
                if ! sysctl -w "$key=$value" >/dev/null 2>&1; then
                    warn "无法应用：$key（可能受容器或内核权限限制）"
                    FAILED_KEYS=$((FAILED_KEYS + 1))
                fi
                ;;
        esac
    done < "$file"
}

write_limits() {
    [ "$NO_LIMITS" = "0" ] || { info "按要求跳过文件句柄限制。"; return; }

    mkdir -p /etc/security/limits.d
    cat > "$LIMITS_FILE" <<EOF_LIMITS
# VPS Network Optimizer $SCRIPT_VERSION
* soft nofile $NOFILE_LIMIT
* hard nofile $NOFILE_LIMIT
root soft nofile $NOFILE_LIMIT
root hard nofile $NOFILE_LIMIT
EOF_LIMITS
    chmod 0644 "$LIMITS_FILE"

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
        cat > "$SYSTEMD_SYSTEM_LIMITS" <<EOF_SYSTEMD
[Manager]
DefaultLimitNOFILE=$NOFILE_LIMIT
EOF_SYSTEMD
        cat > "$SYSTEMD_USER_LIMITS" <<EOF_SYSTEMD_USER
[Manager]
DefaultLimitNOFILE=$NOFILE_LIMIT
EOF_SYSTEMD_USER
        systemctl daemon-reexec >/dev/null 2>&1 || true
    else
        mkdir -p /etc/profile.d
        cat > "$PROFILE_FILE" <<EOF_PROFILE
# Applied to future interactive login shells.
ulimit -n $NOFILE_LIMIT 2>/dev/null || true
EOF_PROFILE
        chmod 0644 "$PROFILE_FILE"
    fi

    info "文件句柄上限设置为：$NOFILE_LIMIT（新登录/服务重启后完全生效）"
}

restart_persistence_service() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl restart systemd-sysctl >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        if command -v rc-update >/dev/null 2>&1; then
            if [ -x /etc/init.d/sysctl ]; then
                rc-update add sysctl boot >/dev/null 2>&1 || true
            elif [ -x /etc/init.d/procps ]; then
                rc-update add procps boot >/dev/null 2>&1 || true
            fi
        fi
    fi
}

show_plan() {
    echo
    echo "================================================="
    echo " VPS Network Optimizer $SCRIPT_VERSION - 配置计划"
    echo "================================================="
    echo "系统             : $OS_NAME"
    echo "内核             : $(uname -r)"
    echo "初始化系统       : $INIT_SYSTEM"
    echo "虚拟化/容器      : $CONTAINER_TYPE"
    echo "内存 / CPU       : ${MEM_MB} MiB / ${CPU_COUNT} vCPU"
    echo "配置档位         : $EFFECTIVE_PROFILE"
    echo "BBR 可用         : $BBR_AVAILABLE"
    echo "队列算法         : ${QDISC:-保持系统当前值}"
    echo "缓冲区上限       : ${BUFFER_MIB} MiB"
    echo "缓冲区来源       : $BUFFER_SOURCE"
    if [ -n "$REQUIRED_BUFFER_MIB" ]; then
        echo "BDP×2 原始需求   : ${REQUIRED_BUFFER_MIB} MiB"
    fi
    echo "somaxconn        : $SOMAXCONN"
    echo "SYN backlog      : $SYN_BACKLOG"
    echo "netdev backlog   : $NETDEV_BACKLOG"
    echo "文件句柄限制     : $NOFILE_LIMIT"
    echo "================================================="
}

show_status() {
    detect_os
    detect_init
    detect_container
    detect_resources

    echo "================================================="
    echo " VPS Network Optimizer - 当前状态"
    echo "================================================="
    echo "系统：$OS_NAME"
    echo "内核：$(uname -r)"
    echo "内存：${MEM_MB} MiB；CPU：${CPU_COUNT}"
    echo "容器：$CONTAINER_TYPE"
    echo

    for key in \
        net.ipv4.tcp_available_congestion_control \
        net.ipv4.tcp_congestion_control \
        net.core.default_qdisc \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.core.somaxconn \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_max_syn_backlog \
        fs.file-max; do
        sysctl "$key" 2>/dev/null || true
    done

    echo
    if [ -f "$CONFIG_FILE" ]; then
        echo "配置文件：$CONFIG_FILE"
        grep '^# Profile:\|^# Buffer:' "$CONFIG_FILE" 2>/dev/null || true
    else
        echo "未发现本脚本配置文件。"
    fi

    echo
    echo "活动 TCP 拥塞控制示例："
    if command -v ss >/dev/null 2>&1; then
        ss -tin 2>/dev/null | grep -m 5 -E 'bbr|cubic|reno' || echo "当前没有可显示的活动 TCP 连接。"
    else
        echo "ss 命令不可用。"
    fi
}

restore_latest() {
    if [ "$(id -u)" != "0" ]; then
        error "恢复配置需要 root 权限。"
        exit 1
    fi

    latest="$(ls -1dt "$BACKUP_DIR"/* 2>/dev/null | head -n 1 || true)"
    if [ -z "$latest" ] || [ ! -f "$latest/manifest" ]; then
        error "没有找到可恢复的备份。"
        exit 1
    fi

    info "正在恢复：$latest"
    while IFS='|' read -r path state; do
        [ -n "$path" ] || continue
        rel="${path#/}"
        if [ "$state" = "present" ]; then
            mkdir -p "$(dirname "$path")"
            cp -p "$latest/$rel" "$path"
        else
            rm -f "$path"
        fi
    done < "$latest/manifest"

    if command -v sysctl >/dev/null 2>&1; then
        if sysctl --system >/dev/null 2>&1; then
            :
        else
            [ -f /etc/sysctl.conf ] && sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true
        fi

        # Restore the exact pre-run runtime values as far as the current environment permits.
        if [ -f "$latest/runtime-sysctl" ]; then
            while IFS='|' read -r key value; do
                [ -n "$key" ] || continue
                sysctl -w "$key=$value" >/dev/null 2>&1 || true
            done < "$latest/runtime-sysctl"
        fi
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl daemon-reexec >/dev/null 2>&1 || true
        systemctl restart systemd-sysctl >/dev/null 2>&1 || true
    fi

    info "恢复完成。已恢复配置文件；个别运行时参数可能需要重启后完全回到系统默认值。"
}

main_apply() {
    if [ "$DRY_RUN" = "0" ] && [ "$(id -u)" != "0" ]; then
        error "请使用 root 用户运行，例如：sudo sh optimize.sh"
        exit 1
    fi

    detect_os
    detect_init
    detect_container
    detect_pkg_manager
    detect_resources

    if [ "$DRY_RUN" = "0" ]; then
        ensure_tools
    elif ! command -v sysctl >/dev/null 2>&1; then
        warn "dry-run：当前没有 sysctl，仅展示估算配置。"
    fi

    if ! kernel_version_ok; then
        warn "内核低于 4.9，BBR 很可能不可用。"
    fi

    detect_bbr
    select_profile
    calculate_buffer

    if [ "$DRY_RUN" = "1" ]; then
        choose_qdisc
        show_plan
        if [ "$IS_CONTAINER" = "1" ]; then
            warn "检测到容器环境；部分 sysctl/BBR 由宿主机控制，实际运行时会逐项尝试并跳过无权限参数。"
        fi
        info "dry-run 完成，未修改系统。"
        return
    fi

    # Backup before probing/applying qdisc so rollback can restore the exact prior runtime state.
    create_backup
    choose_qdisc
    show_plan

    if [ "$IS_CONTAINER" = "1" ]; then
        warn "检测到容器环境；部分 sysctl/BBR 由宿主机控制，脚本会逐项尝试并跳过无权限参数。"
    fi

    prepare_legacy_cleanup
    write_sysctl_config
    write_openrc_fallback
    apply_sysctl_file "$CONFIG_FILE"
    write_limits
    restart_persistence_service

    echo
    if [ "$BBR_AVAILABLE" = "1" ]; then
        current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
        if [ "$current_cc" = "bbr" ]; then
            info "BBR 已启用。"
        else
            warn "检测到 BBR，但当前未成功切换；请检查容器/内核权限。"
        fi
    else
        warn "当前内核没有 BBR，已保留原拥塞控制算法，其余优化仍已应用。"
    fi

    if [ "${FAILED_KEYS:-0}" -gt 0 ]; then
        warn "有 $FAILED_KEYS 个参数无法在当前环境应用。"
    fi

    info "优化完成。建议重启代理服务；无需强制重启 VPS。"
    echo "检查命令：sh $0 --status"
    echo "回滚命令：sh $0 --restore"
}

main() {
    parse_args "$@"
    case "$ACTION" in
        status) show_status ;;
        restore) restore_latest ;;
        apply) main_apply ;;
    esac
}

main "$@"
