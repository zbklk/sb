# sb：IPv6 入站 / IPv4 出站部署脚本

新增推荐方案：[AnyTLS 一键安装与完整说明](anytls-v6in-v4out/README.md)。独立部署 sing-box，客户端通过公网 IPv6 接入，代理到目标站点的 TCP/UDP 流量使用 IPv4。

| 方案 | 核心 | 部署说明 |
| --- | --- | --- |
| **AnyTLS + TLS** | 独立 sing-box 1.14.4 | [安装、证书、客户端和自检](anytls-v6in-v4out/README.md) |
| VLESS + REALITY | Xray | [原有方案](xray-v6in-v4out/README.md) |
| Shadowsocks 2022 | 复用 Xray | [原有方案](shadowsocks2022-v6in-v4out/README.md) |

## AnyTLS 快速安装

在有公网 IPv6 和可用 IPv4 出站的 Debian/Ubuntu VPS 上，先进入 root：

```bash
sudo -i
curl -4fSL --retry 3 https://raw.githubusercontent.com/zbklk/sb/main/anytls-v6in-v4out/install.sh -o /root/anytls-v6v4-install.sh && bash /root/anytls-v6v4-install.sh install
```

默认监听指定公网 IPv6 的 **38445/TCP**，自动检测地址、安装并校验官方核心、生成随机密码、自签证书与显式信任该证书的客户端配置。请在 VPS 安全组和主机防火墙放通该 IPv6 TCP 端口。客户端需要公网 IPv6 连通性并支持 AnyTLS。

已有域名和公开 CA 证书时，建议按[完整 README](anytls-v6in-v4out/README.md#使用域名证书)使用证书模式，可生成 `anytls://` 导入链接。自签模式使用生成的 `client.json`，保留 TLS 证书校验。

## 已安装节点：菜单、多节点与二维码

1.1.0 新增交互菜单、独立多节点、终端二维码和 PNG 导出。已有 1.0.x 节点自动识别为 `default`，更新管理脚本后直接进入菜单，无需重新安装节点：

```bash
curl -4fSL --retry 3 https://raw.githubusercontent.com/zbklk/sb/main/anytls-v6in-v4out/install.sh -o /root/anytls-v6v4-install.sh && bash /root/anytls-v6v4-install.sh menu
```

选 **4** 显示节点二维码；选 **3** 添加新节点。二维码可选严格证书校验，或明确选择关闭客户端证书校验的自签兼容模式。详见[扫码与多节点说明](anytls-v6in-v4out/README.md#扫码添加与二维码导出)。

AnyTLS 使用 TLS、分包和填充设计缓解流量特征问题，实际抗封锁效果取决于网络环境，不能保证不被识别或封锁。见 [AnyTLS 项目](https://github.com/anytls/anytls-go)。

本次新增的 `anytls-v6in-v4out/` 使用独立服务和目录。旧版根目录安装器仍保留，使用前请分别阅读对应脚本；本首页的网络约束仅描述上述独立方案。
