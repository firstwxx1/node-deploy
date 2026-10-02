#!/usr/bin/env bash
# lib/links.sh — 分享链接 / 订阅 / 客户端配置生成
# 产物全部落在 /etc/node-deploy/，方便随时 --list 重新导出。
#
# 链接格式（v2rayN / NekoBox / sing-box / Clash Meta 通用）：
#   vless://<uuid>@<host>:<port>?encryption=none&security=reality&flow=xtls-rprx-vision
#          &type=tcp&sni=<sni>&fp=chrome&pbk=<pub>&sid=<sid>#<label>
#   hysteria2://<auth>@<host>:<port>?insecure=1&sni=<sni>&obfs=salamander
#          &obfs-password=<pw>&mport=<lo>-<hi>#<label>
#   socks5://<user>:<pass>@<host>:<port>#<label>

reg_vless() {
  local host="$1" port="$2" label="$3" uuid="$4" sni="$5" pbk="$6" sid="$7" flow="${8:-xtls-rprx-vision}"
  local link="vless://${uuid}@${host}:${port}?encryption=none&security=reality&flow=${flow}&type=tcp&sni=$(urlenc "$sni")&fp=chrome&pbk=${pbk}&sid=${sid}#$(urlenc "$label")"
  node_registry_add "$(printf '{"type":"vless","label":"%s","host":"%s","port":%s,"link":"%s","params":{"uuid":"%s","flow":"%s","sni":"%s","pbk":"%s","sid":"%s","fp":"chrome"}}' \
    "$(jesc "$label")" "$host" "$port" "$(jesc "$link")" "$(jesc "$uuid")" "$(jesc "$flow")" "$(jesc "$sni")" "$(jesc "$pbk")" "$(jesc "$sid")")"
  printf '%s\n' "$link"
}

reg_hy2() {
  local host="$1" port="$2" label="$3" auth="$4" sni="$5" obfspw="$6" mport="$7"
  local q="insecure=1&sni=$(urlenc "$sni")"
  [ -n "$obfspw" ] && q="${q}&obfs=salamander&obfs-password=$(urlenc "$obfspw")"
  [ -n "$mport" ]  && q="${q}&mport=${mport}"
  local link="hysteria2://$(urlenc "$auth")@${host}:${port}?${q}#$(urlenc "$label")"
  node_registry_add "$(printf '{"type":"hysteria2","label":"%s","host":"%s","port":%s,"link":"%s","params":{"auth":"%s","sni":"%s","obfs_password":"%s","mport":"%s","insecure":true}}' \
    "$(jesc "$label")" "$host" "$port" "$(jesc "$link")" "$(jesc "$auth")" "$(jesc "$sni")" "$(jesc "$obfspw")" "$(jesc "$mport")")"
  printf '%s\n' "$link"
}

reg_socks5() {
  local host="$1" port="$2" label="$3" user="$4" pass="$5"
  local link="socks5://$(urlenc "$user"):$(urlenc "$pass")@${host}:${port}#$(urlenc "$label")"
  node_registry_add "$(printf '{"type":"socks5","label":"%s","host":"%s","port":%s,"link":"%s","params":{"username":"%s","password":"%s"}}' \
    "$(jesc "$label")" "$host" "$port" "$(jesc "$link")" "$(jesc "$user")" "$(jesc "$pass")")"
  printf '%s\n' "$link"
}

# ------------------------------------------------ 导出
export_links() {
  [ -s "$LINK_JSON" ] || { warn "还没有已部署节点"; return 0; }
  python3 - "$LINK_JSON" "$LINK_FILE" "$STATE_DIR/sub.txt" "$STATE_DIR/client-singbox.json" "$STATE_DIR/client-clash.yaml" "$PUBLIC_IP" <<'PY'
import json,sys,base64
pj,pt,psub,pbox,pclash,host = sys.argv[1:7]
d=json.load(open(pj))
nodes=d.get("nodes",[])
lines=[n["link"] for n in nodes]
open(pt,"w").write("\n".join(lines)+"\n")
open(psub,"w").write(base64.b64encode(("\n".join(lines)+"\n").encode()).decode()+"\n")

def box_out(n):
    t=n["type"]; pr=n.get("params",{})
    o={"tag":n["label"],"server":n["host"],"server_port":int(n["port"])}
    if t=="vless":
        o["type"]="vless"; o["uuid"]=pr["uuid"]; o["flow"]=pr.get("flow","xtls-rprx-vision")
        o["tls"]={"enabled":True,"server_name":pr["sni"],"utls":{"enabled":True,"fingerprint":pr.get("fp","chrome")},
                  "reality":{"enabled":True,"public_key":pr["pbk"],"short_id":pr["sid"]}}
    elif t=="hysteria2":
        o["type"]="hysteria2"; o["password"]=pr["auth"]
        o["tls"]={"enabled":True,"server_name":pr["sni"],"insecure":True,"alpn":["h3"]}
        if pr.get("obfs_password"):
            o["obfs"]={"type":"salamander","password":pr["obfs_password"]}
    elif t=="socks5":
        o["type"]="socks"; o["version"]="5"; o["username"]=pr["username"]; o["password"]=pr["password"]
    return o

sb={"log":{"level":"info"},
    "outbounds":[{"type":"selector","tag":"select","outbounds":[n["label"] for n in nodes]}]+[box_out(n) for n in nodes]}
json.dump(sb, open(pbox,"w"), ensure_ascii=False, indent=2)

def clash(n):
    t=n["type"]; pr=n.get("params",{})
    base={"name":n["label"],"server":n["host"],"port":int(n["port"]),"type":t.upper() if t!="hysteria2" else "hysteria2"}
    if t=="vless":
        base.update({"uuid":pr["uuid"],"flow":pr.get("flow","xtls-rprx-vision"),"tls":True,
                     "servername":pr["sni"],"reality-opts":{"public-key":pr["pbk"],"short-id":pr["sid"]},
                     "client-fingerprint":pr.get("fp","chrome"),"network":"tcp","packet-addr":True})
    elif t=="hysteria2":
        base.update({"password":pr["auth"],"sni":pr["sni"],"skip-cert-verify":True})
        if pr.get("obfs_password"): base["obfs-opts"]={"mode":"salamander","password":pr["obfs_password"]}
    elif t=="socks5":
        base={"name":n["label"],"type":"socks5","server":n["host"],"port":int(n["port"]),
              "username":pr["username"],"password":pr["password"],"udp":True}
    return base

import io
y=io.StringIO()
y.write("mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: info\nipv6: true\n")
y.write("proxies:\n")
for n in nodes:
    c=clash(n); first=True
    for k,v in c.items():
        val=json.dumps(v,ensure_ascii=False) if isinstance(v,(bool,dict,int)) else '"%s"'%v
        y.write(("  - " if first else "    ")+"%s: %s\n"%(k,val)); first=False
y.write("proxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n")
for n in nodes: y.write("      - %s\n"%n["label"])
y.write("rules:\n  - MATCH,PROXY\n")
open(pclash,"w").write(y.getvalue())
PY
  ok "已导出: $LINK_FILE · $STATE_DIR/sub.txt · client-singbox.json · client-clash.yaml"
}

show_links() {
  [ -s "$LINK_JSON" ] || { warn "还没有已部署节点。先跑：bash deploy.sh --profile all"; return 0; }
  printf "\n${C_BLD}========== 节点链接 ==========${C_OFF}\n\n"
  python3 - "$LINK_JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for n in d.get("nodes",[]):
    print("  [%s] %s  %s:%s" % (n["type"].upper(), n["label"], n["host"], n["port"]))
    print("    %s" % n["link"])
    print()
PY
}

# 文本二维码（终端直出；手机扫不了就用 links.txt）
show_qr() {
  local link="$1"
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$link" | qrencode -t ANSIUTF8
  elif python3 -c "import segno" >/dev/null 2>&1; then
    python3 -c "import segno,sys;q=segno.make(sys.argv[1]);q.terminal(compact=True)" "$link"
  else
    log "未安装 qrencode，跳过二维码（apt install qrencode 可用）"
  fi
}
