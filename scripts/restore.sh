#!/usr/bin/env bash
# Disaster recovery from the encrypted backup repo (assumes install.sh done).
# Ladder from smallest to largest scope — see docs/restore.md for context.
set -uo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a
B="$BACKUP_LOCAL_DIR"
[ -d "$B" ] || git clone "$BACKUP_REPO_URL" "$B"
( cd "$B" && git-crypt unlock "$GIT_CRYPT_KEY" ) || { echo "解锁失败：检查密钥 $GIT_CRYPT_KEY"; exit 1; }

LATEST_FULL=$(ls "$B"/weekly/gbrain-full-*.dump.part* 2>/dev/null | sed 's/\.part[0-9]*$//' | sort -u | tail -1)
LATEST_META=$(ls -1 "$B"/daily/gbrain-meta-*.sql 2>/dev/null | tail -1)
LATEST_CHUNKS=$(ls -1 "$B"/daily/gbrain-chunks-*.csv 2>/dev/null | tail -1)

echo "全量 dump: ${LATEST_FULL:-无}  | 文本增量: ${LATEST_META:-无}"
if [ -n "$LATEST_FULL" ]; then
  echo "→ 全量恢复（含向量，最快）"
  cat "$LATEST_FULL".part* > /tmp/restore-full.dump
  pg_restore -U "$PG_USER" -h 127.0.0.1 -p "$PG_PORT" -d gbrain --create --clean /tmp/restore-full.dump \
    || echo "WARN: pg_restore 有告警（--clean 对空库正常），检查上方输出"
  rm -f /tmp/restore-full.dump
elif [ -n "$LATEST_META" ]; then
  echo "→ 文本重建（慢，需重新 embed）"
  psql -U "$PG_USER" -h 127.0.0.1 -p "$PG_PORT" -d gbrain -f "$LATEST_META"
  COLS=$(head -1 "$LATEST_CHUNKS" | tr -d '"')
  psql -U "$PG_USER" -h 127.0.0.1 -p "$PG_PORT" -d gbrain \
    -c "\copy content_chunks($COLS) FROM '$LATEST_CHUNKS' CSV"
  ( cd ~/Projects/gbrain && gbrain embed --stale --batch-size 64 )
else
  echo "备份仓库为空 — 跳过素材层恢复"; fi

OV_LATEST=$(ls "$B"/weekly/ov-data-*.tar.zst.part* 2>/dev/null | sed 's/\.part[0-9]*$//' | sort -u | tail -1)
if [ -n "$OV_LATEST" ]; then
  echo "→ 恢复 OpenViking 数据"
  docker stop openviking
  cat "$OV_LATEST".part* | zstd -d | tar -x -f - -C "$(dirname "$OV_DATA_DIR")"
  docker start openviking
fi

HS_LATEST=$(ls "$B"/weekly/hermes-state-*.tar.zst.part* 2>/dev/null | sed 's/\.part[0-9]*$//' | sort -u | tail -1)
if [ -n "$HS_LATEST" ]; then
  read -rp "恢复 Hermes state.db（会覆盖现有会话状态）? [y/N] " a
  if [ "$a" = "y" ]; then
    mkdir -p /tmp/hs && cat "$HS_LATEST".part* | zstd -d | tar -x -f - -C /tmp/hs
    ( cd /tmp/hs/hermes-state && for f in *; do
        dest=$(echo "$f" | sed 's/__/\//g')
        mkdir -p "$(dirname "$HOME/.hermes/$dest")"
        mv "$f" "$HOME/.hermes/$dest"; done )
    rm -rf /tmp/hs
  fi
fi
echo "完成。验证：gbrain search <关键词> / viking_search / hermes cron list"
