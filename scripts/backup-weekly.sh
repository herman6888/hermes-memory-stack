#!/usr/bin/env bash
# WEEKLY backup = full binaries (with vectors), split <95MB (GitHub per-file cap),
# keep $WEEKLY_KEEP copies. Success prints one heartbeat line; failure alerts + nonzero.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
REPO="$BACKUP_LOCAL_DIR"; WK="$(date +%G-W%V)"; STAGE="$REPO/.stage"
OK=1; MSG=""; fail(){ OK=0; MSG="$MSG; $*"; }
cd "$REPO" || { echo "brain-backup 周备份失败：仓库不存在"; exit 1; }
mkdir -p weekly secrets "$STAGE"
JOBS=$(nproc); [ "$JOBS" -gt 6 ] && JOBS=6

# --- 1. gbrain full dump (with vectors) + verify ---
docker exec "$POSTGRES_CONTAINER" pg_dump -U "$PG_USER" -d gbrain -Fc --no-owner \
  > "$STAGE/gbrain-full-$WK.dump" 2>"$STAGE/.pg.err" \
  && pg_restore --list "$STAGE/gbrain-full-$WK.dump" >/dev/null 2>&1 \
  && split -b 95m -d "$STAGE/gbrain-full-$WK.dump" "weekly/gbrain-full-$WK.dump.part" \
  || fail "pg 全量 dump/校验失败"

# --- 2. OpenViking data (gate on zstd -t, never on tar exit code: live dirs have sockets) ---
tar --warning=no-file-changed --exclude='*.sock' --exclude='*.lock' --exclude='*.pid' \
    -cf - -C "$(dirname "$OV_DATA_DIR")" "$(basename "$OV_DATA_DIR")" 2>/dev/null \
  | zstd -q -T"$JOBS" -3 -o "$STAGE/ov-data-$WK.tar.zst"
zstd -t "$STAGE/ov-data-$WK.tar.zst" 2>/dev/null && [ -s "$STAGE/ov-data-$WK.tar.zst" ] \
  && split -b 95m -d "$STAGE/ov-data-$WK.tar.zst" "weekly/ov-data-$WK.tar.zst.part" \
  || fail "OV 打包/校验失败"

# --- 3. hermes sqlite state (WAL-safe .backup) ---
SDIR="$STAGE/hermes-state"; rm -rf "$SDIR"; mkdir -p "$SDIR"
for db in "$HOME/.hermes/state.db" "$HOME/.hermes/kanban.db" "$HOME"/.hermes/profiles/*/state.db; do
  [ -f "$db" ] || continue
  rel=$(echo "$db" | sed "s|$HOME/.hermes/||; s|/|__|g")
  sqlite3 "$db" ".backup '$SDIR/$rel'" 2>/dev/null || fail "sqlite backup: $db"
done
tar -cf - -C "$STAGE" hermes-state 2>/dev/null | zstd -q -T"$JOBS" -3 -o "$STAGE/hermes-state-$WK.tar.zst"
zstd -t "$STAGE/hermes-state-$WK.tar.zst" 2>/dev/null \
  && split -b 95m -d "$STAGE/hermes-state-$WK.tar.zst" "weekly/hermes-state-$WK.tar.zst.part" \
  || fail "hermes state 打包/校验失败"

# --- 4. secrets snapshot ---
tar --warning=no-file-changed -czf "secrets/hermes-config-latest.tar.gz" -C "$HOME/.hermes" \
  --exclude='cache' --exclude='installs' --exclude='tools' --exclude='bin' --exclude='logs' \
  --exclude='*.wal' --exclude='*-shm' --exclude='*.bak*' --exclude='*.sock' \
  --exclude='*.lock' --exclude='*.pid' \
  config.yaml .env SOUL.md skills cron hooks memories scripts auth.json 2>/dev/null
tar -tzf secrets/hermes-config-latest.tar.gz >/dev/null || fail "secrets 校验失败"
cp secrets/hermes-config-latest.tar.gz "secrets/hermes-config-$WK.tar.gz"

# --- 5. retention (keep N weeks per series) ---
prune(){ ls -1tr $1 2>/dev/null | head -n -"$(( $2 * 9 ))" | xargs -r rm -f; }
prune "weekly/*.part*" "$WEEKLY_KEEP"
prune "secrets/hermes-config-20*.tar.gz" "$WEEKLY_KEEP"
rm -rf "$STAGE"

git add -A
git diff --cached --quiet || {
  git commit -q -m "weekly $WK$( [ $OK -eq 1 ] && echo ' (full)' || echo " (partial:$MSG)")"
  P=0; for i in 1 2 3; do git push -q origin main && { P=1; break; }; sleep 5; done
  [ $P -eq 0 ] && fail "git push 失败（大首推请配 VPS 中继，见 RESTORE.md）"
}
SZ=$(du -sh .git 2>/dev/null | cut -f1)
[ $OK -eq 0 ] && { echo "brain-backup 周备份部分失败：$MSG（.git=$SZ）"; exit 1; }
echo "brain-backup 周备份完成 $WK：全量已加密推送，仓库 .git=${SZ}"
