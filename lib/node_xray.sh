#!/usr/bin/env bash
# lib/node_xray.sh — 往 Xray 配置里写入 VLESS-Reality / Hysteria2 / Shadowsocks 入站
# 所有写操作顺序：备份 → 校验 → 重启 → 失败回滚。

# xray x25519 → 现实密钥对
xray_keypair() {
  local out
  out="$("$XRAY_BIN" x25519 2>/dev/null)"
  REALITY_PRIV="$(printf '%s\n' "$out" | grep -oE '[A-Za-z0-9_-]{43}' | sed -n '1p')"
  REALITY_PUB="$(printf '%s\n' "$out" | grep -oE '[A-Za-z0-9_-]{43}' | sed -n '2p')"
  [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ]
}

xray_inbound_exists() {
  python3 - "$XRAY_CONF" "$1" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
print(1 if any(i.get("tag")==sys.argv[2] for i in d.get("inbounds",[])) else 0)
PY
}

# add_vless_reality <tag> <port> <uuid> <sni> <priv> <shortid> [listen]
xray_add_vless_reality() {
  local tag="$1" port="$2" uuid="$3" sni="$4" priv="$5" sid="$6" listen="${7:-0.0.0.0}"
  backup_file "$XRAY_CONF"
  local dest="${sni}:443"
  python3 - "$XRAY_CONF" "$tag" "$port" "$uuid" "$sni" "$priv" "$sid" "$dest" "$listen" <<'PY'
import json,sys
p,tag,port,uuid,sni,priv,sid,dest,listen = sys.argv[1:10]
d=json.load(open(p))
d.setdefault("inbounds",[])
d["inbounds"]=[i for i in d["inbounds"] if i.get("tag")!=tag and not (i.get("port")==int(port) and i.get("protocol")=="vless")]
d["inbounds"].append({
  "listen": listen,
  "port": int(port),
  "protocol": "vless",
  "tag": tag,
  "settings": {
    "clients": [{"id": uuid, "flow": "xtls-rprx-vision", "email": tag}],
    "decryption": "none",
    "fallbacks": []
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": False,
      "dest": dest,
      "xver": 0,
      "serverNames": [sni, "www."+sni.lstrip("www.")],
      "privateKey": priv,
      "shortIds": [sid],
      "maxTimeDiff": 0
    }
  },
  "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"], "routeOnly": False}
})
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2)
PY
  if ! xray_conf_check; then
    err "Xray 配置校验失败，回滚：$(tail -3 /tmp/xray-test.log)"
    cp -a "$(ls -t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | head -1)" "$XRAY_CONF" 2>/dev/null
    return 1
  fi
  svc_enable xray || { err "Xray 启动失败，回滚配置"; cp -a "$(ls -t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | head -1)" "$XRAY_CONF" 2>/dev/null; systemctl restart xray >/dev/null 2>&1; return 1; }
  return 0
}

# add_hysteria2 <tag> <port> <auth> <sni> [obfs_password] [up_mbps] [down_mbps]
xray_add_hysteria2() {
  local tag="$1" port="$2" auth="$3" sni="$4" obfspw="$5" up="${6:-500}" down="${7:-500}"
  backup_file "$XRAY_CONF"
  local crt="$HY2_DIR/selfsigned.crt" key="$HY2_DIR/selfsigned.key"
  if [ ! -f "$crt" ]; then
    mkdir -p "$HY2_DIR"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$key" -out "$crt" -days 3650 -nodes -subj "/CN=${sni}" >/dev/null 2>&1
    chmod 600 "$key"
  fi
  python3 - "$XRAY_CONF" "$tag" "$port" "$auth" "$sni" "$obfspw" "$crt" "$key" "$up" "$down" <<'PY'
import json,sys
(p,tag,port,auth,sni,obfspw,crt,key,up,down)=sys.argv[1:11]
d=json.load(open(p))
d.setdefault("inbounds",[])
d["inbounds"]=[i for i in d["inbounds"] if i.get("tag")!=tag]
ss={"network":"udp","security":"tls","tlsSettings":{"certificates":[{"certificateFile":crt,"keyFile":key,"ocspStapling":3600}],"alpn":["h3"],"minVersion":"1.3"}}
ino={
  "listen":"0.0.0.0","port":int(port),"protocol":"hysteria2","tag":tag,
  "settings":{"clients":[{"password":auth}],"ignoreClientBandwidth":False},
  "streamSettings":ss,
  "sniffing":{"enabled":True,"destOverride":["http","tls","quic"],"routeOnly":False}
}
if obfspw:
    ss["tlsSettings"]["obfs"]={"type":"salamander","password":obfspw}
d["inbounds"].append(ino)
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2)
PY
  if ! xray_conf_check; then
    err "Xray 配置校验失败，回滚：$(tail -3 /tmp/xray-test.log)"
    cp -a "$(ls -t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | head -1)" "$XRAY_CONF" 2>/dev/null
    return 1
  fi
  svc_enable xray || { err "Xray 启动失败，回滚"; cp -a "$(ls -t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | head -1)" "$XRAY_CONF" 2>/dev/null; systemctl restart xray >/dev/null 2>&1; return 1; }
  open_port "$port" udp
  return 0
}

# remove_inbound <tag>
xray_remove_inbound() {
  local tag="$1"
  backup_file "$XRAY_CONF"
  python3 - "$XRAY_CONF" "$tag" <<'PY'
import json,sys
p,tag=sys.argv[1:3]
d=json.load(open(p))
d["inbounds"]=[i for i in d.get("inbounds",[]) if i.get("tag")!=tag]
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2)
PY
  xray_conf_check && systemctl restart xray && ok "已删除入站 $tag" || { warn "删除后校验失败，回滚"; cp -a "$(ls -t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | head -1)" "$XRAY_CONF"; systemctl restart xray >/dev/null 2>&1; }
}

xray_list_inbounds() {
  python3 - "$XRAY_CONF" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
for i in d.get("inbounds",[]):
    print("  %-22s %-10s %s" % (i.get("tag","-"), i.get("protocol","-"), i.get("port","-")))
PY
}
