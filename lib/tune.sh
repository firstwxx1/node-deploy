#!/usr/bin/env bash
# lib/tune.sh — 内核拥塞控制（BBR / BBRv3 / bbrplus）+ sysctl 网络栈调优 + 网卡队列
# 目标：把单连接的长肥管道跑满。实测在 200ms+ 跨洋链路上，默认 cubic 只有 BBR 的 1/5 不到。

TUNE_CONF="/etc/sysctl.d/99-z-node-deploy.conf"

bbr_available() {
  [ -f /proc/sys/net/ipv4/tcp_available_congestion_control ] || return 1
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control
}

# 内核太老（<4.9）没有 BBR：Debian/Ubuntu 上装 XanMod 内核补上
install_xanmod() {
  case "$OS_ID" in
    ubuntu|debian)
      step "内核不含 BBR，尝试安装 XanMod 内核"
      need_cmd wget >/dev/null 2>&1
      need_cmd gnupg >/dev/null 2>&1 || pkg_update gnupg
      wget -qO - https://dl.xanmod.org/archive.key 2>/dev/null \
        | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null || {
          warn "XanMod 公钥获取失败，跳过换内核"; return 1
        }
      echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" \
        > /etc/apt/sources.list.d/xanmod-kernel.list
      apt-get update -qq >/dev/null 2>&1 || true
      if apt-get install -y -qq linux-xanmod-x64v3 >/dev/null 2>&1; then
        ok "XanMod 内核已安装，重启后生效（bbr3 可用）"
        XANMOD_INSTALLED=1
        return 0
      fi
      apt-get install -y -qq linux-xanmod-x64v2 >/dev/null 2>&1 && { ok "XanMod 内核已安装，重启后生效"; XANMOD_INSTALLED=1; return 0; }
      warn "XanMod 安装失败，继续使用当前内核"
      ;;
    centos|rhel|rocky|almalinux|fedora)
      step "内核不含 BBR，尝试安装 ELRepo kernel-ml"
      rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org 2>/dev/null || true
      if [ "$OS_ID" = "fedora" ]; then
        dnf install -y -q "https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm" >/dev/null 2>&1
      else
        yum install -y -q https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm >/dev/null 2>&1 || \
        yum install -y -q https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm >/dev/null 2>&1
      fi
      if yum --enablerepo=elrepo-kernel install -y -q kernel-ml >/dev/null 2>&1; then
        ok "kernel-ml 已安装，重启后生效"
        XANMOD_INSTALLED=1
        return 0
      fi
      warn "ELRepo 安装失败，继续使用当前内核"
      ;;
    *) warn "当前发行版不自动换内核，请手动升级到 >= 4.9" ;;
  esac
  return 1
}

write_sysctl_conf() {
  # 按机器总内存动态换算 tcp_mem / udp_mem（单位为 4KB 内存页，而非字节，避免小内存 VPS OOM）
  local mem_kb mem_pages tcp_min tcp_press tcp_max udp_min udp_press udp_max ct_max
  mem_kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 1048576)"
  [ -n "$mem_kb" ] && [ "$mem_kb" -gt 0 ] 2>/dev/null || mem_kb=1048576
  mem_pages=$(( mem_kb / 4 ))
  tcp_min=$(( mem_pages / 16 )); [ "$tcp_min" -lt 8192 ] && tcp_min=8192
  tcp_press=$(( mem_pages / 8 )); [ "$tcp_press" -lt 16384 ] && tcp_press=16384
  tcp_max=$(( mem_pages / 4 )); [ "$tcp_max" -lt 32768 ] && tcp_max=32768
  udp_min=$(( mem_pages / 32 )); [ "$udp_min" -lt 4096 ] && udp_min=4096
  udp_press=$(( mem_pages / 16 )); [ "$udp_press" -lt 16384 ] && udp_press=16384
  udp_max=$(( mem_pages / 4 )); [ "$udp_max" -lt 32768 ] && udp_max=32768
  if [ "$mem_kb" -ge 3900000 ]; then
    ct_max=524288
  elif [ "$mem_kb" -ge 1800000 ]; then
    ct_max=262144
  else
    ct_max=131072
  fi

  cat >"$TUNE_CONF" <<EOF
# node-deploy — 长肥管道与高并发 UDP/QUIC 优化（按宿主机内存 ${mem_kb}KB 自动换算）
# 拥塞控制：BBR + fq pacing。跨洋高延迟 + 轻丢包场景下吞吐显著高于 cubic。
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 缓冲区：16MB 上限，配合 BBR 与 Hysteria2/QUIC 跑满大 BDP 跨洋链路
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_mem = ${tcp_min} ${tcp_press} ${tcp_max}
net.ipv4.udp_mem = ${udp_min} ${udp_press} ${udp_max}

# 空闲后不回到慢启动：代理长连接反复 idle/active 时这条最关键
net.ipv4.tcp_slow_start_after_idle = 0

# 窗口缩放 + 时间戳 + SACK 全开
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_adv_win_scale = 2

# MTU 探测：路径上有 PPPoE / 隧道 / 小 MTU 中转时避免 PMTUD 黑洞
net.ipv4.tcp_mtu_probing = 1

# TFO：客户端+服务端都开，省一个 RTT
net.ipv4.tcp_fastopen = 3

# 网卡收包队列与连接并发上限
net.core.netdev_max_backlog = 32768
net.core.netdev_budget = 600
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0

# 转发（代理出口必需）
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# conntrack：UDP 型协议（Hysteria2）连接量大，按内存自适应上限避免溢出丢包
net.netfilter.nf_conntrack_max = ${ct_max}
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# 文件描述符
fs.file-max = 1048576
fs.nr_open = 1048576
EOF

  # bbr 不可用时退到 bbrplus / cubic，别把机器写坏
  if ! bbr_available; then
    sed -i 's/^net.ipv4.tcp_congestion_control = bbr$/net.ipv4.tcp_congestion_control = cubic/' "$TUNE_CONF"
  fi
  # 有 bbrplus（部分机房内核）且没原生 bbr 时用它
  if ! bbr_available && grep -qw bbrplus /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    sed -i 's/^net.ipv4.tcp_congestion_control = cubic$/net.ipv4.tcp_congestion_control = bbrplus/' "$TUNE_CONF"
  fi

  sysctl --system >/dev/null 2>&1 || sysctl -p "$TUNE_CONF" >/dev/null 2>&1
}

tune_limits() {
  cat >/etc/security/limits.d/99-node-deploy.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
  mkdir -p /etc/systemd/system.conf.d
  cat >/etc/systemd/system.conf.d/99-node-deploy.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
}

tune_nic() {
  # 队列 / offload / 网卡环缓冲 / 即时生效 fq 队列（无需重启即可发挥 BBR pacing）
  [ -n "${MAIN_IFACE:-}" ] || return 0
  command -v ethtool >/dev/null 2>&1 || pkg_update ethtool >/dev/null 2>&1
  if command -v ethtool >/dev/null 2>&1; then
    local rx_max tx_max
    rx_max="$(ethtool -g "$MAIN_IFACE" 2>/dev/null | awk '/Pre-set maximums:/{s=1;next} /Current hardware/{s=0} s && /^RX:/{print $2; exit}')"
    tx_max="$(ethtool -g "$MAIN_IFACE" 2>/dev/null | awk '/Pre-set maximums:/{s=1;next} /Current hardware/{s=0} s && /^TX:/{print $2; exit}')"
    [ -n "$rx_max" ] && [ "$rx_max" -gt 4096 ] 2>/dev/null && rx_max=4096
    [ -n "$tx_max" ] && [ "$tx_max" -gt 4096 ] 2>/dev/null && tx_max=4096
    if [ -n "$rx_max" ] && [ -n "$tx_max" ]; then
      ethtool -G "$MAIN_IFACE" rx "$rx_max" tx "$tx_max" >/dev/null 2>&1 || true
    fi
    # 代理/NAT 节点必须关闭 LRO（否则可能破坏转发分片包），保留 GRO/GSO/TSO
    for f in tso gso gro tx rx sg; do
      ethtool -K "$MAIN_IFACE" "$f" on >/dev/null 2>&1 || true
    done
    ethtool -K "$MAIN_IFACE" lro off >/dev/null 2>&1 || true
  fi
  ip link set "$MAIN_IFACE" txqueuelen 10000 >/dev/null 2>&1 || true
  # 立即把活动网卡切换为 fq（解决 sysctl default_qdisc 重启前不生效及 mq 子队列残留 fq_codel 问题）
  if command -v tc >/dev/null 2>&1; then
    tc qdisc replace dev "$MAIN_IFACE" root fq >/dev/null 2>&1 || true
  fi
}

tune_all() {
  step "系统网络栈调优"
  bbr_available || install_xanmod
  write_sysctl_conf
  tune_limits
  tune_nic
  local cc now
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  now="$(sysctl -n net.core.rmem_max 2>/dev/null)"
  ok "拥塞控制 = ${cc} · rmem_max = ${now}"
  if [ "$cc" = "bbr" ] || [ "$cc" = "bbrplus" ]; then
    ok "BBR 已生效"
  else
    warn "当前为 ${cc}。若内核 < 4.9 或为 OpenVZ，请升级内核 / 换 KVM 后再跑一次 --tune"
  fi
}

tune_show() {
  printf "  拥塞控制      : %s\n" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  printf "  可用算法      : %s\n" "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
  printf "  队列规则      : %s\n" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  printf "  rmem_max      : %s\n" "$(sysctl -n net.core.rmem_max 2>/dev/null)"
  printf "  tcp_fastopen  : %s\n" "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
  printf "  mtu_probing   : %s\n" "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
  printf "  ip_forward    : %s\n" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
  printf "  调优文件      : %s\n" "$TUNE_CONF"
}
