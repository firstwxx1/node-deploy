# node-deploy

单台 VPS 的代理节点一键部署脚本。跑完直接拿到可用链接、订阅和客户端配置。

一套脚本覆盖三类协议 + 系统调优：

| 组件 | 实现 | 默认 |
|---|---|---|
| VLESS-Reality | XTLS-Vision 流控，握手像真实 TLS，无自签证书特征 | TCP/443，SNI `www.cloudflare.com` |
| Hysteria2 | UDP/QUIC + salamander 混淆 + 端口跳跃 | UDP/10153，跳 `20000-40000` |
| SOCKS5 | danted + PAM 系统账号，独立于代理核心 | TCP/1080 |
| 系统调优 | BBR + fq + 16MB 缓冲 + TFO + MTU 探测 + conntrack 扩容 | 自动 |

---

## 一键部署

### 方式 A — 在 VPS 上直接跑（推荐）

```bash
git clone --depth 1 https://github.com/firstwxx1/node-deploy.git /tmp/nd \
  && sudo bash /tmp/nd/deploy.sh --yes
```

### 方式 B — 只有 curl 的裸机

```bash
# raw.githubusercontent 可达时
curl -fsSL https://github.com/firstwxx1/node-deploy/raw/main/bootstrap.sh | sudo bash

# raw 被重置时的稳妥版（走 codeload）
curl -fsSL https://codeload.github.com/firstwxx1/node-deploy/tar.gz/refs/heads/main -o /tmp/nd.tgz \
  && mkdir -p /tmp/nd && tar -xzf /tmp/nd.tgz -C /tmp/nd --strip-components=1 \
  && sudo bash /tmp/nd/deploy.sh --yes
```

`bootstrap.sh` 会依次尝试 git clone → 直连源码包 → gh-proxy / ghfast / gh.llkk 镜像，任一成功即继续。

### 方式 C — 从本机（Windows / Linux / mac）远程推

```bat
bootstrap.bat          :: Windows：双击，填 IP 和密码
```

```bash
# Linux / mac
bash bootstrap.sh --host root:密码@1.2.3.4 --profile all --port 443

# 批量：改好 servers.json 后
python tools/deploy_remote.py --servers servers.json --parallel 4
```

工具会把整个目录打包上传，远端不需要 git，也不需要能访问 GitHub（核心二进制可用 `--offline-xray` / `--offline-hy2` 从本地带过去）。

---

## 参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `--profile` | `all` / `vless` / `hy2` / `socks5` / `tune` | `all` |
| `--engine` | `xray` / `singbox` | `xray` |
| `--port` | VLESS 监听端口；被 nginx 占用时自动改 8443 | `443` |
| `--sni` | Reality 伪装域名 | `www.cloudflare.com` |
| `--uuid` `--sid` | 手动指定凭据 | 随机 |
| `--nginx-split` | 443 已被网站占用时，nginx 按 SNI 分流复用 443 | 关 |
| `--hy2-port` | Hysteria2 端口 | `10153` |
| `--hy2-hop` | 端口跳跃区间，`none` 关闭 | `20000-40000` |
| `--hy2-auth` `--hy2-obfs` | HY2 密码 / salamander 混淆密码 | 随机 32 位 |
| `--hy2-mode` | `standalone`（独立进程）/`core`（跑在引擎内） | `standalone` |
| `--socks-port` `--socks-user` `--socks-pass` | SOCKS5 三件套 | `1080` / `node` / 随机 |
| `--no-hy2` `--no-socks` `--no-tune` | 关掉对应模块 | — |
| `--qr` | 终端打印二维码（需 `apt install qrencode`） | 关 |
| `--core-version` | 锁定核心版本 | latest |
| `--list` `--status` `--del TAG` `--uninstall` | 管理子命令 | — |

**示例**

```bash
# 全套，VLESS 走 443
sudo bash deploy.sh --profile all --port 443 --sni www.cloudflare.com

# 只上 VLESS，用 sing-box 核心，端口 25774
sudo bash deploy.sh --profile vless --engine singbox --port 25774 --sni itunes.apple.com

# 只上 Hysteria2，带端口跳跃
sudo bash deploy.sh --profile hy2 --hy2-port 10153 --hy2-hop 20000-40000

# 443 已经跑了网站，复用它
sudo bash deploy.sh --profile vless --port 443 --nginx-split --sni daili.example.com

# 只做系统调优，不动任何节点
sudo bash deploy.sh --tune
```

---

## 部署后

产物都在 `/etc/node-deploy/`：

```
links.txt              纯链接，一行一个
sub.txt                base64 订阅内容（可直接挂成订阅地址）
client-singbox.json    sing-box 客户端配置（selector + 全部 outbound）
client-clash.yaml      Clash Meta 配置（proxy / proxy-group / rule）
links.json             结构化节点信息，脚本自己维护
backup/                每次写配置前的备份，失败自动回滚
```

终端收尾会直接打印全部链接：

```
vless://1a1afe94-...@1.2.3.4:443?encryption=none&security=reality&flow=xtls-rprx-vision&type=tcp&sni=www.cloudflare.com&fp=chrome&pbk=...&sid=...#1-2-3-4-VLESS-443
hysteria2://Ab3x...@1.2.3.4:10153?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=...&mport=20000-40000#1-2-3-4-Hy2
socks5://node:xxxx@1.2.3.4:1080#1-2-3-4-SOCKS5
```

远程部署时，链接同时拉回本机 `links/<ip>.txt`，多台汇总到 `links/all-links.txt` 和 `links/all-sub.txt`。

---

## 和 NodePanel 联动

部署完直接写回面板的 `nodes.json`，面板立刻能管理和测速：

```bash
python tools/deploy_remote.py --servers servers.json \
  --panel ../nodepanel/data/nodes.json
```

新机器会自动补 server 条目，节点按 `label` 去重后追加。

---

## 目录结构

```
node-deploy/
├── deploy.sh              主脚本：参数解析 + 部署编排 + 管理子命令
├── bootstrap.sh           一键入口（远端自部署 / 本机远程推）
├── bootstrap.bat          Windows 双击部署
├── lib/
│   ├── common.sh          日志、下载（多镜像回退）、随机凭据、iptables 持久化
│   ├── core.sh            Xray / sing-box / Hysteria2 安装与 systemd 单元
│   ├── tune.sh            BBR 与 sysctl 网络栈调优、fd 限制、网卡队列
│   ├── node_xray.sh       Xray 入站写入（VLESS-Reality / HY2）
│   ├── node_singbox.sh    sing-box 入站写入（VLESS / HY2 / SOCKS）
│   ├── hy2_standalone.sh  独立 HY2 服务端 + UDP 端口跳跃
│   ├── socks5.sh          danted + PAM
│   ├── nginx_split.sh     443 SNI 分流复用
│   └── links.sh           链接 / 订阅 / 客户端配置生成
├── tools/
│   └── deploy_remote.py   本机批量远程部署（paramiko，多线程）
├── servers.example.json   批量列表模板
├── config.env.example     默认参数模板
└── README.md
```

---

## 关键实现说明

**Reality 密钥对** — `xray x25519` / `sing-box generate reality-keypair` 现生成，私钥进服务端配置，公钥进链接。每次部署都是新密钥，不做复用。

**端口跳跃** — 服务端只监听单端口，`iptables -t nat` 把整个 UDP 段 REDIRECT 过去，客户端配 `mport` 定期换源端口。规则写进 `/etc/iptables/rules.v4` 并挂开机恢复，重启不丢。

**SNI 分流** — nginx 占 443 开 `ssl_preread`，命中代理域名转 `127.0.0.1:10444`，其余回落到迁到 `10443` 的原网站。Debian 官方 nginx 缺 stream 模块时会自动补 `libnginx-mod-stream`。

**写操作安全** — 每次改配置都是：备份 → `xray -test` / `sing-box check` 校验 → restart → 失败自动回滚到上一份。核心挂了 SOCKS5 还活着，机器不会失联。

**调优内容** — `fq` + `bbr`，`rmem/wmem` 16MB，`tcp_slow_start_after_idle=0`（代理长连接反复 idle 这条最关键），`tcp_mtu_probing=1`（路径有小 MTU 中转时避免黑洞），`tcp_fastopen=3`，conntrack 表扩到 100 万（UDP 协议连接量大）。内核 < 4.9 无 BBR 时，Debian/Ubuntu 自动装 XanMod，RHEL 系走 ELRepo kernel-ml。

---

## 排错

| 现象 | 原因与处理 |
|---|---|
| `Xray 下载失败（所有镜像均不可达）` | 手动下载 `Xray-linux-64.zip` 放到 `/tmp/xray-offline.zip` 重跑；或用 `--offline-xray` 从本机带过去。也可 `export MIRRORS=https://gh-proxy.com/` |
| Reality 连不上 | 伪装域名必须是该机**能直连的真实 HTTPS 站点**。换 `--sni` 重试，避开被墙域名 |
| 443 起不来 | 有网站占着：加 `--nginx-split`，或换 `--port 8443` |
| Hysteria2 连不上 | 防火墙挡 UDP。云厂商安全组也要放行 UDP 段；`--hy2-hop none` 排除跳跃规则问题 |
| HY2 证书警告 | 用的是自签证书，客户端必须开 `insecure=1`（链接里已带） |
| danted 认证失败 | 缺 `/etc/pam.d/danted`，脚本会自动补；仍未生效看 `/var/log/danted.log` |
| `tcp_congestion_control = cubic` | 内核无 BBR。OpenVZ/LXC 容器无法自己开，需换 KVM 或让宿主机开 |
| 速度没变化 | 瓶颈常在客户端本地国际出口，不在节点。先 `--tune`，再用两台机器对穿测（server-to-server），能排除本地链路干扰 |

---

## 管理

```bash
sudo bash deploy.sh --list            # 重新导出全部链接
sudo bash deploy.sh --status          # 服务 + 调优 + 监听端口
sudo bash deploy.sh --del vless-reality-443   # 删掉某个入站
sudo bash deploy.sh --tune            # 只对已有机器做系统调优
sudo bash deploy.sh --uninstall       # 停核心服务（配置和备份保留）
```
