#!/usr/bin/env bash
# =====================================================================
#  node-deploy — 单台 VPS 代理节点一键部署
#  VLESS-Reality(XTLS-Vision) + Hysteria2(端口跳跃) + SOCKS5 + BBR 调优
#
#  一键：git clone https://github.com/firstwxx1/node-deploy.git && cd node-deploy && sudo bash deploy.sh
#  自定义：sudo bash deploy.sh --profile all --engine xray --port 443 --sni www.cloudflare.com
#  查看：sudo bash deploy.sh --list        状态：sudo bash deploy.sh --status
# =====================================================================

set -uo pipefail
NODE_DEPLOY_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$NODE_DEPLOY_SELF/lib/common.sh"
. "$NODE_DEPLOY_SELF/lib/core.sh"
. "$NODE_DEPLOY_SELF/lib/tune.sh"
. "$NODE_DEPLOY_SELF/lib/node_xray.sh"
. "$NODE_DEPLOY_SELF/lib/node_singbox.sh"
. "$NODE_DEPLOY_SELF/lib/hy2_standalone.sh"
. "$NODE_DEPLOY_SELF/lib/socks5.sh"
. "$NODE_DEPLOY_SELF/lib/nginx_split.sh"
. "$NODE_DEPLOY_SELF/lib/links.sh"

# ----------------------------- 默认参数 -----------------------------
PROFILE="all"
ENGINE="xray"
VLESS_PORT="443"
VLESS_SNI="www.cloudflare.com"
VLESS_UUID=""
VLESS_SID=""
LABEL=""
HY2_ENABLE=1
HY2_MODE="standalone"        # standalone | core
HY2_PORT="10153"
HY2_HOP="20000-40000"
HY2_AUTH=""
HY2_OBFS=""
HY2_SNI="www.bing.com"
SOCKS_ENABLE=1
SOCKS_PORT="1080"
SOCKS_USER="node"
SOCKS_PASS=""
DO_TUNE=1
NGINX_SPLIT=0
ACTION="deploy"
DEL_TAG=""
QR_ENABLE=0
AUTO_YES=0
FORCE_REINSTALL="${FORCE_REINSTALL:-}"
XRAY_VERSION="${XRAY_VERSION:-}"
SBOX_VERSION="${SBOX_VERSION:-}"
HY2_VERSION="${HY2_VERSION:-}"

usage() {
  cat <<'EOF'
用法: sudo bash deploy.sh [选项]

部署组合
  --profile all|vless|hy2|socks5|tune   部署内容（默认 all；tune 只做系统调优）
  --engine xray|singbox                 代理核心（默认 xray）
  --yes                                 全程非交互

VLESS-Reality
  --port PORT        监听端口（默认 443；被占用会自动顺延或走分流）
  --sni DOMAIN       伪装域名，必须是可直连的 HTTPS 站点（默认 www.cloudflare.com）
  --uuid UUID        手动指定 UUID（默认随机）
  --sid HEX          手动指定 shortId，8 位十六进制（默认随机）
  --nginx-split      443 已被网站占用时，用 nginx 按 SNI 分流复用 443

Hysteria2
  --hy2-port PORT    默认 10153
  --hy2-hop RANGE    端口跳跃区间，默认 20000-40000；--hy2-hop none 关闭
  --hy2-auth PW      认证密码（默认随机 32 位）
  --hy2-obfs PW      salamander 混淆密码（默认与 auth 不同的一组 32 位随机）
  --hy2-mode MODE    standalone（独立进程，推荐）| core（跑在引擎内）
  --no-hy2           不部署 Hysteria2

SOCKS5
  --socks-port PORT  默认 1080
  --socks-user NAME  默认 node
  --socks-pass PW    默认随机 16 位
  --no-socks         不部署 SOCKS5

系统
  --no-tune          跳过内核/sysctl 调优
  --core-version VER 指定核心版本（默认 latest，失败回退内置版本）

管理
  --list             列出已部署节点与链接
  --status           查看服务与调优状态
  --del TAG          删除指定入站（tag）
  --qr               为最近一个节点打印终端二维码
  --uninstall        停止并清理本脚本部署的服务（保留备份）

示例
  sudo bash deploy.sh --profile all --port 443 --sni www.cloudflare.com
  sudo bash deploy.sh --profile vless --engine singbox --port 25774 --sni itunes.apple.com
  sudo bash deploy.sh --profile hy2 --hy2-hop 20000-40000
  sudo bash deploy.sh --tune
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --port) VLESS_PORT="$2"; shift 2 ;;
    --sni) VLESS_SNI="$2"; shift 2 ;;
    --uuid) VLESS_UUID="$2"; shift 2 ;;
    --sid) VLESS_SID="$2"; shift 2 ;;
    --nginx-split) NGINX_SPLIT=1; shift ;;
    --hy2-port) HY2_PORT="$2"; shift 2 ;;
    --hy2-hop) HY2_HOP="$2"; shift 2 ;;
    --hy2-auth) HY2_AUTH="$2"; shift 2 ;;
    --hy2-obfs) HY2_OBFS="$2"; shift 2 ;;
    --hy2-mode) HY2_MODE="$2"; shift 2 ;;
    --no-hy2) HY2_ENABLE=0; shift ;;
    --socks-port) SOCKS_PORT="$2"; shift 2 ;;
    --socks-user) SOCKS_USER="$2"; shift 2 ;;
    --socks-pass) SOCKS_PASS="$2"; shift 2 ;;
    --no-socks) SOCKS_ENABLE=0; shift ;;
    --label) LABEL="$2"; shift 2 ;;
    --no-tune) DO_TUNE=0; shift ;;
    --tune) ACTION="tune"; shift ;;
    --core-version) XRAY_VERSION="$2"; SBOX_VERSION="$2"; HY2_VERSION="$2"; shift 2 ;;
    --list) ACTION="list"; shift ;;
    --status) ACTION="status"; shift ;;
    --del) ACTION="del"; DEL_TAG="$2"; shift 2 ;;
    --qr) QR_ENABLE=1; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --yes|-y) AUTO_YES=1; shift ;;
    --force) FORCE_REINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数: $1"; usage; exit 1 ;;
  esac
done

require_root
detect_os

# ----------------------------- 管理子命令 -----------------------------
case "$ACTION" in
  list)
    show_links
    printf "\n产物目录: %s\n" "$STATE_DIR"
    exit 0
    ;;
  tune)
    tune_all
    tune_show
    exit 0
    ;;
  status)
    step "服务状态"
    for s in xray sing-box hysteria-server danted sockd nginx; do
      systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service" && \
        printf "  %-18s %s\n" "$s" "$(svc_status "$s")"
    done
    step "系统调优"
    tune_show
    step "监听端口"
    ss -lntup 2>/dev/null | awk 'NR>1 {print "  "$1"  "$5}' | sort -u | head -30
    exit 0
    ;;
  del)
    [ -n "$DEL_TAG" ] || die "需要 --del <tag>，可用 sudo bash deploy.sh --status 查看"
    step "删除入站 $DEL_TAG"
    case "$ENGINE" in
      singbox) sbox_remove_inbound "$DEL_TAG" ;;
      *) xray_remove_inbound "$DEL_TAG" ;;
    esac
    exit 0
    ;;
  uninstall)
    step "卸载本脚本部署的服务"
    for s in xray sing-box hysteria-server; do
      systemctl stop "$s" >/dev/null 2>&1; systemctl disable "$s" >/dev/null 2>&1
    done
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/sing-box.service /etc/systemd/system/hysteria-server.service
    systemctl daemon-reload
    ok "核心服务已停止并移除（配置与备份保留在 $STATE_DIR 与原路径）"
    exit 0
    ;;
esac

# ----------------------------- 部署流程 -----------------------------
print_banner
log "系统: $OS_NAME / $ARCH / 内核 $(uname -r)"
log "主网卡: $MAIN_IFACE · 公网 IP: ${PUBLIC_IP:-未知}"
[ -n "$LABEL" ] || LABEL="$(printf '%s' "${PUBLIC_IP:-node}" | tr '.' '-')"

if [ "$DO_TUNE" = "1" ] || [ "$PROFILE" = "tune" ]; then tune_all; fi
[ "$PROFILE" = "tune" ] && { tune_show; exit 0; }

[ "$PROFILE" = "all" ] && { DO_VLESS=1; DO_HY2=$HY2_ENABLE; DO_SOCKS=$SOCKS_ENABLE; }
[ "$PROFILE" = "vless" ] && { DO_VLESS=1; DO_HY2=0; DO_SOCKS=0; }
[ "$PROFILE" = "hy2" ] && { DO_VLESS=0; DO_HY2=1; DO_SOCKS=0; }
[ "$PROFILE" = "socks5" ] && { DO_VLESS=0; DO_HY2=0; DO_SOCKS=1; }
: "${DO_VLESS:=1}"; : "${DO_HY2:=$HY2_ENABLE}"; : "${DO_SOCKS:=$SOCKS_ENABLE}"

need_cmd curl >/dev/null 2>&1 || pkg_update curl

# ---------- 核心安装 ----------
# 只在真正需要引擎时才装：纯 SOCKS5 / 独立 HY2 / 只调优的机器不必背一个 core
NEED_CORE=0
[ "${DO_VLESS:-1}" = "1" ] && NEED_CORE=1
[ "${DO_HY2:-1}" = "1" ] && [ "$HY2_MODE" = "core" ] && NEED_CORE=1

if [ "$NEED_CORE" = "1" ]; then
  case "$ENGINE" in
    singbox)
      install_singbox; sbox_conf_init; CORE_NAME="sing-box"; CORE_SVC="sing-box"
      ;;
    xray|*)
      ENGINE="xray"; install_xray; xray_conf_init; CORE_NAME="xray"; CORE_SVC="xray"
      ;;
  esac
fi

# ---------- Reality 密钥对 ----------
REALITY_PRIV=""; REALITY_PUB=""
if [ "${DO_VLESS:-1}" = "1" ]; then
  step "生成 Reality 密钥对"
  case "$ENGINE" in
    singbox) sbox_keypair || die "密钥对生成失败" ;;
    *)       xray_keypair || die "密钥对生成失败" ;;
  esac
  [ -n "$VLESS_SID" ] || VLESS_SID="$(rand_hex 8)"
  [ -n "$VLESS_UUID" ] || VLESS_UUID="$(rand_uuid)"
  ok "pub=${REALITY_PUB} sid=${VLESS_SID}"
fi

# ---------- VLESS-Reality ----------
if [ "${DO_VLESS:-1}" = "1" ]; then
  step "部署 VLESS-Reality (XTLS-Vision) 端口 ${VLESS_PORT} SNI=${VLESS_SNI}"
  REAL_LISTEN="0.0.0.0"; REAL_PORT="$VLESS_PORT"; SPLIT_USED=0

  if [ "$NGINX_SPLIT" = "1" ]; then
    REAL_PORT="$SPLIT_PROXY_PORT"
    if nginx_split_deploy "$VLESS_SNI" "$REAL_PORT"; then
      REAL_LISTEN="127.0.0.1"; SPLIT_USED=1
    else
      warn "分流失败，回退直连 ${VLESS_PORT}"
    fi
  elif ! port_free "$VLESS_PORT" && ss -lntp 2>/dev/null | grep -qE "[:.]${VLESS_PORT}\b.*nginx"; then
    warn "443 已被 nginx 占用。改用 8443（或加 --nginx-split 复用 443）"
    VLESS_PORT="8443"; REAL_PORT="8443"
  fi

  TAG="vless-reality-${REAL_PORT}"
  case "$ENGINE" in
    singbox)
      sbox_add_vless_reality "$TAG" "$REAL_PORT" "$VLESS_UUID" "$VLESS_SNI" "$REALITY_PRIV" "$VLESS_SID" "::" \
        && ok "sing-box 入站 ${TAG} 已就绪" || die "VLESS 入站写入失败"
      ;;
    *)
      xray_add_vless_reality "$TAG" "$REAL_PORT" "$VLESS_UUID" "$VLESS_SNI" "$REALITY_PRIV" "$VLESS_SID" "$REAL_LISTEN" \
        && ok "Xray 入站 ${TAG} 已就绪" || die "VLESS 入站写入失败"
      ;;
  esac
  open_port "$VLESS_PORT" tcp
  wait_port "$REAL_PORT" || warn "端口 ${REAL_PORT} 未监听，请检查 ${CORE_SVC} 状态"

  LINK="$(reg_vless "$PUBLIC_IP" "$VLESS_PORT" "${LABEL}-VLESS-${VLESS_PORT}" "$VLESS_UUID" "$VLESS_SNI" "$REALITY_PUB" "$VLESS_SID")"
  printf "  ${C_GRN}%s${C_OFF}\n" "$LINK"
  [ "$QR_ENABLE" = "1" ] && show_qr "$LINK"
fi

# ---------- Hysteria2 ----------
if [ "${DO_HY2:-1}" = "1" ]; then
  step "部署 Hysteria2 端口 ${HY2_PORT} (UDP)"
  [ -n "$HY2_AUTH" ] || HY2_AUTH="$(rand_pass 32)"
  [ -n "$HY2_OBFS" ] || HY2_OBFS="$(rand_pass 32)"
  [ "$HY2_HOP" = "none" ] && HY2_HOP=""

  if [ "$HY2_MODE" = "standalone" ]; then
    hy2_standalone_deploy "$HY2_PORT" "$HY2_AUTH" "$HY2_SNI" "$HY2_OBFS" "$HY2_HOP" || warn "独立 Hysteria2 部署失败"
  else
    case "$ENGINE" in
      singbox) sbox_add_hysteria2 "hy2-${HY2_PORT}" "$HY2_PORT" "$HY2_AUTH" "$HY2_SNI" "$HY2_OBFS" \
                 && ok "sing-box hy2 入站就绪" || warn "hy2 入站写入失败" ;;
      *) xray_add_hysteria2 "hy2-${HY2_PORT}" "$HY2_PORT" "$HY2_AUTH" "$HY2_SNI" "$HY2_OBFS" \
                 && ok "Xray hy2 入站就绪" || warn "hy2 入站写入失败" ;;
    esac
    open_port "$HY2_PORT" udp
    if [ -n "$HY2_HOP" ]; then hy2_setup_hop "$HY2_PORT" "$HY2_HOP"; fi
  fi

  LINK="$(reg_hy2 "$PUBLIC_IP" "$HY2_PORT" "${LABEL}-Hy2" "$HY2_AUTH" "$HY2_SNI" "$HY2_OBFS" "$HY2_HOP")"
  printf "  ${C_GRN}%s${C_OFF}\n" "$LINK"
  [ "$QR_ENABLE" = "1" ] && show_qr "$LINK"
fi

# ---------- SOCKS5 ----------
if [ "${DO_SOCKS:-1}" = "1" ]; then
  [ -n "$SOCKS_PASS" ] || SOCKS_PASS="$(rand_pass 16)"
  socks5_deploy "$SOCKS_PORT" "$SOCKS_USER" "$SOCKS_PASS" || warn "SOCKS5 部署失败"
  LINK="$(reg_socks5 "$PUBLIC_IP" "$SOCKS_PORT" "${LABEL}-SOCKS5" "$SOCKS_USER" "$SOCKS_PASS")"
  printf "  ${C_GRN}%s${C_OFF}\n" "$LINK"
fi

# ---------- 收尾 ----------
export_links
printf "\n${C_BLD}========== 部署完成 ==========${C_OFF}\n"
show_links
printf "  订阅内容(base64): %s\n" "$STATE_DIR/sub.txt"
printf "  sing-box 客户端  : %s\n" "$STATE_DIR/client-singbox.json"
printf "  Clash 客户端     : %s\n" "$STATE_DIR/client-clash.yaml"
printf "  纯链接列表       : %s\n\n" "$LINK_FILE"
[ "${XANMOD_INSTALLED:-0}" = "1" ] && warn "已更换内核，请 reboot 后再测速"
log "下次查看：sudo bash deploy.sh --list"
