#!/usr/bin/env bash
# Public-repo leak gate: fail if local identifiers sneak in.
# Customize the PATTERN list for your own identifiers before publishing.
set -uo pipefail
cd "$(dirname "$0")"
PATTERNS=(
  "192\.168\.[0-9]\+\.[0-9]\+"
  "10\.126\.[0-9]\+\.[0-9]\+"
  "38\.175\.[0-9]\+\.[0-9]\+"
  "oc_[a-z0-9]\{16,\}"
  "wx7[0-9a-f]\{15\}"
  "gho_[A-Za-z0-9]\{20,\}"
  "github_pat_"
  "sk-[A-Za-z0-9]\{20,\}"
  "/root/git-crypt"
  "gbrain-personal"
)
WARN_PATTERNS=(
  "herman6888"
)
LEAKS=0
for p in "${WARN_PATTERNS[@]}"; do
  hits=$(grep -rln --exclude-dir=.git -E "$p" . 2>/dev/null | grep -v "sanitise-check.sh")
  [ -n "$hits" ] && echo "WARN [$p] 出现于: $(echo "$hits" | tr '\n' ' ')（作者署名/URL 可接受）"
done
for p in "${PATTERNS[@]}"; do
  hits=$(grep -rn --exclude-dir=.git -E "$p" . 2>/dev/null | grep -v "sanitise-check.sh")
  if [ -n "$hits" ]; then
    echo "LEAK [$p]:"; echo "$hits" | head -5; LEAKS=$((LEAKS+1))
  fi
done
# binary files should not exist in a template repo
bins=$(find . -path ./.git -prune -o -type f -print | xargs file 2>/dev/null | grep -v "text\|JSON\|empty" | head -5)
[ -n "$bins" ] && { echo "非文本文件:"; echo "$bins"; LEAKS=$((LEAKS+1)); }
[ $LEAKS -eq 0 ] && echo "扫描通过 ✅ 无本地数据泄漏" || { echo "发现 $LEAKS 类泄漏 ⚠️"; exit 1; }
