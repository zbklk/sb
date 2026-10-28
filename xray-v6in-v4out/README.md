# Xray VLESS + REALITY + XTLS Vision：IPv6 入站 / IPv4 出站

在 Debian / Ubuntu VPS 上，以**公网 IPv6 接收客户端 TCP 连接**，通过 VPS 的**本机 IPv4**访问目标站点。适用于独立 IPv4 + IPv6 VPS，以及 **NAT IPv4 + 公网 IPv6** VPS。

> **无需域名、无需 A/AAAA DNS 解析、无需自己申请 TLS 证书、无需开放 80 端口。** 客户端的服务器地址可以直接填写 VPS 公网 IPv6；REALITY 的 SNI（默认 `www.microsoft.com`）是独立的 TLS 目标域名，不应解析到你的 VPS。若需要使用自己的客户端连接域名，可额外把 AAAA 解析到 VPS 的 IPv6（非必需）。

## 工作原理

```text
客户端（需具备 IPv6 网络）
    │  IPv6 TCP / VLESS + REALITY + Vision
    ▼
VPS 公网 IPv6：[IPv6]:8443
    │  Xray Freedom (sendThrough = 本机 IPv4; sockopt.domainStrategy = ForceIPv4)
    ▼
VPS IPv4 出口（公网 IPv4 或 NAT 映射后的共享公网 IPv4）
    │
    ▼
IPv4 目标网站
```

**不是 NAT64。** 只有 IPv6、没有任何 IPv4 出站能力的 VPS 不能直接使用。仅支持 IPv6 的目标网站可能因强制 IPv4 而无法连接；部分 REALITY 非法握手的回落连接与普通 Freedom 出站是两条独立路径。

## 系统要求

- Debian 11/12/13 或 Ubuntu 22.04/24.04（systemd；建议 Debian 12 / Ubuntu 24.04）。脚本只针对 Debian 和 Ubuntu。
- VPS 有**实际分配到本机网卡的、全局可路由的 IPv6**，并且客户端所在网络可以访问该 IPv6。
- VPS 有本机 IPv4 地址及**真实可用的 IPv4 互联网出口**（可以是 NAT 私有 IPv4），可执行 `curl -4 https://api.ipify.org`。
- root 权限；VPS 安全组/云防火墙放行选定 TCP 端口；可访问 GitHub 安装 Xray。
- 如已安装 Xray，脚本使用现有的 `xray` 命令，不覆盖现有配置或默认服务；但现有版本必须支持 REALITY 相关字段。

## 一键安装

> 建议先阅读脚本再执行。脚本需要 root 权限，而且安装 Xray-core 时会下载并运行 [XTLS 官方安装脚本](https://github.com/XTLS/Xray-install)。

```bash
sudo -i
curl -fsSLo install.sh https://raw.githubusercontent.com/zbklk/sb/main/xray-v6in-v4out/install.sh
less install.sh
bash install.sh
```

想直接运行也可以：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zbklk/sb/main/xray-v6in-v4out/install.sh)
```

**默认配置**：自动选择公网 IPv6、自动识别 IPv4 路由源地址，监听 TCP `8443`，REALITY SNI/target 为 `www.microsoft.com:443`，使用独立的 `xray-v6v4.service`。

可指定参数：

```bash
# 固定使用指定的 VPS IPv6、本机 IPv4 和端口
bash install.sh install --ipv6 '2001:4860:1234::100' --ipv4 '10.0.0.5' --port 443 --sni www.microsoft.com

# 只修改默认端口和 SNI
bash install.sh --port 9443 --sni www.microsoft.com
```

> 上述 IPv6、IPv4 为演示值，须换成你实际网卡地址。`--ipv4` 必须是 **VPS 本机 IPv4**，NAT VPS 填私有 IPv4（如 `10.0.0.5`），不是商家共享的公网出口 IP。端口需未被其他进程占用。已安装时重复运行不会覆盖现有节点；需要变更参数时请备份、卸载后重新安装（客户端凭据会变更）。

## 获取节点连接信息

安装结束显示 VLESS 链接，保存在：

```bash
cat /etc/xray-v6v4/client.txt
bash install.sh show
```

客户端参数：

| 参数 | 值 |
| --- | --- |
| 协议 | VLESS |
| 地址 | VPS 公网 IPv6（纯 IPv6 地址；在 URI 中须带方括号） |
| 端口 | 8443（或自定义） |
| UUID | 安装时自动生成 |
| 网络 | TCP / RAW |
| TLS 安全 | REALITY |
| SNI | 默认 `www.microsoft.com` |
| Fingerprint | `chrome` |
| Public Key / PBK | `xray x25519` 输出的 `Password` |
| Short ID | 自动生成 |
| Flow | `xtls-rprx-vision` |

支持兼容 REALITY + Vision 的 Shadowrocket、v2rayN、Karing 等客户端。客户端应具备可到达 VPS IPv6 的网络。

## 网络和防火墙

脚本**不会自动开启、重置或改写 UFW**，以防误断 SSH。请在 VPS 商家控制台的安全组/防火墙开放 IPv6 入站 TCP 8443（或自定义端口）。若已使用 UFW：

```bash
# 检查 IPv6 支持及现有规则
sudo grep '^IPV6=' /etc/default/ufw
sudo ufw status verbose

# 可选择只放行 VPS 指定 IPv6 的对应入站端口（换成真实地址）
sudo ufw allow in to 2001:4860:1234::100 port 8443 proto tcp
```

在任何修改防火墙前，确保当前 SSH 端口已放行。无需开放 80 端口；安装不涉及 ACME 证书。

## 验证：IPv6 入站，IPv4 出站

在 VPS 上：

```bash
ip -6 addr show scope global
ip -4 addr show scope global
ip -4 route get 1.1.1.1
curl -4 https://api.ipify.org
sudo ss -lntp '( sport = :8443 )'
sudo systemctl status xray-v6v4 --no-pager
```

客户端成功连上后，检查 VPS 的 TCP 连接：

```bash
sudo ss -ntp '( sport = :8443 )'
```

应能看到客户端与 VPS 之间的 IPv6 TCP 连接。之后在客户端**通过节点代理**打开 `https://api.ipify.org`，应显示 VPS 的公网 IPv4（NAT VPS 为共享公网 IPv4）。在 Windows v2rayN 本地 SOCKS 端口为 10808 时：

```powershell
curl.exe --socks5-hostname 127.0.0.1:10808 https://api.ipify.org
```

注意：访问网站返回 IPv4 只是验证代理出站；还需通过 `ss` 或抓包同时验证真实入站走 IPv6。客户端自己的 DNS、直连分流规则和 WebRTC 等可能另有泄露路径，需要分别检查。

## 管理命令

```bash
bash install.sh status            # 查询服务状态
bash install.sh show              # 再次打印客户端链接
bash install.sh backup            # 备份到 /root，包含 REALITY 私钥
bash install.sh uninstall         # 自动备份后，移除该独立服务和配置
sudo journalctl -u xray-v6v4 -n 50 --no-pager
sudo systemctl restart xray-v6v4
```

安装文件：

- `/etc/xray-v6v4/config.json`：服务端配置（私钥，权限受限）。
- `/etc/xray-v6v4/client.txt`：客户端链接（包含 UUID/公钥/Short ID，权限 600）。
- `/etc/systemd/system/xray-v6v4.service`：本项目独立服务。

卸载仅处理以上项目，不会移除共享 Xray-core，也不会删除其他 Xray 节点。备份存储在 root 的 home 目录，**必须妥善保管**。

## 安全说明及限制

1. 使用 IPv6 入站并不会隐藏端口：端口仍可能被 IPv6 扫描。建议限制 SSH 来源、使用更新的 Xray-core、维护操作系统安全更新。
2. REALITY 不需要申请域名证书，但 `target` 必须是可达且兼容 TLS 1.3 的真实站点。可使用 `xray tls ping www.microsoft.com` 检查；不要随意把你自己的未配置站点作为 target。
3. 未通过 REALITY 验证的连接可回落转发至 `target`，可能被恶意利用。本脚本启用回落速率限制，但**并不保证完全阻断滥用**。
4. `ForceIPv4` + 本机 IPv4 `sendThrough` 只限制 **Freedom 代理出站**。它不会将 IPv6-only 目标“转换成 IPv4”；REALITY fallback、客户端自身 DNS 以及系统其他服务也不受这个 Freedom 规则约束。
5. 不会新增 DNS A/AAAA 记录，不会自动配置防火墙，也不会在已有安装上覆盖配置。脚本只提供 TCP VLESS/REALITY/Vision，不实现端口转发型的独立 UDP 入站。
6. 任何上传 GitHub 的代码都不应包含真实私钥和 UUID。运行时自动生成凭据，并仅保存在 VPS 上。

## 官方参考

- [Xray 配置：REALITY](https://xtls.github.io/en/config/transports/reality.html)
- [Xray 配置：Sockopt 与 ForceIPv4](https://xtls.github.io/en/config/transports/sockopt.html)
- [Xray 配置：Freedom](https://xtls.github.io/en/config/outbounds/freedom.html)
- [XTLS/Xray-install](https://github.com/XTLS/Xray-install)
