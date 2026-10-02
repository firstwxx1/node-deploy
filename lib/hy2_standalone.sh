#!/usr/bin/env bash
# lib/hy2_standalone.sh — 独立 Hysteria2 服务端（UDP/QUIC）+ 端口跳跃
# 端口跳跃原理：服务端只听一个端口，用 iptables DNAT 把整个 UDP 段重定向过去；
# 客户端配置 mport，每 30s 换端口，抗 QoS/限速和按端口的封锁。

hy2_standalone_deploy() {
  local port="${1:-10153}" auth="$2" sni="$3" obfspw="$4" hop="${5:-}"
  install_hysteria
  mkdir -p /etc/hysteria
  backup_file "$HY2_CONF"

  local crt="$HY2_DIR/selfsigned.crt" key="$HY2_DIR/selfsigned.key"
  if [ ! -f "$crt" ]; then
    need_cmd openssl >/dev/null 2>&1 || pkg_update openssl >/dev/null 2>&1
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$key" -out "$crt" -days 3650 -nodes -subj "/CN=${sni}" >/dev/null 2>&1
    chmod 600 "$key"
  fi

  {
    echo "listen: :${port}"
    echo "tls:"
    echo "  cert: ${crt}"
    echo "  key: ${key}"
    if [ -n "$obfspw" ]; then
      echo "obfs:"
      echo "  type: salamander"
      echo "  salamander:"
      echo "    password: ${obfspw}"
    fi
    echo "auth:"
    echo "  type: password"
    echo "  password: ${auth}"
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: https://${sni}"
    echo "    rewriteHost: true"
    echo "quic:"
    echo "  initStreamReceiveWindow: 8388608"
    echo "  maxStreamReceiveWindow: 8388608"
    echo "  initConnReceiveWindow: 20971520"
    echo "  maxConnReceiveWindow: 20971520"
    echo "  maxIdleTimeout: 60s"
    echo "  maxIncomingStreams: 1024"
    echo "  disablePathMTUDiscovery: false"
    echo "bandwidth:"
    echo "  up: 500 mbps"
    echo "  down: 500 mbps"
    echo "ignoreClientBandwidth: false"
  } > "$HY2_CONF"

  open_port "$port" udp
  if ! svc_enable hysteria-server; then
    err "Hysteria2 启动失败：$(systemctl status hysteria-server --no-pager 2>/dev/null | tail -5)"
    return 1
  fi

  if [ -n "$hop" ]; then
    hy2_setup_hop "$port" "$hop"
  fi
  ok "Hysteria2 监听 UDP ${port}"
}

# hy2_setup_hop <listen_port> <range>  e.g. 20000-40000
hy2_setup_hop() {
  local port="$1" range="$2" lo hi
  lo="${range%-*}"; hi="${range#*-}"
  step "配置 UDP 端口跳跃 ${lo}-${hi} → ${port}"
  need_cmd iptables >/dev/null 2>&1 || pkg_update iptables >/dev/null 2>&1
  modprobe ip_conntrack >/dev/null 2>&1
  modprobe nf_conntrack >/dev/null 2>&1
  iptables -t nat -C PREROUTING -p udp --dport "${lo}:${hi}" -j REDIRECT --to-ports "$port" 2>/dev/null || \
    iptables -t nat -A PREROUTING -p udp --dport "${lo}:${hi}" -j REDIRECT --to-ports "$port"
  ip6tables -t nat -C PREROUTING -p udp --dport "${lo}:${hi}" -j REDIRECT --to-ports "$port" 2>/dev/null || \
    ip6tables -t nat -A PREROUTING -p udp --dport "${lo}:${hi}" -j REDIRECT --to-ports "$port" 2>/dev/null
  iptables -C INPUT -p udp --dport "${lo}:${hi}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p udp --dport "${lo}:${hi}" -j ACCEPT
  save_iptables
  ok "端口跳跃已生效并持久化"
}

hy2_remove_hop() {
  local port="$1" range="$2" lo hi
  lo="${range%-*}"; hi="${range#*-}"
  iptables -t nat -D PREROUTING -p udp --dport "${lo}:${hi}" -j REDIRECT --to-ports "$port" 2>/dev/null
  iptables -D INPUT -p udp --dport "${lo}:${hi}" -j ACCEPT 2>/dev/null
  save_iptables
}
