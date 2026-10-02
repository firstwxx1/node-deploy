#!/usr/bin/env bash
# lib/socks5.sh — danted SOCKS5 出口（系统级账号认证，独立于代理核心）
# 好处：核心挂了、配置写错了，SOCKS5 仍然活着，永远留一条能进机房的路。

DANTED_CONF="/etc/danted.conf"

socks5_deploy() {
  local port="${1:-1080}" user="$2" pass="$3"
  step "部署 SOCKS5 (danted) 端口 ${port}"
  case "$OS_ID" in
    ubuntu|debian)
      pkg_update dante-server || die "dante-server 安装失败"
      ;;
    centos|rhel|rocky|almalinux|fedora)
      pkg_update dante dante-server 2>/dev/null || pkg_update epel-release
      pkg_update dante-server 2>/dev/null || warn "RHEL 系请手动安装 dante-server"
      ;;
    *) warn "未知发行版，尝试直接安装 dante-server" ; pkg_update dante-server ;;
  esac
  command -v danted >/dev/null 2>&1 || die "未找到 danted 二进制，SOCKS5 跳过（可用 --engine singbox 改用内核级 socks）"

  # PAM 栈：很多镜像缺这个文件，danted 认证会直接拒绝
  if [ ! -f /etc/pam.d/danted ]; then
    cat >/etc/pam.d/danted <<'EOF'
auth    required    pam_unix.so    nullok_secure
account required    pam_unix.so
session required    pam_unix.so
EOF
    cp -f /etc/pam.d/danted /etc/pam.d/sockd 2>/dev/null
    cp -f /etc/pam.d/danted /etc/pam.d/dante 2>/dev/null
  fi

  # 专用低权账号
  if ! id -u "$user" >/dev/null 2>&1; then
    useradd -M -s /usr/sbin/nologin "$user" 2>/dev/null || useradd -M -s /bin/false "$user"
  fi
  printf '%s:%s\n' "$user" "$pass" | chpasswd -c SHA512 2>/dev/null || \
    printf '%s:%s\n' "$user" "$pass" | chpasswd
  usermod -aG proxy "$user" 2>/dev/null

  backup_file "$DANTED_CONF"
  cat >"$DANTED_CONF" <<EOF
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = ${port}
internal: :: port = ${port}
external: ${MAIN_IFACE}
external.rotation: same-same
socksmethod: username
clientmethod: none
user.privileged: root
user.unprivileged: nobody
user.libwrap: nobody
client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: connect disconnect error
}
client pass {
  from: ::/0 to: ::/0
  log: connect disconnect error
}
socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp udp
  command: bind connect udpassociate
  log: connect disconnect error
  socksmethod: username
}
socks pass {
  from: ::/0 to: ::/0
  protocol: tcp udp
  command: bind connect udpassociate
  log: connect disconnect error
  socksmethod: username
}
EOF

  open_port "$port" tcp
  open_port "$port" udp

  # 服务名在 Debian 是 danted，在部分镜像叫 sockd
  local svc="danted"
  systemctl list-unit-files 2>/dev/null | grep -q '^sockd' && svc="sockd"
  if ! systemctl restart "$svc" >/dev/null 2>&1; then
    # 老镜像无 systemd 单元，直接起进程
    /usr/sbin/danted -D -f "$DANTED_CONF" >/dev/null 2>&1 || danted -D -f "$DANTED_CONF" >/dev/null 2>&1
    pgrep -x danted >/dev/null 2>&1 && ok "danted 以进程方式启动" || { err "danted 启动失败"; return 1; }
  else
    systemctl enable "$svc" >/dev/null 2>&1
    ok "danted 服务已启动 ($svc)"
  fi
  sleep 0.5
  if ss -lnt 2>/dev/null | grep -qE "[:.]${port}\b"; then
    ok "SOCKS5 监听 ${port}"
  else
    warn "端口 ${port} 未监听，检查 /var/log/danted.log"
  fi
}

socks5_del_user() {
  local user="$1"
  userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null
  ok "已删除系统账号 $user"
}
