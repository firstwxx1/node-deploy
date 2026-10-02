#!/usr/bin/env bash
# lib/node_singbox.sh — 往 sing-box 配置里写入 VLESS-Reality / Hysteria2 / SOCKS 入站
# 注意 sing-box 用 listen_port，不是 port；端口是数字，不要加引号。

sbox_keypair() {
  local out
  out="$("$SBOX_BIN" generate reality-keypair 2>/dev/null)"
  REALITY_PRIV="$(printf '%s\n' "$out" | grep -oE '[A-Za-z0-9_-]{43}' | sed -n '1p')"
  REALITY_PUB="$(printf '%s\n' "$out" | grep -oE '[A-Za-z0-9_-]{43}' | sed -n '2p')"
  [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ]
}

sbox_restart_safe() {
  if ! sbox_conf_check; then
    err "sing-box 配置校验失败，回滚：$(tail -3 /tmp/singbox-check.log)"
    cp -a "$(ls -t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | head -1)" "$SBOX_CONF" 2>/dev/null
    systemctl restart sing-box >/dev/null 2>&1
    return 1
  fi
  svc_enable sing-box || {
    err "sing-box 启动失败，回滚配置"
    cp -a "$(ls -t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | head -1)" "$SBOX_CONF" 2>/dev/null
    systemctl restart sing-box >/dev/null 2>&1
    return 1
  }
  return 0
}

# add_vless_reality <tag> <port> <uuid> <sni> <priv> <shortid> [listen]
sbox_add_vless_reality() {
  local tag="$1" port="$2" uuid="$3" sni="$4" priv="$5" sid="$6" listen="${7:-::}"
  backup_file "$SBOX_CONF"
  python3 - "$SBOX_CONF" "$tag" "$port" "$uuid" "$sni" "$priv" "$sid" "$listen" <<'PY'
import json,sys
(p,tag,port,uuid,sni,priv,sid,listen)=sys.argv[1:9]
d=json.load(open(p))
d.setdefault("inbounds",[])
d["inbounds"]=[i for i in d["inbounds"] if i.get("tag")!=tag and not (i.get("listen_port")==int(port) and i.get("type")=="vless")]
d["inbounds"].append({
  "type":"vless","tag":tag,"listen":listen,"listen_port":int(port),
  "users":[{"uuid":uuid,"flow":"xtls-rprx-vision","name":tag}],
  "tls":{
    "enabled":True,
    "server_name":sni,
    "reality":{
      "enabled":True,
      "handshake":{"server":sni,"server_port":443},
      "private_key":priv,
      "short_id":[sid],
      "max_time_difference":"0s"
    }
  }
})
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2)
PY
  sbox_restart_safe
}

# add_hysteria2 <tag> <port> <auth> <sni> [obfs_password] [cert] [key]
sbox_add_hysteria2() {
  local tag="$1" port="$2" auth="$3" sni="$4" obfspw="$5"
  local crt="$HY2_DIR/selfsigned.crt" key="$HY2_DIR/selfsigned.key"
  if [ ! -f "$crt" ]; then
    mkdir -p "$HY2_DIR"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$key" -out "$crt" -days 3650 -nodes -subj "/CN=${sni}" >/dev/null 2>&1
    chmod 600 "$key"
  fi
  backup_file "$SBOX_CONF"
  python3 - "$SBOX_CONF" "$tag" "$port" "$auth" "$sni" "$obfspw" "$crt" "$key" <<'PY'
import json,sys
(p,tag,port,auth,sni,obfspw,crt,key)=sys.argv[1:9]
d=json.load(open(p))
d.setdefault("inbounds",[])
d["inbounds"]=[i for i in d["inbounds"] if i.get("tag")!=tag]
ino={
  "type":"hysteria2","tag":tag,"listen":"::","listen_port":int(port),
  "users":[{"password":auth}],
  "tls":{"enabled":True,"server_name":sni,"alpn":["h3"],
         "certificate_path":crt,"key_path":key},
  "up_mbps":500,"down_mbps":500
}
if obfspw:
    ino["obfs"]={"type":"salamander","password":obfspw}
d["inbounds"].append(ino)
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2)
PY
  sbox_restart_safe && open_port "$port" udp
}

# add_socks <tag> <port> <user> <pass>
sbox_add_socks() {
  local tag="$1" port="$2" user="$3" pass="$4"
  backup_file "$SBOX_CONF"
  python3 - "$SBOX_CONF" "$tag" "$port" "$user" "$pass" <<'PY'
import json,sys
(p,tag,port,user,passwd)=sys.argv[1:6]
d=json.load(open(p))
d.setdefault("inbounds",[])
d["inbounds"]=[i for i in d["inbounds"] if i.get("tag")!=tag]
d["inbounds"].append({
  "type":"socks","tag":tag,"listen":"::","listen_port":int(port),
  "users":[{"username":user,"password":passwd}]
})
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2)
PY
  sbox_restart_safe
}

sbox_remove_inbound() {
  local tag="$1"
  backup_file "$SBOX_CONF"
  python3 - "$SBOX_CONF" "$tag" <<'PY'
import json,sys
p,tag=sys.argv[1:3]
d=json.load(open(p))
d["inbounds"]=[i for i in d.get("inbounds",[]) if i.get("tag")!=tag]
json.dump(d, open(p,"w"), ensure_ascii=False, indent=2)
PY
  sbox_restart_safe && ok "已删除入站 $tag"
}

sbox_list_inbounds() {
  python3 - "$SBOX_CONF" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1]))
for i in d.get("inbounds",[]):
    print("  %-22s %-10s %s" % (i.get("tag","-"), i.get("type","-"), i.get("listen_port","-")))
PY
}
