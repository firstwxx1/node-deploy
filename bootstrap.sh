#!/usr/bin/env bash
# =====================================================================
#  bootstrap.sh — 远端一键部署入口（在新 VPS 上直接跑这一条）
#
#  A. 有 git（推荐，最稳）:
#     git clone --depth 1 https://github.com/firstwxx1/node-deploy.git /tmp/nd \
#       && sudo bash /tmp/nd/deploy.sh --yes
#
#  B. 什么都没有，只有 curl:
#     curl -fsSL https://github.com/firstwxx1/node-deploy/raw/main/bootstrap.sh | sudo bash
#     （若 raw.githubusercontent 被重置，改用下面的 codeload 直链）
#     curl -fsSL https://codeload.github.com/firstwxx1/node-deploy/tar.gz/refs/heads/main \
#       -o /tmp/nd.tgz && mkdir -p /tmp/nd && tar -xzf /tmp/nd.tgz -C /tmp/nd --strip-components=1 \
#       && sudo bash /tmp/nd/deploy.sh --yes
#
#  C. 本机（Linux/mac）远程推:
#     bash bootstrap.sh --host root:密码@1.2.3.4 --profile all
# =====================================================================
set -uo pipefail

REPO="firstwxx1/node-deploy"
DIR="/tmp/node-deploy"
MIRRORS_DEFAULT="https://gh-proxy.com/,https://ghfast.top/,https://gh.llkk.cc/"

# ---- 本机远程模式 ----
if [ "${1:-}" = "--host" ] || [ "${1:-}" = "--servers" ]; then
  cd "$(dirname "$0")"
  command -v python3 >/dev/null 2>&1 || { echo "需要 python3"; exit 1; }
  python3 -c "import paramiko" 2>/dev/null || python3 -m pip install --quiet paramiko
  exec python3 tools/deploy_remote.py "$@"
fi

# ---- 远端自部署模式 ----
[ "$(id -u)" = "0" ] || { echo "请用 root 运行（或 sudo bash bootstrap.sh）"; exit 1; }
echo "[bootstrap] 获取 node-deploy ..."

rm -rf "$DIR"; mkdir -p "$DIR"
if command -v git >/dev/null 2>&1; then
  git clone --depth 1 "https://github.com/${REPO}.git" "$DIR" >/dev/null 2>&1 && echo "[bootstrap] git clone 成功"
fi

if [ ! -f "$DIR/deploy.sh" ]; then
  echo "[bootstrap] git 不可用，改用源码包（自动尝试镜像）"
  ok=0
  for prefix in "" $(printf '%s' "$MIRRORS_DEFAULT" | tr ',' ' '); do
    if curl -fsSL --noproxy '*' --max-time 90 "${prefix}https://codeload.github.com/${REPO}/tar.gz/refs/heads/main" -o /tmp/nd.tgz 2>/dev/null \
       && [ -s /tmp/nd.tgz ]; then
      tar -xzf /tmp/nd.tgz -C "$DIR" --strip-components=1 && { ok=1; echo "[bootstrap] 源码包就绪（${prefix:-直连}）"; break; }
    fi
  done
  [ "$ok" = "1" ] || { echo "[bootstrap] 下载失败。请手动上传 node-deploy 目录后运行 deploy.sh"; exit 1; }
fi

cd "$DIR"
chmod +x deploy.sh
echo "[bootstrap] 开始部署"
exec bash deploy.sh "$@"
