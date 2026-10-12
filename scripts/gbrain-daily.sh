#!/usr/bin/env bash
# Daily material-layer maintenance: transcripts ingest + sync + extract + embed.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
export TZ GBRAIN_HOME="$HOME"
REPO="$HOME/Projects/gbrain"
LOG="$REPO/.logs/daily-$(date +%F).log"; mkdir -p "$REPO/.logs"
{
  echo "===== daily start $(date '+%F %T %Z') ====="
  echo "-- pull --"; git -C "$REPO" pull --rebase 2>&1 || true
  echo "-- transcripts ingest --"; gbrain transcripts ingest --all 2>&1 || echo "WARN: ingest failed (non-fatal)"
  echo "-- sync --"; gbrain sync --repo "$REPO" --no-pull 2>&1
  echo "-- extract --"; gbrain extract --stale 2>&1
  # 冷启动预热本地 embedding 模型（冷加载会撞上请求超时引发重试风暴）；
  # 批量要大：串行服务的单请求成本固定，小批量=排队。
  echo "-- embed warmup --"
  curl -s --max-time 90 -o /dev/null -X POST "$EMBED_BASE_URL/embeddings" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$EMBED_MODEL\",\"input\":\"warmup\"}" && echo "warmup ok" || echo "WARN: warmup failed"
  echo "-- embed --"; gbrain embed --stale --batch-size 64 2>&1
  echo "===== daily end $(date '+%F %T %Z') ====="
} >> "$LOG" 2>&1
