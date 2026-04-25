#!/bin/sh
# optimize.sh
# Linux auto-detect BBR + network optimization script
# Supports: Debian/Ubuntu, CentOS/Rocky/Alma, Fedora, Alpine, and most systemd/OpenRC Linux systems.

set -u

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
RED="$(printf '\033[31m')"
RESET="$(printf '\033[0m')"

info() {
    printf "%s[INFO]%s %s\n" "$GREEN" "$RESET" "$*"
}

warn() {
    printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"
}

error() {
    printf "%s[ERROR]%s %s\n" "$RED" "$RESET" "$*"
}

trim() {
    printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

backup_file() {
    file="$1"
    if [ -f "$file" ]; then
        cp "$file" "$file.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
    fi
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
        *debian*|*ubuntu*)
            OS_FAMILY="debian"
            ;;
        *rhel*|*centos*|*rocky*|*almalinux*|*fedora*)
            OS_FAMILY="rhel"
            ;;
        *alpine*)
            OS_FAMILY="alpine"
            ;;
        *arch*)
            OS_FAMILY="arch"
            ;;
        *)
            OS_FAMILY="unknown"
            ;;
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

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --quiet --container 2>/dev/null; then
            IS_CONTAINER="1"
            return
        fi
    fi

    if grep -qaE 'docker|lxc|kubepods|containerd|podman|openvz' /proc/1/cgroup 2>/dev/null; then
        IS_CONTAINER="1"
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

install_pkg() {
    pkg="$1"

    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" >/dev/null 2>&1
            ;;
        dnf)
            dnf install -y "$pkg" >/dev/null 2>&1
            ;;
        yum)
            yum install -y "$pkg" >/dev/null 2>&1
            ;;
        apk)
            apk add --no-cache "$pkg" >/dev/null 2>&1
            ;;
        pacman)
            pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_tools() {
    info "检查必要命令..."

    if ! command -v sysctl >/dev/null 2>&1; then
        warn "未找到 sysctl，尝试自动安装。"
        case "$OS_FAMILY" in
            debian) install_pkg procps || true ;;
            rhel) install_pkg procps-ng || true ;;
            alpine) install_pkg procps || true ;;
            arch) install_pkg procps-ng || true ;;
            *) install_pkg procps || true ;;
        esac
    fi

    if ! command -v modprobe >/dev/null 2>&1; then
        warn "未找到 modprobe，尝试自动安装 kmod。"
        install_pkg kmod || true
    fi

    if ! command -v ss >/dev/null 2>&1; then
        warn "未找到 ss，尝试自动安装 iproute2。"
        case "$OS_FAMILY" in
            rhel) install_pkg iproute || true ;;
            *) install_pkg iproute2 || true ;;
        esac
    fi

    if ! command -v sysctl >/dev/null 2>&1; then
        error "sysctl 仍不可用，无法继续优化内核参数。"
        exit 1
    fi
}

kernel_ge_49() {
    major="$(uname -r | cut -d. -f1)"
    minor="$(uname -r | cut -d. -f2 | sed 's/[^0-9].*$//')"

    [ -z "$major" ] && major=0
    [ -z "$minor" ] && minor=0

    if [ "$major" -gt 4 ]; then
        return 0
    fi

    if [ "$major" -eq 4 ] && [ "$minor" -ge 9 ]; then
        return 0
    fi

    return 1
}

detect_bbr() {
    BBR_AVAILABLE="0"

    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi

    if [ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
        if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            BBR_AVAILABLE="1"
        fi
    fi
}

choose_qdisc() {
    QDISC=""

    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        QDISC="fq"
    elif sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1; then
        QDISC="fq_codel"
        warn "当前系统不支持 fq，已自动回退为 fq_codel。"
    else
        warn "当前系统无法设置 net.core.default_qdisc，可能是容器限制或内核不支持。"
    fi
}

write_sysctl_config() {
    SYSCTL_CONF="/etc/sysctl.d/99-bbr-optimize.conf"

    mkdir -p /etc/sysctl.d 2>/dev/null || true
    backup_file "$SYSCTL_CONF"

    info "写入内核网络优化配置：$SYSCTL_CONF"

    {
        echo "# 99-bbr-optimize.conf"
        echo "# Generated by optimize.sh"
        echo "# OS: $OS_NAME"
        echo

        echo "# BBR + queue discipline"
        if [ -n "$QDISC" ]; then
            echo "net.core.default_qdisc = $QDISC"
        fi

        if [ "$BBR_AVAILABLE" = "1" ]; then
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi

        echo
        echo "# TCP basic optimization"
        echo "net.ipv4.tcp_fastopen = 3"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        echo "net.ipv4.tcp_mtu_probing = 1"
        echo "net.ipv4.tcp_syncookies = 1"

        echo
        echo "# TCP keepalive"
        echo "net.ipv4.tcp_keepalive_time = 600"
        echo "net.ipv4.tcp_keepalive_intvl = 30"
        echo "net.ipv4.tcp_keepalive_probes = 5"

        echo
        echo "# Queue and backlog"
        echo "net.core.somaxconn = 65535"
        echo "net.core.netdev_max_backlog = 250000"
        echo "net.ipv4.tcp_max_syn_backlog = 65535"
        echo "net.ipv4.ip_local_port_range = 1024 65535"

        echo
        echo "# TIME_WAIT / FIN"
        echo "net.ipv4.tcp_fin_timeout = 15"
        echo "net.ipv4.tcp_max_tw_buckets = 2000000"

        echo
        echo "# Buffer size"
        echo "net.core.rmem_max = 67108864"
        echo "net.core.wmem_max = 67108864"
        echo "net.core.rmem_default = 262144"
        echo "net.core.wmem_default = 262144"
        echo "net.ipv4.tcp_rmem = 4096 87380 67108864"
        echo "net.ipv4.tcp_wmem = 4096 65536 67108864"

        echo
        echo "# File handles"
        echo "fs.file-max = 1048576"
    } > "$SYSCTL_CONF"
}

write_sysctl_conf_fallback() {
    # Some OpenRC or minimal systems may not load /etc/sysctl.d/*.conf automatically.
    # Add a marked block to /etc/sysctl.conf for better persistence.
    case "$OS_FAMILY:$INIT_SYSTEM" in
        alpine:*|*:openrc|unknown:*)
            SYSCTL_MAIN="/etc/sysctl.conf"
            backup_file "$SYSCTL_MAIN"

            tmp="/tmp/sysctl.conf.$$"
            if [ -f "$SYSCTL_MAIN" ]; then
                sed '/# BEGIN CHATGPT_BBR_OPTIMIZE/,/# END CHATGPT_BBR_OPTIMIZE/d' "$SYSCTL_MAIN" > "$tmp" 2>/dev/null || cp "$SYSCTL_MAIN" "$tmp"
            else
                : > "$tmp"
            fi

            {
                cat "$tmp"
                echo
                echo "# BEGIN CHATGPT_BBR_OPTIMIZE"
                cat /etc/sysctl.d/99-bbr-optimize.conf
                echo "# END CHATGPT_BBR_OPTIMIZE"
            } > "$SYSCTL_MAIN"

            rm -f "$tmp"
            info "已同步写入 $SYSCTL_MAIN，方便 OpenRC/精简系统重启后生效。"
            ;;
    esac
}

apply_sysctl_runtime() {
    file="$1"

    info "应用 sysctl 参数..."

    while IFS= read -r raw || [ -n "$raw" ]; do
        line="$(printf "%s" "$raw" | sed 's/#.*$//')"
        case "$line" in
            *"="*)
                key="$(trim "$(printf "%s" "$line" | cut -d= -f1)")"
                value="$(trim "$(printf "%s" "$line" | sed 's/^[^=]*=//')")"

                [ -z "$key" ] && continue
                [ -z "$value" ] && continue

                if ! sysctl -w "$key=$value" >/dev/null 2>&1; then
                    warn "当前环境无法应用：$key"
                fi
                ;;
        esac
    done < "$file"
}

optimize_limits() {
    info "优化文件句柄和进程限制..."

    mkdir -p /etc/security/limits.d 2>/dev/null || true

    cat > /etc/security/limits.d/99-system-optimize.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 1048576
root hard nproc 1048576
LIMITS

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d 2>/dev/null || true

        cat > /etc/systemd/system.conf.d/99-limits.conf <<'SYSTEMD'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
SYSTEMD

        cat > /etc/systemd/user.conf.d/99-limits.conf <<'SYSTEMD'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
SYSTEMD

        systemctl daemon-reexec >/dev/null 2>&1 || true
        systemctl enable systemd-sysctl >/dev/null 2>&1 || true
    else
        mkdir -p /etc/profile.d 2>/dev/null || true
        cat > /etc/profile.d/99-system-optimize.sh <<'PROFILE'
ulimit -n 1048576 2>/dev/null || true
PROFILE
    fi
}

restart_sysctl_service_if_possible() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl restart systemd-sysctl >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        if command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
            if rc-service --list 2>/dev/null | grep -qw sysctl; then
                rc-update add sysctl boot >/dev/null 2>&1 || true
                rc-service sysctl restart >/dev/null 2>&1 || true
            fi
            if rc-service --list 2>/dev/null | grep -qw procps; then
                rc-update add procps boot >/dev/null 2>&1 || true
                rc-service procps restart >/dev/null 2>&1 || true
            fi
        fi
    fi
}

show_status() {
    echo
    echo "================================================="
    echo " 当前系统与优化状态"
    echo "================================================="
    echo "系统：$OS_NAME"
    echo "系统族：$OS_FAMILY"
    echo "初始化系统：$INIT_SYSTEM"
    echo "内核：$(uname -r)"
    echo "包管理器：$PKG_MANAGER"

    if [ "$IS_CONTAINER" = "1" ]; then
        echo "虚拟化/容器：检测到容器环境，部分参数可能受宿主机限制"
    else
        echo "虚拟化/容器：未明显检测到容器限制"
    fi

    echo
    echo "可用拥塞控制算法："
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true

    echo
    echo "当前拥塞控制算法："
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true

    echo
    echo "当前默认队列算法："
    sysctl net.core.default_qdisc 2>/dev/null || true

    echo
    echo "文件句柄上限："
    sysctl fs.file-max 2>/dev/null || true

    echo
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        printf "%sBBR 已开启成功。%s\n" "$GREEN" "$RESET"
    else
        printf "%sBBR 未成功开启。可能原因：内核不支持、tcp_bbr 模块不可用、LXC/OpenVZ 容器限制。%s\n" "$RED" "$RESET"
    fi

    echo
    echo "复查命令："
    echo "sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc"
    echo "ss -tin | grep -i bbr"
    echo
    echo "提示：systemd 系统的文件句柄限制通常需要重新登录或重启服务后完全生效。"
}

main() {
    if [ "$(id -u)" != "0" ]; then
        error "请使用 root 用户运行，例如：sudo sh optimize.sh"
        exit 1
    fi

    echo "================================================="
    echo " Linux Auto Optimize + BBR Script"
    echo "================================================="

    detect_os
    detect_init
    detect_container
    detect_pkg_manager

    info "检测到系统：$OS_NAME"
    info "系统族：$OS_FAMILY，初始化系统：$INIT_SYSTEM，包管理器：$PKG_MANAGER"

    if [ "$IS_CONTAINER" = "1" ]; then
        warn "检测到容器环境，BBR 和部分 sysctl 参数可能无法由当前 VPS 修改。"
    fi

    if ! kernel_ge_49; then
        warn "当前内核版本低于 4.9，原生 BBR 可能不可用。"
    fi

    ensure_tools
    detect_bbr

    if [ "$BBR_AVAILABLE" = "1" ]; then
        info "检测到当前内核支持 BBR。"
    else
        warn "未检测到 BBR 支持，本脚本不会更换内核。KVM VPS 可考虑升级内核；容器环境需宿主机支持。"
    fi

    choose_qdisc
    write_sysctl_config
    write_sysctl_conf_fallback
    apply_sysctl_runtime /etc/sysctl.d/99-bbr-optimize.conf
    optimize_limits
    restart_sysctl_service_if_possible
    show_status

    echo "完成。"
}

main "$@"
