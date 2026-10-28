# AnyTLS：公网 IPv6 入站 → IPv4 出站

版本 **1.0.1**，固定使用官方 **sing-box 1.14.4**，支持 Debian/Ubuntu、systemd、Linux x86_64 / aarch64。安装器自动补充依赖，核心下载须通过内置 SHA-256 校验。

1.0.1 修复了 systemd 地址族白名单遗漏 `AF_NETLINK` 导致的 `initialize network: create netlink socket: address family not supported by protocol` 启动错误。1.0.0 若已自动回滚，重新下载本脚本并安装即可。启动失败时会先输出状态与 journal，并将诊断日志保存到 `/root/anytls-v6v4-failure-*.log`，再清理本次新建服务。

```text
支持 AnyTLS 的客户端（具有公网 IPv6 连通性）
    ↓ TLS / TCP，通过 VPS 的指定公网 IPv6
AnyTLS 入站 [VPS IPv6]:38445
    ↓ DNS over HTTPS 使用 IPv4；域名只解析 A 记录
绑定 VPS 本机 IPv4 的 direct 出站
    ↓ IPv4 TCP/UDP
目标网站
```

**IPv4-only 是严格限制：**使用 `ipv4_only`，直接请求 IPv6 目标会被路由规则拒绝；仅有 AAAA 记录的站点访问失败。客户端不要把目标域名预先解析为 IPv6，应交给服务端解析。服务器回复客户端的数据仍通过原 IPv6 连接返回，这是 IPv6 入站的正常行为。“IPv4 出站”指此代理服务连接目标站点与 DNS 上游的流量；服务器其他进程的网络配置不受影响。

AnyTLS 使用 TLS、分包与填充，旨在缓解嵌套 TLS 握手特征；仍可能受到 IP、SNI、流量分析或主动探测等因素影响。自签证书和高端口不等于普通网站伪装。见 [AnyTLS 官方项目](https://github.com/anytls/anytls-go)、[sing-box AnyTLS 入站](https://sing-box.sagernet.org/configuration/inbound/anytls/)。

## 一键安装

VPS 必须同时具有已配置到网卡的公网 IPv6、可访问公网的 IPv4。纯 IPv6 VPS 需要先有可用 IPv4 出口，本脚本不会自动创建 WARP/NAT64/代理链。客户端所在网络必须能到达 VPS 的公网 IPv6。

```bash
sudo -i
curl -4fSL --retry 3 https://raw.githubusercontent.com/zbklk/sb/main/anytls-v6in-v4out/install.sh -o /root/anytls-v6v4-install.sh && bash /root/anytls-v6v4-install.sh install
```

默认自动选择网卡上的公网 IPv6 和 IPv4 路由源地址，监听 **38445/TCP**。多地址服务器建议明确指定：

```bash
bash /root/anytls-v6v4-install.sh install \
  --ipv6 '你的VPS公网IPv6' \
  --ipv4 '你的VPS本机IPv4' \
  --port 38445
```

`--ipv4` 是网卡本机地址：NAT VPS 应填写内网 IPv4，而不是 NAT 后的共享公网 IPv4。脚本会核对地址是否属于本机、检查端口占用，并测试指定 IPv4 的公网连通性。

安装默认生成 32 字节随机密码、825 天有效的自签证书（SNI 为 `anytls.invalid`，无需注册该域名），以及**嵌入信任证书、`insecure: false`** 的 sing-box 客户端 JSON。安装阶段会校验服务端/客户端配置，并实际走完整代理链路检查公网 IPv4；失败会清理本次新建的 AnyTLS 服务。

## 使用域名证书

如果已有自有域名和公开 CA 签发的有效证书，使用以下参数安装；证书需包含该域名，`--cert` 提供完整链，私钥须无口令：

```bash
bash /root/anytls-v6v4-install.sh install \
  --port 443 \
  --server-name 'node.example.com' \
  --cert '/你的证书目录/fullchain.pem' \
  --key '/你的证书目录/privkey.pem'
```

`443` 是可选端口，必须未被其他服务占用。即使使用域名证书，生成的客户端服务器地址仍是 VPS IPv6，SNI/证书校验名称才是域名。脚本不申请 ACME 证书，不开放 80，不设置自动续期。若用 DNS 获取证书，公网入口域名可只设 AAAA；这里使用直接 IPv6 连接也无需客户端解析入口域名。

公开 CA 证书模式会额外生成 `anytls://` 链接，包含 IPv6、端口、随机密码和 SNI。脚本会通过真实握手验证证书链是否被核心信任；不能验证的证书会导致安装失败。不要把自签证书当作公开 CA 证书传入此模式。

## 防火墙与端口

在商家安全组和主机防火墙允许 **IPv6 TCP 38445**（或实际选择的端口）。AnyTLS 的客户端到服务器传输为 TCP；应用 UDP 通过隧道承载，无需开放相同的 UDP 入站端口。

脚本不会修改 UFW/nftables/iptables。若使用已启用且 `IPV6=yes` 的 UFW，可在确保 SSH 已放行后添加：

```bash
ufw allow proto tcp from ::/0 to any port 38445
ufw status verbose
```

IPv4 出站需允许目标业务流量和到 `1.1.1.1:443` 的 DNS over HTTPS。指定 IPv6 地址监听避免 `::` 通配监听在部分系统上接收 IPv4 的问题。

## 客户端导入

安装完成后运行：

```bash
bash /root/anytls-v6v4-install.sh show
```

| 文件/字段 | 用途 |
| --- | --- |
| `/etc/anytls-v6v4/client.json` | sing-box 完整客户端示例，含 AnyTLS 出站和本机 `127.0.0.1:1080` SOCKS/HTTP 入口 |
| `/etc/anytls-v6v4/client.txt` | 服务器 IPv6、端口、密码、SNI；公开 CA 模式还有导入 URI |
| `/etc/anytls-v6v4/server.crt` | 自签模式客户端需要显式信任的证书；通过可信渠道获取 |
| TLS 校验 | 保持启用；SNI 必须与证书对应 |

**自签模式：**将 `client.json` 私下复制到装有 sing-box 的客户端，运行 `sing-box run -c client.json`，再把应用代理指向本机 `127.0.0.1:1080`。也可以将其中的 AnyTLS 出站合入现有客户端配置。这个示例不会自动接管整个系统流量，也不是手机 TUN 的完整配置。

**公开 CA 证书模式：**使用支持 AnyTLS 的客户端导入 `anytls://` 链接，或手工填写 AnyTLS、VPS IPv6、端口、密码、SNI，保持证书校验启用。不同客户端对 URI 支持不同，以实际字段为准。

Shadowrocket 等手机客户端须在当前版本中明确支持 AnyTLS；不要假定旧版支持。若客户端无法显式信任自签证书，改用公开 CA 证书模式。自签模式不输出要求跳过证书校验的 URI。

完整 sing-box 示例在电脑运行后可测试：

```bash
curl --noproxy '' --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

结果应为 VPS 的公网 IPv4。手机端启用该节点并选择让测试请求走代理，再访问同一地址。公网 IPv6 不通的 Wi-Fi/移动网络无法连接此节点。

## 管理与自检

```bash
bash /root/anytls-v6v4-install.sh status
bash /root/anytls-v6v4-install.sh test
bash /root/anytls-v6v4-install.sh backup
journalctl -u anytls-v6v4 -n 60 --no-pager
ss -6 -lntp
```

`test` 临时启动仅监听本机随机端口的客户端，经 **SOCKS → AnyTLS IPv6 入站 → IPv4 出站** 访问 `api.ipify.org`，并与绑定 IPv4 的公网出口比对。它只能证明 VPS 本机链路可用，外部 IPv6 路由、安全组、客户端兼容性仍需从手机/其他网络实测。

服务以独立的 `anytls-v6v4` 系统账户运行；默认拒绝私网、回环、链路本地、CGNAT 与组播等目标。配置字段参见：[DNS/拨号字段](https://sing-box.sagernet.org/configuration/shared/dial/)、[路由动作](https://sing-box.sagernet.org/configuration/route/rule_action/)。

| 路径 | 用途 |
| --- | --- |
| `/opt/anytls-v6v4/sing-box` | 独立核心，不替换已有 sing-box/Xray |
| `/etc/anytls-v6v4/` | 配置、证书、私钥、客户端文件 |
| `/etc/systemd/system/anytls-v6v4.service` | 独立服务 |
| `/root/anytls-v6v4-backup-*.tar.gz` | 配置与服务备份，含密码和私钥；不含核心程序 |

已有目录/服务文件会使安装器拒绝覆盖。备份、客户端配置、URI 都含凭据，请勿提交到 GitHub 或公开截图。

## 证书续期与重装

`show` 会显示证书到期日。公开 CA 证书续期后，需要将新完整链与对应私钥复制到本服务（安装时是复制，不是软链接），并重启：

```bash
bash /root/anytls-v6v4-install.sh backup
install -o root -g anytls-v6v4 -m 640 /你的证书目录/fullchain.pem /etc/anytls-v6v4/server.crt
install -o root -g anytls-v6v4 -m 640 /你的证书目录/privkey.pem /etc/anytls-v6v4/server.key
/opt/anytls-v6v4/sing-box check -c /etc/anytls-v6v4/config.json
systemctl restart anytls-v6v4
bash /root/anytls-v6v4-install.sh test
```

自签证书更换后，客户端必须同步更新信任证书。需要重置密码/自签证书或调整安装参数时，先备份，再卸载重装并重新导入客户端；这会短暂中断此 AnyTLS 节点：

```bash
bash /root/anytls-v6v4-install.sh uninstall --yes
bash /root/anytls-v6v4-install.sh install
```

卸载前会自动备份，仅移除此 AnyTLS 的服务、配置与核心，保留系统账户和备份。现有 VLESS/SS2022 节点可继续使用。

## 自动化验证

[GitHub Actions](../.github/workflows/anytls-v6v4.yml) 检查 Bash 语法、ShellCheck、证书名称预检、官方核心配置兼容性，以及真正的本地 AnyTLS 连接：IPv6 监听、IPv4 TCP/UDP 目标、双栈域名只查询 A、AAAA-only 失败、IPv6 TCP/UDP 字面量被拒绝、错误密码/不可信证书被拒绝。另在 Linux 上以独立非 root 账户实际启动生成的 systemd 服务，在完整服务限制下验证 IPv6 TLS 握手，覆盖 `AF_NETLINK` 初始化回归。测试使用临时回环套接字和临时服务，不部署到 VPS。

实际 VPS 部署仍需在你的服务器执行上述安装命令，并完成客户端公网 IPv6 实测。
