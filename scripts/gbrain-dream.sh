#!/usr/bin/env bash
# Nightly dream: reflection/pattern synthesis + lint/backlinks/embed + skill audit.
# Context discipline: dream.synthesize.max_turns capped in gbrain config (configure.sh)
# — protects a shared local inference pool from being blown out by long contexts.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
export TZ GBRAIN_HOME="$HOME"
REPO="$HOME/Projects/gbrain"
LOG="$REPO/.logs/dream-$(date +%F).log"; mkdir -p "$REPO/.logs"
{
  echo "===== dream start $(date '+%F %T %Z') ====="
  gbrain dream --dir "$REPO" 2>&1
  echo "-- skill audit (proposals only; pruning is human-gated) --"
  python3 scripts/skill_audit.py --report 2>&1 || echo "WARN: skill audit failed (non-fatal)"
  echo "===== dream end $(date '+%F %T %Z') ====="
} >> "$LOG" 2>&1
