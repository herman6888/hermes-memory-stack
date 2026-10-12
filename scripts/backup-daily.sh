#!/usr/bin/env bash
# DAILY backup = text increments to encrypted git repo.
# Pattern: script-only job; success = silent (empty stdout), failure = alert + nonzero exit.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
REPO="$BACKUP_LOCAL_DIR"; STAMP="$(date +%F)"
OK=1; MSG=""; fail(){ OK=0; MSG="$MSG; $*"; }
cd "$REPO" || { echo "备份失败：$REPO 不存在"; exit 1; }
mkdir -p daily hermes-config

# --- 1. gbrain: schema+pages SQL, exclude the vector-heavy table (regenerable) ---
if docker exec "$POSTGRES_CONTAINER" pg_dump -U "$PG_USER" -d gbrain --no-owner \
     --exclude-table=public.content_chunks > "daily/.meta.sql.tmp" 2>"daily/.pg.err"; then
  grep -q "PostgreSQL database dump complete" "daily/.meta.sql.tmp" \
    && mv "daily/.meta.sql.tmp" "daily/gbrain-meta-$STAMP.sql" \
    || { fail "pg_dump 截断"; rm -f "daily/.meta.sql.tmp"; }
else fail "pg_dump 失败: $(tail -1 daily/.pg.err 2>/dev/null)"; rm -f "daily/.meta.sql.tmp"; fi

# --- 2. content_chunks text columns via dynamic column list (vectors excluded) ---
COLS=$(docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d gbrain -Atc \
  "SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position)
     FROM information_schema.columns
    WHERE table_name='content_chunks'
      AND column_name NOT IN ('embedding','embedding_image','embedding_multimodal','search_vector')")
[ -n "$COLS" ] && docker exec "$POSTGRES_CONTAINER" psql -U "$PG_USER" -d gbrain \
  -c "\copy (SELECT $COLS FROM content_chunks) TO STDOUT CSV" > "daily/.chunks.csv.tmp" 2>"daily/.psql.err" \
  && mv "daily/.chunks.csv.tmp" "daily/gbrain-chunks-$STAMP.csv" \
  || { fail "chunks 导出失败"; rm -f "daily/.chunks.csv.tmp"; }

# --- 3. hermes config text snapshot (trailing slashes are load-bearing!) ---
SNAP="hermes-config/snap"; mkdir -p "$SNAP"
sync_one(){ local src="$1" dst; [ -e "$src" ] || return 0; dst="$SNAP/$(basename "$src")"
  if [ -d "$src" ]; then
    rsync -a --delete --delete-excluded --exclude '*.bak*' --exclude '*.lock' \
      "$src/" "$dst/" 2>/dev/null || fail "rsync: $src"
  else rsync -a "$src" "$SNAP/" 2>/dev/null || fail "rsync: $src"; fi; }
for p in SOUL.md config.yaml .env auth.json skills cron hooks memories scripts; do
  sync_one "$HOME/.hermes/$p"; done

# --- 4. workspace repo push (pages are source of truth, versioned separately) ---
( cd "$HOME/Projects/gbrain" && git add -A && git commit -m "backup-snapshot $STAMP" 2>/dev/null; \
  git push origin HEAD ) >/dev/null 2>&1 || true

# --- 5. retention + commit + push ---
find daily -name 'gbrain-meta-*.sql' -mtime +"$DAILY_KEEP_DAYS" -delete
find daily -name 'gbrain-chunks-*.csv' -mtime +"$DAILY_KEEP_DAYS" -delete
git add -A
git diff --cached --quiet || {
  git commit -q -m "daily $STAMP$( [ $OK -eq 1 ] && echo ' (ok)' || echo " (partial:$MSG)")"
  P=0; for i in 1 2 3; do git push -q origin main && { P=1; break; }; sleep 3; done
  [ $P -eq 0 ] && fail "git push 失败（直连 3 次；如网络受限参考 RESTORE.md 的 VPS 中继）"
}
git fsck --no-dangling >/dev/null 2>&1 || fail "git fsck 异常"
[ $OK -eq 0 ] && { echo "brain-backup 每日备份部分失败：$MSG"; exit 1; }
exit 0
