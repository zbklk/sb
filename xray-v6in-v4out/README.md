# Xray IPv6 入站 / IPv4 出站 — VLESS + REALITY + Vision（V2）

> 当前版本：**V2.1.2**（适配 Xray v26.10.21 暂存配置扩展名检查，显示真实校验错误）

使用 **VPS 的公网 IPv6 接收客户端连接**，代理出站**绑定 VPS 本机 IPv4**（支持 NAT 内网 IPv4 再经商家出口 NAT）。脚本适用于 Debian / Ubuntu + systemd。V2 新增**中文数字菜单、安装完成自动展示二维码、端口和 SNI 在线修改、重置密钥、备份/恢复、独立卸载**。

> **无需自己的域名、DNS A/AAAA 解析、TLS 证书或 TCP 80 端口。** 客户端可以直接填写 VPS 公网 IPv6；REALITY 的 SNI 是独立的真实 TLS 目标域名（默认 `www.microsoft.com`），不要解析到你的 VPS。若需要用自己的域名作为*客户端连接地址*，可另外添加 AAAA 记录，但不是必要条件。

## 工作原理

```text
客户端（必须能连接 IPv6）
  └─ IPv6 TCP → VPS 公网 IPv6:8443 → VLESS + REALITY + xtls-rprx-vision
                                           │
                                           └─ Xray Freedom + ForceIPv4
                                                sendThrough = 本机 IPv4
                                                  │
                                                  └─ IPv4 目标站（显示 VPS 公网 IPv4）
```

`sendThrough` 填写 VPS 网卡实际配置的本机 IPv4：如果 VPS 用 NAT，填写 `10.x.x.x` / `172.16–31.x.x` / `192.168.x.x` 等**内网地址**，不要填写商家共享的公网 IPv4。此方案不是 NAT64，无法访问只有 IPv6 地址、没有 IPv4 的目标。REALITY 未通过认证时的 `target` 回落连接、客户端自己的 DNS 等不属于 Freedom IPv4 出站策略的范围。

## 系统要求

- Debian / Ubuntu，具备 systemd、root 权限及 GitHub 网络访问能力。推荐 Debian 12 / Ubuntu 24.04。
- VPS 有绑定在本机网卡的**公网 IPv6**，且客户端网络能够连到该 IPv6。
- VPS 有**本机 IPv4**并能 IPv4 出站：`curl -4 https://api.ipify.org` 能获取公网地址。只有 IPv6、完全没有 IPv4 出口的 VPS 不适用。
- VPS 服务商安全组及本机防火墙允许你选择的 IPv6 TCP 监听端口，且该端口未被其它服务占用。
- 已运行 Xray 的 VPS 可以共用 Xray 可执行文件；本工具使用**独立**的 `xray-v6v4.service` 和配置目录，不替换已有 `/usr/local/etc/xray/config.json`。如果系统没有 Xray 核心，安装时调用官方 `XTLS/Xray-install` 安装。

## 快速开始（推荐交互方式）

先登录 VPS：

```bash
sudo -i
curl -fsSLo install.sh https://raw.githubusercontent.com/zbklk/sb/main/xray-v6in-v4out/install.sh
less install.sh             # 建议先核对脚本内容
bash install.sh             # 无参数进入中文菜单（SSH 交互终端）
```

也可直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zbklk/sb/main/xray-v6in-v4out/install.sh)
```

运行后会显示：

```text
======= Xray IPv6 入站 → IPv4 出站 V2.1.2 =======
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
```

首次安装可选择监听端口（默认 TCP `8443`）、SNI（默认 `www.microsoft.com`）；IPv6 及 IPv4 由脚本自动检测，也可手动输入本机地址。安装成功后自动显示**完整 VLESS 导入链接和 SSH 终端二维码**，可直接用 Shadowrocket、v2rayN、Karing 等支持 REALITY/Vision 的客户端导入。

二维码通过 Debian / Ubuntu 的 `qrencode` 软件包输出（终端 UTF8 二维码），安装时自动尝试安装；如果包管理器暂时不可用，会提示并继续输出节点链接。二维码需要**能正确显示 UTF-8 字符的 SSH 终端**；终端宽度不足或扫码软件不兼容时，可直接复制 VLESS 链接。

## 非交互一键部署及管理命令

```bash
# 按默认参数部署；无 TTY 时自动安装，有交互终端可加 install 显式安装
bash install.sh install

# 自定义端口、SNI、IPv6 和本机 NAT IPv4
bash install.sh install --port 443 --sni www.microsoft.com --ipv6 '2001:db8::10' --ipv4 '10.0.0.5'

# 查看节点信息（会显示二维码）
bash install.sh show
bash install.sh qr

# 在线修改端口和 SNI（检查新配置、备份、重启；失败则尝试回滚）
bash install.sh port --port 9443
bash install.sh sni --sni www.microsoft.com

# 重置 UUID/REALITY 私钥/Short ID（旧节点凭据立即失效，需确认）
bash install.sh rotate --yes

# 检查服务、查看 IPv4 公网出口、重启节点
bash install.sh status
bash install.sh restart

# 创建备份；恢复（仅适用于已安装的本项目节点）
bash install.sh backup
bash install.sh restore --file /root/xray-v6v4-backup-YYYYMMDD-HHMMSS-XXXXXX.tar.gz --yes

# 卸载本项目服务及配置，自动保留备份（不会卸载 Xray 核心）
bash install.sh uninstall --yes
```

以上带 `--yes` 的命令用于**明确确认**更换密钥、恢复备份或卸载，执行前请检查参数，切勿在不可信的脚本中使用。需要选择菜单可执行 `bash install.sh menu`。`--ipv6` 和 `--ipv4` 只用于**安装阶段**，修改已有 IPv6/IPv4 绑定不在 V2 管理菜单范围内。

已安装时再次执行 `install` **不会覆盖现有节点和密钥**。菜单修改端口/SNI 后将输出**更新过的客户端链接和二维码**；修改端口后需同步放通新端口；重新生成密钥后需要在所有客户端重新导入。

## 文件与权限

| 路径 | 作用 |
| --- | --- |
| `/etc/xray-v6v4/config.json` | 服务端 Xray 配置，包含 REALITY 私钥，`root:xray-v6v4` 权限 `640` |
| `/etc/xray-v6v4/client.txt` | 节点信息 / VLESS 链接，包含敏感客户端凭据，`600` |
| `/etc/systemd/system/xray-v6v4.service` | 独立的 systemd 服务 |
| `/root/xray-v6v4-backup-*.tar.gz` | 备份档案，`600`，**包含私钥** |

服务采用专用系统用户 `xray-v6v4` 运行。备份在修改端口、SNI、密钥、恢复和卸载前创建。**不要把真实 VPS 的配置、备份或节点链接推送到公开 GitHub 仓库**。

## 防火墙与安全组

脚本**不会**启用、更改或清空 UFW，以免造成 SSH 断联。请自行在云厂商控制台放行 IPv6 TCP `8443`（或设置的新端口）。如已开启 UFW，应先保证 SSH 端口开放，然后针对*真实 VPS IPv6* 放行，例如：

```bash
sudo grep '^IPV6=' /etc/default/ufw    # 期望 IPV6=yes
sudo ufw status verbose
sudo ufw allow in to YOUR_VPS_IPV6 port 8443 proto tcp
```

将 `YOUR_VPS_IPV6` 替换为真实地址。**不需要开放 80 端口**。IPv6 监听端口仍可能被扫描，不应视为隐藏端口。对外服务建议及时安装安全更新。

## 检查 IPv6 入站、IPv4 出站

```bash
sudo systemctl status xray-v6v4 --no-pager
sudo journalctl -u xray-v6v4 -n 50 --no-pager
ip -6 addr show scope global
ip -4 route get 1.1.1.1
curl -4 https://api.ipify.org
sudo ss -lntp '( sport = :8443 )'
```

连接后访问以下地址，并确保网页流量**确实经过节点代理**：

```text
https://api.ipify.org
```

应显示 VPS 的公网 IPv4（NAT VPS 通常是商家共享 IPv4）。IPv6 入站另用 `ss -ntp '( sport = :8443 )'` 检查已建立连接。客户端 DNS、分流、WebRTC 与此服务端配置属于不同层面的安全问题，需要另外排查。

### FAQ

**Q：需要提前给域名做 A/AAAA 解析吗？**

A：不需要，客户端地址直接填公网 IPv6 即可。SNI 仅作为 REALITY 的 TLS 目标，默认 `www.microsoft.com`；它不应指向你的 VPS。可用 `xray tls ping www.microsoft.com` 检查伪装目标对 TLS 1.3 的支持。

**Q：二维码不显示怎么办？**

A：在 VPS 执行 `apt-get update && apt-get install -y qrencode`，然后 `bash install.sh qr`。若客户端扫描不成功，复制脚本输出的 `vless://` 链接即可。

**Q：恢复备份支持跨 VPS 吗？**

A：V2 恢复只作用于**已安装的独立服务**，而且会检查备份中写入的 IPv6 和本机 IPv4 是否仍配置在当前机器上。跨 VPS 使用不同 IP 时不应直接恢复，建议新安装生成节点，或手动迁移并调整配置。恢复时只接受约定格式的配置/客户端文件备份，拒绝其他 tar 条目及符号链接。

**Q：脚本会修改现有 Xray/XHTTP/sing-box/防火墙吗？**

A：不会更改其它服务的配置或 UFW 规则；不过如果系统本来没有 Xray 二进制，调用官方安装器可能新增 `xray.service`，应在部署前评估现有环境和端口占用。脚本拒绝覆盖已有本项目安装，监听端口冲突会退出。

**Q：Xray 会把所有 IPv6 访问转成 IPv4 吗？**

A：不会。`ForceIPv4` 只约束这里的 Freedom 出站连接，IPv6-only 目的地可能不可达。REALITY 的 TLS 回落不是这条 Freedom 出站，不能据此保证整个 VPS 没有 IPv6 外连。

## 官方文档

- [Xray REALITY 参数](https://xtls.github.io/en/config/transports/reality.html)
- [Xray Freedom 出站](https://xtls.github.io/en/config/outbounds/freedom.html)
- [Xray Sockopt / ForceIPv4](https://xtls.github.io/en/config/transports/sockopt.html)
- [XTLS 官方安装脚本](https://github.com/XTLS/Xray-install)

本项目为自用部署辅助工具；请阅读代码后在自己的 VPS 上执行。尚未在所有商家的 VPS 网络中进行完整连接实测，使用前建议对现有业务配置作快照。


## V2.0.2 修复说明（2026-10-28）

- 修复 Debian/Ubuntu 的 `/etc/os-release` 中 `NAME="Debian GNU/Linux"` 覆盖脚本服务名 `xray-v6v4` 的问题，避免出现 `groupadd: 'Debian GNU/Linux' is not a valid group name` 和 `Invalid user/group name`。
- 系统发行版信息改为函数内部局部变量，保证 `xray-v6v4` 服务名及系统账户不受影响。
- 新增创建用户组、配置文件写入、服务文件加载的显式错误检查；失败时尽早停止，不继续使用错误账户名。
- 如果 V2.0.1 曾经安装失败并输出“已删除本次创建的服务及节点配置”，无需卸载 Xray-core。重新获取 V2.0.2，并从菜单选择 `1` 即可。
- 若已在服务器保存旧版本本地脚本，例如 `/root/xray-v6v4-install.sh`，请重新下载；重新执行旧的本地文件不会自动升级脚本。

## V2.0.1 修复说明（2026-10-28）

- 修复 Xray v26.10.21 的 `xray x25519` 输出 `Password (PublicKey):` 时，V2.0.0 报 `UUID/REALITY 密钥生成失败` 的问题。
- 同时兼容旧格式 `Private key: / Public key:`、中间版本 `PrivateKey: / Password:`，以及新格式 `PrivateKey: / Password (PublicKey):`。
- 检查 UUID 格式及 X25519 密钥是否是有效的 32 字节数据；不再只依赖固定标签字符串或输出行号。
- 如果原来停在密钥生成失败阶段，**重新运行菜单并选择 1 安装**即可；不需要卸载已安装的 Xray 核心，不会重设 VPS 网络。
- XTLS 官方安装器可能同时启用了默认的 `xray.service`；本项目的服务名是 `xray-v6v4.service`，两个服务相互独立。请勿在确认其他节点用途之前随意停用/删除 `xray.service`。

## V2.1.2 暂存配置扩展名修复（2026-10-28）

- **进一步确认根因**：Xray v26.10.21 的配置读取器会检查配置文件的实际扩展名，导致使用无后缀的 `.change.XXXXXXXX` 暂存文件时，即使设置 `-format json` 仍被拒绝。参见 XTLS/Xray-core Issue #7239 中公开的 v26.10.21 代码。
- 菜单 **12/13** 的配置暂存文件改为 `.change.XXXXXXXX.json`，菜单 **3/4/5** 的暂存文件改为 `.newconfig.XXXXXXXX.json`；所有配置更新仍先校验、备份再重启，失败不覆盖原节点。
- 校验失败时新增 Xray 原始错误信息显示，而不是只有“新配置未通过检查”；请分享前留意错误输出可能包含的地址等信息。
- **仅下载新脚本不更改 VPS 当前配置、UUID、REALITY 密钥或服务。** 再执行菜单 `13 → 2` 启用诊断日志；排查后 `13 → 1` 恢复 `warning`。
- GitHub 自动测试检查 Bash 语法和暂存配置的文件名。真实服务端仍以 Xray-core 在 VPS 上的校验结果为准。

## V2.1.1 热修复（2026-10-28）

- 修复菜单 **13** 日志切换中，选择 `warning` 或 `info` 都提示“新配置未通过 Xray 检查”的问题；菜单 **12** DNS 模式切换同理。
- 根因：配置暂存文件使用 `.change.XXXXXXXX` 等无 `.json` 后缀的文件名，Xray `run -test` 默认按照扩展名自动识别格式，无法识别。统一改为 `xray run -test -format json -config ...`。
- **后续更正**：v26.10.21 还有独立的实际扩展名检查，因此仅指定 `-format json` 仍不够；V2.1.2 已改为实际 `.json` 文件名。
- 修复仅改变**管理脚本的校验命令**，下载 V2.1.1 并不会自动重启节点、覆盖 UUID 或改动 `config.json`；需要通过菜单实际选择日志/DNS 选项，才会按原有备份、校验、重启流程修改。
- 如果先前的日志模式切换提示“保持原配置”，无需卸载节点；重新下载脚本后再选择 `13 → 2`，然后执行 `journalctl -u xray-v6v4 -f --no-pager` 观察手机连接，排查结束选择 `13 → 1` 恢复默认。
- 目前确认本机自检成功并不等于手机通过公网 IPv6 已完成 REALITY/VLESS 认证；日志里来源为 VPS 本机 IPv6 的 `accepted` 是自检，不能当作手机成功的证明。

## V2.1.0 稳定性和诊断升级（2026-10-28）

本版保留 **IPv6 入站、IPv4 Freedom 出站、VLESS + REALITY + Vision** 架构，不更改现有 UUID/密钥；升级管理脚本不会自动重建已有节点。新增以下 7 项：

1. **完整代理端到端自检**：临时启动 Xray SOCKS5 客户端，通过本机 IPv6 → 当前 REALITY 入站 → 绑定 IPv4 的 Freedom 出站访问 `https://api.ipify.org`，并与 VPS 直连公网 IPv4 结果对比。不会创建长期监听端口；测试进程退出后清理临时配置。**本机通过不代表外部移动网络也能访问 IPv6**。
2. **REALITY 目标预检**：修改 SNI 或首次安装时使用 OpenSSL 检查 TLS 1.3 和 ALPN。预检失败会警告，不能证明目标一定不兼容，也不会直接阻止安装。完整代理自检是更强的证据。
3. **一键诊断**：IPv4/IPv6 路由、IPv6 监听、DNS 查询、DoH 访问性、TLS 目标和完整代理出站；不自动更改或清空防火墙。
4. **DNS 模式**：可在默认 UDP DNS 与内置 DNS `https+local://...` DoH 模式之间切换。切换前先备份并检查配置，失败尝试回滚。**DoH 不保证一定优于 UDP，需考虑 VPS 到 DNS 的可达性。**
5. **安装可靠性**：关键步骤显式检查返回值、保留既有独立节点且不覆盖凭据；端到端自检未通过仍保留已启动节点，便于诊断；修正了之前易误判的成功提示。
6. **诊断日志模式**：提供 `info` + DNS 日志（地址脱敏）与默认 `warning` 模式，配置经校验后重启；日志可能仍含域名等敏感信息，分享前请检查。
7. **多 IPv6 地址选择**：首次交互安装时显示本机候选公网 IPv6；如果有多个，可手动选择。此功能不能替代外部 IPv6 TCP 端口可达性检测。

### V2.1 新菜单

```text
10) 一键诊断（包含 REALITY 完整代理自检）
11) 单独执行完整代理自检
12) 切换 DNS（UDP / DoH）
13) 设置诊断日志（info / warning）
```

对应命令行：`bash install.sh diagnose` 与 `bash install.sh selftest`。DNS 和日志修改请在可交互终端通过菜单执行。完整自检需要 VPS 已有 Xray 服务正常启动，且本机可以通过 IPv6 连接到其监听地址。其结果只能证明服务器本机端到端代理行为，外部手机是否有 IPv6、服务商端口是否放通，需要另外检查。

> **安全提醒：** 本机自检会把当前私有节点配置写入权限为 `700` 的临时目录，并在退出时删除。尽量不要将完整客户端链接或私钥粘贴到公开渠道。V2.1 还未在全部 VPS 商家环境进行真实部署验证，请先备份重要配置并在非关键节点上测试。
