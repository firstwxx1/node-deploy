#!/usr/bin/env bash
# lib/nginx_split.sh — 443 端口复用：nginx stream 按 SNI 分流
# 场景：443 已经被网站占了，但仍想让 VLESS-Reality 跑在 443（防火墙最常放通的端口）。
# 做法：nginx 占 443 并 ssl_preread，命中代理域名转给本机 xray(x 端口)，其余走回原网站(x 端口)。

NGINX_STREAM_CONF="/etc/nginx/conf.d/node-deploy-stream.conf"
SPLIT_LOCAL_PORT="${SPLIT_LOCAL_PORT:-10443}"    # 原网站迁到这个端口
SPLIT_PROXY_PORT="${SPLIT_PROXY_PORT:-10444}"    # 代理核心监听这个端口

nginx_split_deploy() {
  local sni="$1" proxy_port="$2"
  step "配置 nginx 443 SNI 分流 → ${sni} 转到 127.0.0.1:${proxy_port}"
  command -v nginx >/dev/null 2>&1 || pkg_update nginx
  command -v nginx >/dev/null 2>&1 || { warn "未安装 nginx，跳过分流"; return 1; }

  # stream 模块：Debian 官方包默认不带
  if ! nginx -V 2>&1 | grep -q 'with-stream'; then
    if [ -d /usr/lib/nginx/modules ] && [ ! -f /usr/lib/nginx/modules/ngx_stream_module.so ]; then
      pkg_update libnginx-mod-stream
    fi
  fi
  nginx -V 2>&1 | grep -q 'with-stream' || { warn "nginx 无 stream 模块，跳过分流（改用独立端口部署）"; return 1; }

  # 现有 443 vhost 迁到 127.0.0.1:SPLIT_LOCAL_PORT
  local changed=0
  while IFS= read -r f; do
    if grep -qE 'listen\s+(\[::\]:)?443' "$f" 2>/dev/null; then
      backup_file "$f"
      sed -i -E "s/listen\s+\[::\]:443/listen 127.0.0.1:${SPLIT_LOCAL_PORT}/g; s/listen\s+443/listen 127.0.0.1:${SPLIT_LOCAL_PORT}/g" "$f"
      changed=$((changed+1))
    fi
  done < <(grep -rlE 'listen\s+(\[::\]:)?443' /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null)

  mkdir -p /etc/nginx/conf.d
  cat >"$NGINX_STREAM_CONF" <<EOF
stream {
    map \$ssl_preread_server_name \$node_deploy_backend {
        ${sni}                     proxy_core;
        *.${sni}                   proxy_core;
        default                    local_web;
    }
    upstream proxy_core { server 127.0.0.1:${proxy_port}; }
    upstream local_web   { server 127.0.0.1:${SPLIT_LOCAL_PORT}; }

    log_format node_deploy '\$remote_addr [\$time_local] sni=\$ssl_preread_server_name -> \$upstream_addr';
    access_log /var/log/nginx/node-deploy-stream.log node_deploy;

    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        ssl_preread on;
        proxy_pass \$node_deploy_backend;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
    }
}
EOF

  # stream 块必须在主配置里被 include（conf.d 已在 http 块内时需单独挂）
  if [ -f /etc/nginx/nginx.conf ] && ! grep -q 'node-deploy-stream.conf' /etc/nginx/nginx.conf; then
    backup_file /etc/nginx/nginx.conf
    python3 - /etc/nginx/nginx.conf <<'PY'
import re,sys
p=sys.argv[1]
s=open(p).read()
if 'node-deploy-stream.conf' not in s:
    inc="include /etc/nginx/conf.d/node-deploy-stream.conf;\n"
    s=re.sub(r'^(events\s*\{)', inc+r'\1', s, count=1, flags=re.M) if 'events' in s else inc+s
    open(p,'w').write(s)
PY
  fi

  nginx -t >/tmp/nginx-test.log 2>&1 || { err "nginx 配置错误：$(tail -5 /tmp/nginx-test.log)"; return 1; }
  systemctl enable nginx >/dev/null 2>&1
  systemctl restart nginx
  sleep 1
  if systemctl is-active --quiet nginx; then
    ok "nginx 分流已生效（${changed} 个 443 vhost 迁到 ${SPLIT_LOCAL_PORT}）"
    return 0
  fi
  err "nginx 启动失败：$(systemctl status nginx --no-pager 2>/dev/null | tail -4)"
  return 1
}

nginx_split_remove() {
  rm -f "$NGINX_STREAM_CONF"
  sed -i '/node-deploy-stream.conf/d' /etc/nginx/nginx.conf 2>/dev/null
  nginx -t >/dev/null 2>&1 && systemctl restart nginx
  ok "已移除 nginx 分流配置（原 443 vhost 需手动改回）"
}
