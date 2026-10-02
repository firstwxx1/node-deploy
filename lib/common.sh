#!/usr/bin/env bash
# lib/common.sh — 公共工具：日志、下载、随机凭据、系统探测
# 被 deploy.sh source，不单独执行。

NODE_DEPLOY_VERSION="1.0.0"
NODE_DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NODE_DEPLOY_ROOT

STATE_DIR="/etc/node-deploy"
LINK_FILE="$STATE_DIR/links.txt"
LINK_JSON="$STATE_DIR/links.json"
BACKUP_DIR="$STATE_DIR/backup"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"

C_RED='\033[31m'; C_GRN='\033[32m'; C_YEL='\033[33m'; C_BLU='\033[36m'; C_BLD='\033[1m'; C_OFF='\033[0m'

log()  { printf "${C_BLU}[node-deploy]${C_OFF} %s\n" "$*"; }
ok()   { printf "${C_GRN}[  ok  ]${C_OFF} %s\n" "$*"; }
warn() { printf "${C_YEL}[ warn ]${C_OFF} %s\n" "$*"; }
err()  { printf "${C_RED}[ fail ]${C_OFF} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf "\n${C_BLD}==> %s${C_OFF}\n" "$*"; }

require_root() {
  [ "$(id -u)" = "0" ] || die "需要 root 权限，请用 sudo 运行：sudo bash deploy.sh"
}

# ---------- 系统探测 ----------
detect_os() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"; OS_NAME="$PRETTY_NAME"; OS_VER="$VERSION_ID"
  else
    OS_ID="unknown"; OS_NAME="$(uname -s)"; OS_VER=""
  fi
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH_DEB="amd64"; ARCH_GO="amd64" ;;
    aarch64|arm64) ARCH_DEB="arm64"; ARCH_GO="arm64" ;;
    armv7l) ARCH_DEB="armhf"; ARCH_GO="armv7" ;;
    *) die "不支持的架构: $ARCH" ;;
  esac
  KERNEL_MAJ="$(uname -r | cut -d. -f1)"
  KERNEL_MIN="$(uname -r | cut -d. -f2)"
  INIT_SYS="systemd"
  command -v systemctl >/dev/null 2>&1 || INIT_SYS="other"
  # 主网卡
  MAIN_IFACE="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
  [ -n "$MAIN_IFACE" ] || MAIN_IFACE="eth0"
  # 公网 IP（多源兜底）
  PUBLIC_IP=""
  for u in https://api.ipify.org https://ifconfig.me/ip https://ip.sb; do
    PUBLIC_IP="$(curl -fsS --noproxy '*' --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$PUBLIC_IP" ] && break
  done
  [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
}

# ---------- 下载（多镜像回退） ----------
# fetch <url> <outfile>  — GitHub raw 常被重置，因此每个资源都给多个可达源。
MIRRORS="${MIRRORS:-https://gh-proxy.com/,https://ghfast.top/,https://gh.llkk.cc/}"
RAW_URL=""

fetch() {
  local url="$1" out="$2" m
  if curl -fsSL --noproxy '*' --connect-timeout 10 --max-time 300 --retry 2 -o "$out" "$url" 2>/dev/null \
     && [ -s "$out" ]; then
    return 0
  fi
  # 直连失败：套镜像前缀
  local IFS=','
  for m in $MIRRORS; do
    [ -z "$m" ] && continue
    if curl -fsSL --noproxy '*' --connect-timeout 10 --max-time 300 --retry 1 -o "$out" "${m}${url}" 2>/dev/null \
       && [ -s "$out" ]; then
      return 0
    fi
  done
  rm -f "$out"
  return 1
}

# ---------- 随机凭据 ----------
rand_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | \
      sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
  fi
}
rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
rand_pass() { tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "${1:-16}"; }

# JSON 字符串转义（凭据里带引号/反斜杠时别把 links.json 写坏）
jesc() {
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}

# URL 编码（链接里的 #label 用）
urlenc() {
  local s="$1" i c out=""
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# ---------- 端口 ----------
port_free() {
  local p="$1"
  ! ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$"
}
wait_port() {
  local p="$1" i
  for i in $(seq 1 30); do
    ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$" && return 0
    sleep 0.3
  done
  return 1
}

# ---------- JSON 辅助 ----------
have_jq() { command -v jq >/dev/null 2>&1; }
json_get() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2],''))" "$1" "$2" 2>/dev/null; }

# ---------- 备份 / 回滚 ----------
backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  cp -a "$f" "$BACKUP_DIR/$(basename "$f").$(date +%s).bak"
}

# ---------- 服务 ----------
svc_enable() {
  systemctl daemon-reload
  systemctl enable "$1" >/dev/null 2>&1
  systemctl restart "$1"
  sleep 1
  systemctl is-active --quiet "$1"
}
svc_status() {
  systemctl is-active "$1" 2>/dev/null || echo "inactive"
}

# ---------- 防火墙放通 ----------
open_port() {
  local p="$1" proto="${2:-tcp}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${p}/${proto}" >/dev/null 2>&1
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${p}/${proto}" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
  fi
  iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null
}

# 保存 iptables（端口跳跃需要持久化）
save_iptables() {
  mkdir -p /etc/iptables
  iptables-save  > /etc/iptables/rules.v4 2>/dev/null
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1
  fi
  # 开机自动恢复
  if [ -d /etc/network/if-pre-up.d ]; then
    cat >/etc/network/if-pre-up.d/node-deploy-iptables <<'EOF'
#!/bin/sh
[ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
exit 0
EOF
    chmod +x /etc/network/if-pre-up.d/node-deploy-iptables
  fi
  cat >/usr/local/sbin/node-deploy-iptables-restore <<'EOF'
#!/bin/sh
[ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
exit 0
EOF
  chmod +x /usr/local/sbin/node-deploy-iptables-restore
  if command -v systemctl >/dev/null 2>&1; then
    cat >/etc/systemd/system/node-deploy-iptables.service <<'EOF'
[Unit]
Description=Restore node-deploy iptables rules (UDP port hopping)
Before=network-pre.target
Wants=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/node-deploy-iptables-restore

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable node-deploy-iptables.service >/dev/null 2>&1
  fi
}

# ---------- 包管理 ----------
pkg_update() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq "$@" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$@" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$@" >/dev/null 2>&1
  else
    warn "未识别的包管理器，跳过安装: $*"
    return 1
  fi
}
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || pkg_update "$1"
  command -v "$1" >/dev/null 2>&1
}

# ---------- 记录已部署节点 ----------
# node_add <json-file-entry>
node_registry_add() {
  local entry="$1"
  if [ ! -s "$LINK_JSON" ]; then
    printf '{"nodes":[]}' > "$LINK_JSON"
  fi
  python3 - "$LINK_JSON" "$entry" <<'PY'
import json,sys
p,e = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(p))
except Exception:
    d = {"nodes": []}
d.setdefault("nodes", []).append(json.loads(e))
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2)
PY
}

print_banner() {
  printf "${C_BLD}
  _   _  ___  ____  _____    ____  _____ _     _____ _   _ 
 | \ | |/ _ \|  _ \| ____|  |  _ \| ____| |   | ____| \ | |
 |  \| | | | | | | |  _|    | | | |  _| | |   |  _| |  \| |
 | |\  | |_| | |_| | |___   | |_| | |___| |___| |___| |\  |
 |_| \_|\___/|____/|_____|  |____/|_____|_____|_____|_| \_|
${C_OFF}
       节点一键部署 v$NODE_DEPLOY_VERSION  ·  VLESS-Reality / Hysteria2 / SOCKS5
"
}
