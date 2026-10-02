#!/usr/bin/env bash
# lib/tune.sh — 内核拥塞控制（BBR / BBRv3 / bbrplus）+ sysctl 网络栈调优 + 网卡队列
# 目标：把单连接的长肥管道跑满。实测在 200ms+ 跨洋链路上，默认 cubic 只有 BBR 的 1/5 不到。

TUNE_CONF="/etc/sysctl.d/99-node-deploy.conf"

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
  cat >"$TUNE_CONF" <<'EOF'
# node-deploy — 长肥管道优化
# 拥塞控制：BBR。跨洋高延迟 + 轻丢包场景下吞吐显著高于 cubic。
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 缓冲区：16MB 上限，配合 BBR 让 BDP 大的链路能开满窗口
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 262144 524288 16777216
net.ipv4.udp_mem = 262144 524288 16777216

# 空闲后不回到慢启动：代理长连接反复 idle/active 时这条最关键
net.ipv4.tcp_slow_start_after_idle = 0

# 窗口缩放 + 时间戳 + SACK 全开
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_adv_win_scale = 2

# MTU 探测：路径上有 PPPoE / 隧道 / 小 MTU 中转时避免 PMTUD 黑洞
net.ipv4.tcp_mtu_probing = 1

# TFO：客户端+服务端都开，省一个 RTT
net.ipv4.tcp_fastopen = 3

# 拥塞窗口上限（保守放开）
net.ipv4.tcp_congestion_control_bbr = 1
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 262144
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

# conntrack：UDP 型协议（Hysteria2）连接量大，表太小会丢包
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_udp_timeout = 120
net.netfilter.nf_conntrack_udp_timeout_stream = 300

# 文件描述符
fs.file-max = 1048576
fs.nr_open = 1048576
EOF

  # bbr 不可用时退到 bbrplus / cubic，别把机器写坏
  if ! bbr_available; then
    sed -i 's/^net.ipv4.tcp_congestion_control = bbr$/net.ipv4.tcp_congestion_control = cubic/' "$TUNE_CONF"
    sed -i '/^net.ipv4.tcp_congestion_control_bbr/d' "$TUNE_CONF"
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
  # 队列 / offload / 队列长度。失败不影响主流程。
  command -v ethtool >/dev/null 2>&1 || pkg_update ethtool >/dev/null 2>&1
  if command -v ethtool >/dev/null 2>&1; then
    ethtool -G "$MAIN_IFACE" rx 4096 tx 4096 >/dev/null 2>&1
    for f in tso gso gro lro tx rx sg; do
      ethtool -K "$MAIN_IFACE" "$f" on >/dev/null 2>&1
    done
  fi
  ip link set "$MAIN_IFACE" txqueuelen 10000 >/dev/null 2>&1
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
