#!/usr/bin/env bash
# lib/core.sh — 代理核心安装：Xray / sing-box / Hysteria2
# 每个 core 独立安装、独立 systemd 单元，互不干扰；--engine 决定节点写在哪个 core 里。

XRAY_DIR="/usr/local/share/xray"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_VERSION_DEFAULT="v26.3.27"

SBOX_DIR="/usr/local/share/sing-box"
SBOX_BIN="/usr/local/bin/sing-box"
SBOX_CONF="/etc/sing-box/config.json"
SBOX_VERSION_DEFAULT="v1.14.0"

HY2_DIR="/usr/local/share/hysteria"
HY2_BIN="/usr/local/bin/hysteria"
HY2_CONF="/etc/hysteria/config.yaml"
HY2_VERSION_DEFAULT="app/v2.6.2"

# ---------------------------------------------------------------- Xray
install_xray() {
  if [ -x "$XRAY_BIN" ] && [ -z "$FORCE_REINSTALL" ]; then
    ok "Xray 已存在: $("$XRAY_BIN" version 2>/dev/null | head -1)"
    return 0
  fi
  step "安装 Xray"
  need_cmd unzip >/dev/null 2>&1 || pkg_update unzip >/dev/null 2>&1
  local ver="$XRAY_VERSION"
  [ -z "$ver" ] || [ "$ver" = "latest" ] && ver="$(github_latest XTLS/Xray-core || echo "$XRAY_VERSION_DEFAULT")"
  local zip="/tmp/xray-${ver}.zip"
  local url="https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${ARCH_DEB}.zip"
  if [ -f /tmp/xray-offline.zip ]; then
    cp /tmp/xray-offline.zip "$zip"; log "使用离线包 /tmp/xray-offline.zip"
  else
    fetch "$url" "$zip" || die "Xray 下载失败（所有镜像均不可达）。可手动下载后放到 /tmp/xray-offline.zip 再运行。"
  fi
  mkdir -p "$XRAY_DIR" /usr/local/etc/xray
  unzip -o -q "$zip" -d "$XRAY_DIR"
  install -m 755 "$XRAY_DIR/xray" "$XRAY_BIN"
  # 地理数据（路由规则用），失败不致命
  fetch "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"  "$XRAY_DIR/geoip.dat"  || true
  fetch "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" "$XRAY_DIR/geosite.dat" || true
  cat >/etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  ok "Xray ${ver} 安装完成"
}

xray_conf_init() {
  mkdir -p /usr/local/etc/xray
  if [ -s "$XRAY_CONF" ]; then return 0; fi
  cat >"$XRAY_CONF" <<'EOF'
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIP" } },
    { "protocol": "blackhole", "tag": "blocked" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" }
    ]
  }
}
EOF
}

xray_conf_check() {
  "$XRAY_BIN" -test -config "$XRAY_CONF" >/tmp/xray-test.log 2>&1
}

# ---------------------------------------------------------------- sing-box
install_singbox() {
  if [ -x "$SBOX_BIN" ] && [ -z "$FORCE_REINSTALL" ]; then
    ok "sing-box 已存在: $("$SBOX_BIN" version 2>/dev/null | head -1 | awk '{print $3}')"
    return 0
  fi
  step "安装 sing-box"
  local ver="$SBOX_VERSION"
  [ -z "$ver" ] || [ "$ver" = "latest" ] && ver="$(github_latest SagerNet/sing-box || echo "$SBOX_VERSION_DEFAULT")"
  ver="${ver#v}"; local tag="v${ver}"
  local tgz="/tmp/singbox-${tag}.tar.gz"
  local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${ARCH_GO}.tar.gz"
  if [ -f /tmp/singbox-offline.tar.gz ]; then
    cp /tmp/singbox-offline.tar.gz "$tgz"; log "使用离线包 /tmp/singbox-offline.tar.gz"
  else
    fetch "$url" "$tgz" || die "sing-box 下载失败。可手动下载后放到 /tmp/singbox-offline.tar.gz 再运行。"
  fi
  mkdir -p "$SBOX_DIR" /etc/sing-box
  tar -xzf "$tgz" -C "$SBOX_DIR" --strip-components=1
  install -m 755 "$SBOX_DIR/sing-box" "$SBOX_BIN"
  cat >/etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE
NoNewPrivileges=true
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=3
LimitNPROC=10000
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  ok "sing-box ${tag} 安装完成"
}

sbox_conf_init() {
  mkdir -p /etc/sing-box
  if [ -s "$SBOX_CONF" ]; then return 0; fi
  cat >"$SBOX_CONF" <<'EOF'
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "block" }
    ]
  }
}
EOF
}

sbox_conf_check() {
  "$SBOX_BIN" check -c "$SBOX_CONF" >/tmp/singbox-check.log 2>&1
}

# ---------------------------------------------------------------- Hysteria2
install_hysteria() {
  if [ -x "$HY2_BIN" ] && [ -z "$FORCE_REINSTALL" ]; then
    ok "Hysteria2 已存在: $("$HY2_BIN" version 2>/dev/null | head -1 | grep -oE 'v[0-9.]+' | head -1)"
    return 0
  fi
  step "安装 Hysteria2"
  local ver="$HY2_VERSION"
  [ -z "$ver" ] || [ "$ver" = "latest" ] && ver="$(github_latest apernet/hysteria app/ || echo "$HY2_VERSION_DEFAULT")"
  local enc ver_part="${ver#app/}"
  enc="$(printf '%s' "$ver" | sed 's|/|%2F|g')"
  local url="https://github.com/apernet/hysteria/releases/download/${enc}/hysteria-linux-${ARCH_GO}"
  if [ -f /tmp/hysteria-offline ]; then
    install -m 755 /tmp/hysteria-offline "$HY2_BIN"; log "使用离线包 /tmp/hysteria-offline"
  else
    fetch "$url" "/tmp/hysteria-bin" || die "Hysteria2 下载失败。可手动下载后放到 /tmp/hysteria-offline 再运行。"
    install -m 755 /tmp/hysteria-bin "$HY2_BIN"
  fi
  mkdir -p /etc/hysteria
  "$HY2_BIN" version >/dev/null 2>&1 || chmod +x "$HY2_BIN"
  # 自签证书（EC，10 年）—— 客户端 insecure=1 即可，避免 ACME 因域名指向旧 IP 失败
  mkdir -p "$HY2_DIR"
  if [ ! -f "$HY2_DIR/selfsigned.crt" ]; then
    need_cmd openssl >/dev/null 2>&1 || pkg_update openssl >/dev/null 2>&1
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$HY2_DIR/selfsigned.key" -out "$HY2_DIR/selfsigned.crt" \
      -days 3650 -nodes -subj "/CN=www.bing.com" >/dev/null 2>&1
    chmod 600 "$HY2_DIR/selfsigned.key"
  fi
  cat >/etc/systemd/system/hysteria-server.service <<'EOF'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3
LimitNPROC=10000
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  ok "Hysteria2 ${ver_part} 安装完成"
}

hy2_conf_init() {
  mkdir -p /etc/hysteria
  if [ -s "$HY2_CONF" ]; then return 0; fi
  cat >"$HY2_CONF" <<EOF
listen: :10153
tls:
  cert: $HY2_DIR/selfsigned.crt
  key: $HY2_DIR/selfsigned.key
auth:
  type: password
  password: $(rand_pass 32)
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
bandwidth:
  up: 500 mbps
  down: 500 mbps
ignoreClientBandwidth: false
EOF
}

hy2_conf_check() {
  "$HY2_BIN" server -c "$HY2_CONF" -check >/tmp/hysteria-check.log 2>&1 || \
    "$HY2_BIN" server --config "$HY2_CONF" --validate >/tmp/hysteria-check.log 2>&1
}

# ---------------------------------------------------------------- 版本探测
github_latest() {
  local repo="$1" prefix="${2:-}" out
  out="$(curl -fsS --noproxy '*' --max-time 10 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)"
  [ -z "$out" ] && return 1
  printf '%s' "$out" | grep -oE '"tag_name": *"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"/\1/' | grep -E "^${prefix}[0-9]" || return 1
}
