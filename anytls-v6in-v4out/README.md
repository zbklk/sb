# AnyTLS：公网 IPv6 入站 → IPv4 出站

版本 **1.1.0**，固定使用官方 **sing-box 1.14.4**，支持 Debian/Ubuntu、systemd、Linux x86_64 / aarch64。安装器自动补充依赖，核心下载须通过内置 SHA-256 校验。

1.1.0 新增交互菜单、独立多节点、终端二维码和 PNG 二维码。已有 1.0.x 节点自动作为 `default` 使用，更新脚本即可管理，**无需重新安装，不会自动更改现有密码、证书或服务**。

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

## 已安装用户：更新管理脚本并进入菜单

以 root 执行：

```bash
curl -4fSL --retry 3 https://raw.githubusercontent.com/zbklk/sb/main/anytls-v6in-v4out/install.sh -o /root/anytls-v6v4-install.sh && bash /root/anytls-v6v4-install.sh menu
```

以后无参数运行 `bash /root/anytls-v6v4-install.sh` 就会显示菜单：

```text
1) 安装默认节点
2) 列出节点
3) 添加独立节点
4) 节点二维码/导入链接
5) 查看节点配置
6) 节点完整自检
7) 节点状态
8) 备份节点
9) 卸载指定节点
0) 退出
```

已有节点选菜单 **4**，节点 ID 直接回车使用 `default`。菜单 **3** 添加新节点，例如 `phone2`，可填写中文显示名称和新端口。每个节点独立运行 sing-box，拥有独立的端口、随机密码、证书、目录和 systemd 服务，会增加相应的内存和磁盘占用；添加或卸载一个节点不会重启其他节点。

## 扫码添加与二维码导出

菜单 **4** 提供两种明确区分的方式：

| 模式 | 客户端行为 | 使用条件 |
| --- | --- | --- |
| 1：严格证书校验 | URI 含 `insecure=0`，验证服务器证书 | 公开 CA 证书可直接导入；自签证书需客户端先显式信任 `server.crt` |
| 2：自签兼容扫码 | URI 含 `insecure=1`，关闭客户端 TLS 证书身份校验 | 方便支持 AnyTLS 的客户端扫码连接自签节点；不能验证服务器身份 |

标准 AnyTLS URI 只携带服务器、密码、SNI 等基本参数，**无法携带自签证书信任链**。因此不能承诺“严格模式扫描一次，就自动信任自签证书”。需要保留验证又想直接扫码时，请使用自有域名的公开 CA 证书模式。URI 格式见 [AnyTLS 官方规范](https://github.com/anytls/anytls-go/blob/main/docs/uri_scheme.md)。

无需菜单也能执行：

```bash
# 默认严格校验
bash /root/anytls-v6v4-install.sh qr --node default

# 明确选择自签兼容扫码，关闭此导入链接中的客户端证书校验
bash /root/anytls-v6v4-install.sh qr --node default --allow-insecure
```

首次生成二维码时会自动安装 `qrencode`。终端会同时显示链接和二维码，并保存 `/etc/anytls-v6v4/qr-strict.png` 或 `qr-insecure.png`，权限为 600；可以通过 SFTP 私下下载图片供手机扫描。生成兼容二维码不会更改服务端或原有 `client.json` 的校验设置。

手机客户端需要实际支持 AnyTLS 及其 URI 格式。二维码、PNG 和链接都包含密码，请勿公开分享。

## 后续增加节点

```bash
bash /root/anytls-v6v4-install.sh add --node phone2 --name '手机备用' --port 38446
bash /root/anytls-v6v4-install.sh list
bash /root/anytls-v6v4-install.sh qr --node phone2 --allow-insecure
bash /root/anytls-v6v4-install.sh test --node phone2
bash /root/anytls-v6v4-install.sh backup --node phone2
bash /root/anytls-v6v4-install.sh uninstall --node phone2 --yes
```

节点 ID 须为 1–20 位小写字母/数字/中间连字符；显示名称支持中文。`add` 不指定端口时，会建议高于已有节点端口的新端口；若被其他进程占用，安装会拒绝启动，请使用 `--port` 改选。每个新增端口都需要在 IPv6 防火墙和安全组放通 TCP。

| 节点 | 配置目录 | 服务 |
| --- | --- | --- |
| `default`（兼容原节点） | `/etc/anytls-v6v4/` | `anytls-v6v4.service` |
| `phone2` | `/etc/anytls-v6v4-phone2/` | `anytls-v6v4-phone2.service` |

核心分别位于 `/opt/anytls-v6v4[-节点ID]/sing-box`。新增节点也可使用 `--ipv6`、`--ipv4` 和证书参数；每个节点仍严格使用 IPv6 入站、IPv4 出站。这是在同一 VPS 上增加不同端口的节点，通常使用同一公网出口；如需增加其他 VPS，请到相应 VPS 运行脚本，本菜单不远程控制其他服务器。

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

公开 CA 证书模式会额外生成 `anytls://` 链接，包含 IPv6、端口、随机密码和 SNI，可通过菜单或 `qr` 生成严格模式二维码。脚本会通过真实握手验证证书链是否被核心信任；不能验证的证书会导致安装失败。不要把自签证书当作公开 CA 证书传入此模式。

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

Shadowrocket 等手机客户端须在当前版本中明确支持 AnyTLS；不要假定旧版支持。若客户端无法显式信任自签证书，可使用公开 CA 证书模式，或明确选择菜单中的自签兼容扫码。`client.json` 始终保留证书校验；兼容二维码只改变该导入链接的客户端校验选项。

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

以上未指定 `--node` 的示例均针对 `default`；其他节点的管理命令需添加 `--node ID`，证书路径、服务名和文件属组也需换成该节点对应名称。更换证书/密码后请重新生成二维码，旧图片中的凭据不会自动更新。

## 自动化验证

[GitHub Actions](../.github/workflows/anytls-v6v4.yml) 检查 Bash 语法、ShellCheck、证书名称预检、官方核心配置兼容性，以及真正的本地 AnyTLS 连接：IPv6 监听、IPv4 TCP/UDP 目标、双栈域名只查询 A、AAAA-only 失败、IPv6 TCP/UDP 字面量被拒绝、错误密码/不可信证书被拒绝。另验证旧节点路径兼容、多节点隔离、单节点卸载、菜单错误恢复、URI 转义，并用 `zbarimg` 独立解码严格/兼容两种 PNG 二维码，核对完整链接。在 Linux 上以独立非 root 账户实际启动生成的 systemd 服务，在完整服务限制下验证 IPv6 TLS 握手，覆盖 `AF_NETLINK` 初始化回归。测试使用临时回环套接字和临时服务，不部署到 VPS。

实际 VPS 部署仍需在你的服务器执行上述安装命令，并完成客户端公网 IPv6 实测。
