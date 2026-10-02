#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
deploy_remote.py — 从本机一键把 node-deploy 推到远端 VPS 并执行部署。

只需本机装 paramiko：  python -m pip install paramiko
不需要远端有 git/网络（脚本与核心二进制都可由本地上传；核心默认在远端下载）。

用法
  # 单台
  python deploy_remote.py --host root:密码@1.2.3.4 --profile all --port 443
  # 多台（JSON 数组：[{"host":"1.2.3.4","user":"root","password":"x","args":"--port 8443"}]）
  python deploy_remote.py --servers servers.json
  # 只取链接（已部署过的机器）
  python deploy_remote.py --host root:密码@1.2.3.4 --list
  # 部署完写回 NodePanel 的 nodes.json
  python deploy_remote.py --servers servers.json --panel ../nodepanel/data/nodes.json
  # 本机已有核心二进制，走离线（远端下载不了时）
  python deploy_remote.py --host ... --offline-xray ./xray.zip --offline-hy2 ./hysteria
"""
import argparse, getpass, io, json, os, sys, tarfile, time, re
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import paramiko
except ImportError:
    sys.exit("缺少 paramiko，先执行: python -m pip install paramiko")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "links")


def log(msg, color=""):
    print(msg, flush=True)


def parse_target(s):
    # root:pass@1.2.3.4  |  1.2.3.4  |  user@1.2.3.4
    user, pwd, host = "root", None, None
    if "@" in s:
        left, host = s.rsplit("@", 1)
        if ":" in left:
            user, pwd = left.split(":", 1)
        else:
            user = left
    else:
        host = s
    return {"host": host, "user": user, "password": pwd}


def pack_repo():
    """把 node-deploy 目录打成 tar.gz 字节流（排除 .git/产物）"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name in sorted(os.listdir(ROOT)):
            if name in (".git", "links", "__pycache__", ".workbuddy"):
                continue
            tf.add(os.path.join(ROOT, name), arcname="node-deploy/" + name)
    return buf.getvalue()


class Box:
    def __init__(self, host, user="root", password=None, port=22, key=None):
        self.host, self.user, self.password, self.port, self.key = host, user, password, port, key
        self.cli = None
        self.sftp = None

    def connect(self):
        self.cli = paramiko.SSHClient()
        self.cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        kw = dict(hostname=self.host, username=self.user, port=self.port,
                  timeout=25, banner_timeout=25, allow_agent=False, look_for_keys=False)
        if self.key:
            kw["key_filename"] = self.key
        else:
            kw["password"] = self.password
        self.cli.connect(**kw)
        self.cli.get_transport().set_keepalive(30)
        self.sftp = self.cli.open_sftp()
        return self

    def run(self, cmd, timeout=900, quiet=False):
        _, out, err = self.cli.exec_command(cmd, timeout=timeout)
        buf = []
        for line in iter(out.readline, ""):
            buf.append(line)
            if not quiet:
                print("   | " + line.rstrip(), flush=True)
        code = out.channel.recv_exit_status()
        return code, "".join(buf), err.read().decode("utf-8", "ignore")

    def put_bytes(self, data, remote_path):
        with self.sftp.open(remote_path, "wb") as f:
            f.write(data)

    def close(self):
        try:
            self.sftp and self.sftp.close()
        except Exception:
            pass
        try:
            self.cli and self.cli.close()
        except Exception:
            pass


def remote_prepare(box, mirror=""):
    box.run("export DEBIAN_FRONTEND=noninteractive; "
            "command -v curl >/dev/null || (apt-get update -qq && apt-get install -y -qq curl) 2>/dev/null; "
            "command -v python3 >/dev/null || (apt-get update -qq && apt-get install -y -qq python3) 2>/dev/null; "
            "command -v tar >/dev/null || apt-get install -y -qq tar 2>/dev/null; true", quiet=True)


def deploy_one(target, args, offline=None, mirror=""):
    host = target["host"]
    print("\n" + "=" * 68)
    print("  %s  profile=%s engine=%s" % (host, args.get("profile", "all"), args.get("engine", "xray")))
    print("=" * 68)
    box = Box(host, target.get("user", "root"), target.get("password"), target.get("port", 22), target.get("key"))
    box.connect()
    try:
        remote_prepare(box, mirror)
        # 上传仓库
        data = pack_repo()
        box.put_bytes(data, "/tmp/node-deploy.tar.gz")
        # 包内顶层目录就是 node-deploy/，解到 /tmp 得到 /tmp/node-deploy
        code, _, e = box.run("rm -rf /tmp/node-deploy && mkdir -p /tmp/node-deploy && "
                             "tar -xzf /tmp/node-deploy.tar.gz -C /tmp && "
                             "ls /tmp/node-deploy/deploy.sh", timeout=120, quiet=True)
        if code != 0:
            raise RuntimeError("上传解包失败: %s" % e.strip())
        # 离线二进制
        if offline:
            for local, remote in offline.items():
                with open(local, "rb") as f:
                    box.put_bytes(f.read(), remote)
                print("   已上传离线包 -> %s" % remote)
        # 拼参数
        cmd = ["cd /tmp/node-deploy", "chmod +x deploy.sh"]
        flags = ["--yes"]
        for k in ("profile", "engine", "port", "sni", "uuid", "sid", "label",
                  "hy2-port", "hy2-hop", "hy2-auth", "hy2-obfs", "hy2-mode",
                  "socks-port", "socks-user", "socks-pass", "core-version"):
            v = args.get(k)
            if v not in (None, "", False):
                flags.append("--%s %s" % (k, v))
        for f in ("nginx-split", "no-hy2", "no-socks", "no-tune", "qr", "force"):
            if args.get(f):
                flags.append("--" + f)
        if mirror:
            cmd.append("export MIRRORS='%s'" % mirror)
        cmd.append("bash deploy.sh " + " ".join(flags))
        full = " && ".join(cmd) + " 2>&1"
        t0 = time.time()
        code, out, err = box.run(full, timeout=args.get("timeout", 1500))
        print("   用时 %.1fs  退出码 %d" % (time.time() - t0, code))
        if code != 0:
            print("   stderr: %s" % (err.strip()[-800:] or "(空)"))
            if not out.strip():
                print("   脚本无输出，检查 /tmp/node-deploy/deploy.sh 是否存在")
        # 取回链接
        _, links, _ = box.run("cat /etc/node-deploy/links.txt 2>/dev/null || echo ''", quiet=True)
        _, sub, _ = box.run("cat /etc/node-deploy/sub.txt 2>/dev/null || echo ''", quiet=True)
        _, meta, _ = box.run("cat /etc/node-deploy/links.json 2>/dev/null || echo '{}'", quiet=True)
        os.makedirs(OUT_DIR, exist_ok=True)
        safe = host.replace(".", "_")
        with open(os.path.join(OUT_DIR, "%s.txt" % safe), "w", encoding="utf-8") as f:
            f.write(links)
        try:
            nodes = json.loads(meta or "{}").get("nodes", [])
        except Exception:
            nodes = []
        return {"host": host, "ok": code == 0, "links": links.strip().splitlines(),
                "sub": sub.strip(), "nodes": nodes, "log": out[-4000:]}
    finally:
        box.close()


def list_one(target):
    box = Box(target["host"], target.get("user", "root"), target.get("password"),
              target.get("port", 22), target.get("key"))
    box.connect()
    try:
        box.run("cd /tmp/node-deploy 2>/dev/null || echo '（远端无部署脚本，仅读取已存链接）'", quiet=True)
        _, links, _ = box.run("cat /etc/node-deploy/links.txt 2>/dev/null || echo ''", quiet=True)
        _, meta, _ = box.run("cat /etc/node-deploy/links.json 2>/dev/null || echo '{}'", quiet=True)
        print("\n--- %s ---" % target["host"])
        print(links or "  （无）")
        try:
            return {"host": target["host"], "nodes": json.loads(meta or "{}").get("nodes", []),
                    "links": links.strip().splitlines()}
        except Exception:
            return {"host": target["host"], "nodes": [], "links": []}
    finally:
        box.close()


def write_panel(results, panel_path):
    """把新部署的节点写回 NodePanel 的 nodes.json"""
    if not os.path.exists(panel_path):
        print("面板文件不存在: %s" % panel_path)
        return
    d = json.load(open(panel_path, encoding="utf-8"))
    servers = {s["host"]: s for s in d.get("servers", [])}
    for r in results:
        host = r["host"]
        if host not in servers:
            sid = re.sub(r"\W", "", "box" + host.split(".")[-1])
            servers[host] = {"id": sid, "name": host, "host": host,
                             "ssh_user": "root", "ssh_pass": "",
                             "engine": "xray", "service": "xray",
                             "config_path": "/usr/local/etc/xray/config.json",
                             "core_bin": "/usr/local/bin/xray", "allowed_ports": []}
            d.setdefault("servers", []).append(servers[host])
        srv = servers[host]
        for n in r.get("nodes", []):
            p = n.get("params", {})
            nid = re.sub(r"[^a-z0-9-]", "", n["label"].lower())
            entry = {"id": nid, "server_id": srv["id"], "label": n["label"],
                     "protocol": n["type"], "port": int(n["port"]),
                     "inbound_tag": "%s-%s" % (n["type"], n["port"]), "params": p}
            if n["type"] == "hysteria2":
                entry["manage"] = {"config_path": "/etc/hysteria/config.yaml", "service": "hysteria-server"}
            elif n["type"] == "socks5":
                entry["manage"] = {"service": "danted", "config_path": "/etc/danted.conf"}
            d["nodes"] = [x for x in d.get("nodes", []) if x["id"] != nid]
            d.setdefault("nodes", []).append(entry)
    json.dump(d, open(panel_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("\n已写回面板: %s （%d 台服务器 / %d 个节点）" % (panel_path, len(d["servers"]), len(d["nodes"])))


def main():
    ap = argparse.ArgumentParser(description="node-deploy 远程一键部署器")
    ap.add_argument("--host", help="root:密码@IP")
    ap.add_argument("--servers", help="服务器列表 JSON 文件")
    ap.add_argument("--profile", default="all")
    ap.add_argument("--engine", default="xray")
    ap.add_argument("--port"), ap.add_argument("--sni"), ap.add_argument("--uuid"), ap.add_argument("--sid")
    ap.add_argument("--label")
    ap.add_argument("--hy2-port"), ap.add_argument("--hy2-hop"), ap.add_argument("--hy2-auth")
    ap.add_argument("--hy2-obfs"), ap.add_argument("--hy2-mode")
    ap.add_argument("--socks-port"), ap.add_argument("--socks-user"), ap.add_argument("--socks-pass")
    ap.add_argument("--core-version")
    ap.add_argument("--nginx-split", action="store_true")
    ap.add_argument("--no-hy2", action="store_true")
    ap.add_argument("--no-socks", action="store_true")
    ap.add_argument("--no-tune", action="store_true")
    ap.add_argument("--qr", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--yes", action="store_true", help="兼容标志，始终非交互")
    ap.add_argument("--list", action="store_true", help="只读取已部署链接")
    ap.add_argument("--offline-xray", help="本地 xray zip，上传为 /tmp/xray-offline.zip")
    ap.add_argument("--offline-hy2", help="本地 hysteria 二进制，上传为 /tmp/hysteria-offline")
    ap.add_argument("--offline-singbox", help="本地 sing-box tar.gz，上传为 /tmp/singbox-offline.tar.gz")
    ap.add_argument("--mirror", default="", help="GitHub 镜像前缀，逗号分隔")
    ap.add_argument("--panel", help="部署后写回 NodePanel 的 nodes.json 路径")
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=1500)
    a = ap.parse_args()

    if not a.host and not a.servers:
        sys.exit("需要 --host 或 --servers")

    targets = []
    if a.servers:
        raw = json.load(open(a.servers, encoding="utf-8"))
        if isinstance(raw, dict):
            raw = raw.get("servers", [])
        for t in raw:
            if "password" not in t and "key" not in t:
                t["password"] = getpass.getpass("%s 密码: " % t["host"])
            targets.append(t)
    else:
        t = parse_target(a.host)
        if not t["password"] and not t.get("key"):
            t["password"] = getpass.getpass("%s 密码: " % t["host"])
        targets.append(t)

    if a.list:
        results = []
        for t in targets:
            try:
                results.append(list_one(t))
            except Exception as e:
                print("%s 失败: %s" % (t["host"], e))
        return

    args = {k: v for k, v in vars(a).items()
            if k in ("profile", "engine", "port", "sni", "uuid", "sid", "label", "hy2_port", "hy2_hop",
                     "hy2_auth", "hy2_obfs", "hy2_mode", "socks_port", "socks_user", "socks_pass",
                     "core_version", "nginx_split", "no_hy2", "no_socks", "no_tune", "qr", "force", "timeout")
            and v not in (None, "", False)}
    # --hy2-port 之类要还原成连字符
    for k in list(args):
        args[k.replace("_", "-")] = args.pop(k)

    offline = {}
    if a.offline_xray:
        offline[a.offline_xray] = "/tmp/xray-offline.zip"
    if a.offline_hy2:
        offline[a.offline_hy2] = "/tmp/hysteria-offline"
    if a.offline_singbox:
        offline[a.offline_singbox] = "/tmp/singbox-offline.tar.gz"

    results = []
    with ThreadPoolExecutor(max_workers=min(a.parallel, len(targets))) as ex:
        futs = {ex.submit(deploy_one, t, dict(args), offline, a.mirror): t for t in targets}
        for f in as_completed(futs):
            t = futs[f]
            try:
                results.append(f.result())
            except Exception as e:
                print("\n%s 部署异常: %s" % (t["host"], e))
                results.append({"host": t["host"], "ok": False, "links": [], "nodes": [], "log": str(e)})

    # 汇总
    os.makedirs(OUT_DIR, exist_ok=True)
    agg = []
    for r in results:
        agg += r.get("links", [])
    if agg:
        with open(os.path.join(OUT_DIR, "all-links.txt"), "w", encoding="utf-8") as f:
            f.write("\n".join(agg) + "\n")
        import base64
        with open(os.path.join(OUT_DIR, "all-sub.txt"), "w", encoding="utf-8") as f:
            f.write(base64.b64encode(("\n".join(agg) + "\n").encode()).decode() + "\n")

    print("\n" + "=" * 68)
    print("  汇总：成功 %d / 共 %d" % (sum(1 for r in results if r.get("ok")), len(results)))
    print("=" * 68)
    for r in results:
        print("  %-18s %s  %d 条链接" % (r["host"], "OK" if r.get("ok") else "FAIL", len(r.get("links", []))))
        for l in r.get("links", []):
            print("       " + l)
    if agg:
        print("\n  全部链接: %s" % os.path.join(OUT_DIR, "all-links.txt"))
        print("  聚合订阅: %s" % os.path.join(OUT_DIR, "all-sub.txt"))

    if a.panel:
        write_panel(results, a.panel)


if __name__ == "__main__":
    main()
