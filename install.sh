#!/usr/bin/env bash
# hermes-memory-stack installer — dependencies + services. Idempotent.
# Reads .env. Package commands assume Arch (pacman); adapt the PKG block for Debian/Ubuntu.
set -uo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "缺少 .env（cp .env.example .env 并填写）"; exit 1; }
set -a; . ./.env; set +a
SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"

echo "== [1/5] 基础依赖 =="
if command -v pacman >/dev/null; then
  $SUDO pacman -S --noconfirm git-crypt zstd sqlite rsync bun
elif command -v apt-get >/dev/null; then
  $SUDO apt-get install -y git-crypt zstd sqlite3 rsync
fi
command -v docker >/dev/null || { echo "请先安装 docker（官方脚本或发行版包）"; exit 1; }

echo "== [2/5] Hermes Agent =="
command -v hermes >/dev/null || curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

echo "== [3/5] gbrain（素材层）=="
if ! command -v gbrain >/dev/null; then
  git clone "${GBRAIN_UPSTREAM_URL:-https://github.com/garrytan/gbrain}" ~/Projects/gbrain-upstream
  ( cd ~/Projects/gbrain-upstream && bun install -g . )
fi
gbrain --version

echo "== [4/5] 数据服务 =="
mkdir -p "$STACK_DATA_DIR" "$OV_DATA_DIR"
cp -n templates/ov.conf.example "$OV_DATA_DIR/ov.conf" 2>/dev/null || \
  echo "提示：$OV_DATA_DIR/ov.conf 已存在，检查端点/密钥占位符"
docker compose up -d
echo "等待 postgres 就绪..."
for i in $(seq 1 30); do docker exec "$POSTGRES_CONTAINER" pg_isready -q && break; sleep 2; done

echo "== [5/5] gbrain 工作区 =="
if [ -d ~/Projects/gbrain/.git ]; then
  git -C ~/Projects/gbrain pull --rebase || true
else
  git clone "$GBRAIN_REPO_URL" ~/Projects/gbrain
fi

echo
echo "完成。下一步：./configure.sh"
