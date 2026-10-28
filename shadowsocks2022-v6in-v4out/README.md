# Shadowsocks 2022：公网 IPv6 入站 → 绑定 IPv4 出站

> 版本 **V1.0.0** · 适用于 Debian/Ubuntu + systemd + 已安装的 Xray-core v26.10.21。与旧项目 xray-v6in-v4out 完全独立。

这个项目针对 **iOS Shadowrocket 2.2.92 和 Xray-core 26.10.21 的 VLESS + REALITY 握手兼容性问题**提供替代通道。使用 **Shadowsocks 2022 (2022-blake3-aes-256-gcm)**，不建立代理链路上的 TLS/REALITY 握手，不需要证书、SNI、域名或 X25519MLKEM768 客户端指纹兼容性。

**不是“绝对不握手”：**TCP 本身仍然需要三次握手；浏览器访问 HTTPS 网站时依然会在隧道内进行正常的 TLS 握手。SS2022 使用预共享密钥和加密会话数据，不具备 TLS 网站伪装能力。与旧 SS AEAD 相比，SS2022 具有完整的重放保护，但**不提供前向保密**。参见 [Shadowsocks SIP022 规范](https://shadowsocks.org/doc/sip022.html) 和 [Xray Shadowsocks 官方文档](https://xtls.github.io/en/config/inbounds/shadowsocks.html)。

## 网络结构

    iPhone Shadowrocket (SS2022)
            ↓  IPv6 TCP/UDP
    [2a12:bec0:16f:101::]:38444  (示例：当前 ByteVirt 节点地址)
            ↓
    Xray SS2022 inbound (独立 ss2022-v6v4.service)
            ↓  Freedom sendThrough: 本机 IPv4
    sockopt.domainStrategy: ForceIPv4
            ↓
    公网 IPv4 出站（示例：185.115.207.154）

默认 IPv6 监听端口 **38444/TCP + 38444/UDP**；原来的 VLESS REALITY 节点 **38443** 不受影响。

客户端必须能连公网 IPv6：若家庭 iStoreOS 关闭了 IPv6，IPv6-only 节点仍无法通过该 Wi-Fi 访问。代理服务器返回给客户端的响应自然使用 IPv6；只有**到目标网站的代理出站**强制使用 IPv4。仅有 AAAA 记录、没有 A 记录的目标可能访问失败。

## 一键安装（在已有 Xray VPS 上执行）

    sudo -i
    curl -fSL --retry 3 \
      https://raw.githubusercontent.com/zbklk/sb/main/shadowsocks2022-v6in-v4out/install.sh \
      -o /root/ss2022-v6v4-install.sh
    bash -n /root/ss2022-v6v4-install.sh
    bash /root/ss2022-v6v4-install.sh install

无需重新安装 Xray-core。脚本会自动检测 VPS 的全局公网 IPv6 和绑定本机网卡的 IPv4，生成 32 字节随机 PSK、独立 JSON 服务端配置和 Shadowrocket 可导入的 ss:// 链接。

若需要手动指定：

    bash /root/ss2022-v6v4-install.sh install \
      --port 38444 \
      --ipv6 '2a12:bec0:16f:101::' \
      --ipv4 '185.115.207.154'

**注意：**这里填写的是 *VPS 网卡上真实配置的本机 IPv4*。如果另一台 VPS 采用 NAT IPv4，必须填 NAT 内网 IP（如 10.x.x.x），而不是共享公网 IP。脚本会检查本机 IPv4 是否可访问公网。

如果已有本项目的 service/config，安装器会拒绝覆盖；不会覆盖 VLESS 的 UUID、REALITY 密钥、配置目录、服务单元，也不会修改防火墙或停用原服务。

## 开放端口

新节点必须在商家的安全组/防火墙放通 **IPv6 TCP/UDP 38444**。如果 UFW 已启用且支持 IPv6，在**确认 SSH 管理端口已放通**后：

    sudo grep '^IPV6=' /etc/default/ufw   # IPV6=yes
    sudo ufw allow 38444/tcp
    sudo ufw allow 38444/udp
    sudo ufw status verbose

**不需要开启 80/443；也不需要证书。** 如果只使用 HTTP/HTTPS TCP，也可先测试仅开放 TCP 38444，但 iOS 一些功能、DNS/语音/游戏的 UDP 代理可能受限。

## iOS Shadowrocket 导入

安装完成后会显示 ss:// 链接，若有 qrencode 还会显示二维码。可扫码或复制导入。手工配置时：

| 字段 | 值 |
| --- | --- |
| 协议 | Shadowsocks |
| 服务器 | VPS 公网 IPv6（无括号；例如 2a12:bec0:16f:101::） |
| 端口 | 38444 |
| 加密方式 | 2022-blake3-aes-256-gcm |
| 密码 / PSK | 脚本生成的随机 Base64 密钥（不可公开） |
| TLS / REALITY / SNI / Flow | **不需要，不要启用** |

SS2022 与传统 Shadowsocks 的密码含义不同：SS2022 要求**长度严格正确的 Base64 编码密钥**。不要手动用普通密码替换。请确认 Shadowrocket 的加密方式选项确实包含 2022-blake3-aes-256-gcm，若 UI 不支持不要退回旧 SS AEAD 协议而不评估风险。

导入后将全局路由切换为「代理」，仅使用手机 5G，访问 https://api.ipify.org ，结果应为 VPS 的公网 IPv4，例如 185.115.207.154。

## 诊断、备份和卸载

    bash /root/ss2022-v6v4-install.sh show      # ss:// 链接与二维码
    bash /root/ss2022-v6v4-install.sh status    # systemd 状态
    bash /root/ss2022-v6v4-install.sh test      # 本机完整 SS2022 → IPv4 代理自检
    bash /root/ss2022-v6v4-install.sh backup    # 备份配置（含密钥）
    bash /root/ss2022-v6v4-install.sh uninstall # 确认后卸载 SS2022，VLESS 不动

或者无参数运行交互菜单。

常用日志/监听检查：

    systemctl is-active ss2022-v6v4
    journalctl -u ss2022-v6v4 -n 70 --no-pager
    ss -lntup | grep 38444
    curl -4 https://api.ipify.org

安装时与 test 命令会临时启动本机 Xray SOCKS5 → SS2022 → IPv4 的完整 HTTPS 代理检测，验证目标网站的公网 IPv4 与 VPS 绑定 IPv4 的公网出口一致。**该自检只验证 VPS 本机链路，不证明手机从公网 IPv6 一定可达。**

遇到失败时先核对：手机网络支持 IPv6；IPv6 TCP/UDP 端口开放；Shadowrocket 加密方法和 PSK 完全对应；系统时间已同步（SS2022 具有 30 秒时间窗口检查）；VPS 本机 IPv4 正常。如果手机客户端仍失败，可临时启用服务日志 info 进行排查，注意日志中可能包含连接元数据。

## 安全与文件隔离

| 路径 | 用途 |
| --- | --- |
| /etc/ss2022-v6v4/config.json | 独立服务端配置，root:ss2022-v6v4 640 |
| /etc/ss2022-v6v4/client.txt | ss:// 客户端链接，root 600 |
| /etc/systemd/system/ss2022-v6v4.service | 独立 systemd 服务 |
| /root/ss2022-v6v4-backup-*.tar.gz | 手动或卸载前备份（包含共享密钥） |

- 只通过 **Xray 的 Shadowsocks 入站**接收加密代理流量，不启用无认证 SOCKS5 公网服务。
- 保留 Xray Freedom 的内建私有地址防护，不添加无条件 allow 规则。
- 不在 GitHub 仓库提交真实 PSK、二维码或任何包含凭据的客户端链接。
- SS2022 的流量不是正常 HTTPS 网站 TLS 流量，没有 REALITY 的伪装特性，可能受到网络识别或阻断。
- SS2022 是预共享密钥体系，不提供前向保密；必须随机生成密钥，泄漏后应重新部署或轮换。
- **终止旧节点**：只有 SS2022 在 5G 上实际测试成功后，才考虑停止原 xray-v6v4.service。默认不会执行该操作。

## 参考

- [Xray Shadowsocks 入站](https://xtls.github.io/en/config/inbounds/shadowsocks.html)
- [Xray Shadowsocks 出站](https://xtls.github.io/en/config/outbounds/shadowsocks.html)
- [Xray Freedom 出站与默认私有地址限制](https://xtls.github.io/en/config/outbounds/freedom.html)
- [Xray Sockopt / ForceIPv4](https://xtls.github.io/en/config/transports/sockopt.html)
- [Shadowsocks 2022 (SIP022)](https://shadowsocks.org/doc/sip022.html)

> 安装脚本在 GitHub Actions 中使用官方 Xray v26.10.21 做 JSON 兼容性校验，但真实可用性仍以你自己的 ByteVirt 服务器和手机测试为准。
