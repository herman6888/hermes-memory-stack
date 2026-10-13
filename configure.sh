#!/usr/bin/env bash
# Post-install configuration: gbrain config keys, OpenViking keys, systemd timers, skills.
set -uo pipefail
cd "$(dirname "$0")"; ROOT="$PWD"
set -a; . ./.env; set +a
FAILS=0

echo "== gbrain workspace（~/Projects/gbrain）=="
if [ ! -d "$HOME/Projects/gbrain/.git" ]; then
  if [[ "$GBRAIN_REPO_URL" != *REPLACE_ME* ]]; then
    git clone "$GBRAIN_REPO_URL" ~/Projects/gbrain || { echo "X clone 工作区失败: $GBRAIN_REPO_URL"; exit 1; }
  else
    echo "  无私有工作区仓库（GBRAIN_REPO_URL=REPLACE_ME）→ 本地 git init 起步"
    mkdir -p ~/Projects/gbrain && cd ~/Projects/gbrain && git init -b main -q
  fi
fi
cd ~/Projects/gbrain
[ -f .gbrainignore ] || touch .gbrainignore
gbrain init-db --yes 2>/dev/null || echo "  （init-db 跳过：库已存在）"

echo "== gbrain 配置（provider 前缀 + 本地零价格注册；与 VM 实测配方一致）=="
EP="${EMBED_PROVIDER:-lmstudio}"; CP="${CHAT_PROVIDER:-lmstudio}"
# gbrain ≥0.60.177 对 embed 调用有付费成本闸门：本地端点注册零价格
gbrain pricing set "$EP:$EMBED_MODEL" --rate 0 --source local 2>/dev/null || true
gbrain pricing set "$CP:$CHAT_MODEL" --rate 0 --source local 2>/dev/null || true
# LM Studio provider 读 LMSTUDIO_BASE_URL 环境变量（写回 .env 供 systemd EnvironmentFile 用）
if [ "$EP" = lmstudio ] && ! grep -q '^LMSTUDIO_BASE_URL=' .env 2>/dev/null; then
    echo "LMSTUDIO_BASE_URL=$EMBED_BASE_URL" >> .env; export LMSTUDIO_BASE_URL="$EMBED_BASE_URL"
fi
gbrain config set engine postgres 2>/dev/null
gbrain config set database_url "postgresql://${PG_USER}:${PG_PASSWORD}@127.0.0.1:${PG_PORT}/gbrain" || FAILS=$((FAILS+1))
# embed 模型走 migrate embeddings（v0.60.x 真正的配置平面），config set 会被忽略
gbrain migrate embeddings --to "$EP:$EMBED_MODEL" --dim "$EMBED_DIM" --yes --max-cost-usd 5 \
    || { echo "  重试 --retarget…"; gbrain migrate embeddings --to "$EP:$EMBED_MODEL" --dim "$EMBED_DIM" --yes --retarget --max-cost-usd 5; } \
    || FAILS=$((FAILS+1))
gbrain config set chat_model "$CP:$CHAT_MODEL" 2>/dev/null || gbrain config set chat_model "$CP:$CHAT_MODEL" --force || FAILS=$((FAILS+1))
gbrain config set provider_base_urls "{\"$EP\":\"${EMBED_BASE_URL}\",\"$CP\":\"${CHAT_BASE_URL}\"}" 2>/dev/null \
    || gbrain config set provider_base_urls "{\"$EP\":\"${EMBED_BASE_URL}\",\"$CP\":\"${CHAT_BASE_URL}\"}" --force || FAILS=$((FAILS+1))
[ -n "${OPENAI_API_KEY:-}" ] && export OPENAI_API_KEY
# 长转录分块（超长页不截断）：
gbrain config set chunk_overlap_chars 2000 2>/dev/null || true
# dream 上下文硬上限（共享本地推理池必备）：
gbrain config set dream.synthesize.max_turns 8 2>/dev/null || gbrain config set dream.synthesize.max_turns 8 --force || true
gbrain sync --repo ~/Projects/gbrain --no-pull || echo "WARN: 首次 sync 需要 DB 建好（install.sh 已建）"
gbrain embed --stale || true

echo "== OpenViking：生成 ov.conf（缺时）+ 用 admin API 发 user key =="
mkdir -p "$OV_DATA_DIR"
if [ ! -f "$OV_DATA_DIR/ov.conf" ]; then
  OV_ROOT_KEY=$(openssl rand -hex 24)
  sed -e "s|<REPLACE: embedding 模型名>|$EMBED_MODEL|" \
      -e "s|<REPLACE: http://<LLM_HOST>:<PORT>/v1>|$EMBED_BASE_URL|g" \
      -e "s|<REPLACE: 对话模型名>|$CHAT_MODEL|" \
      -e "s|\"api_key\": \"<REPLACE>\"|\"api_key\": \"local\"|g" \
      -e "s|<REDACTED: 生成一个强随机 key>|$OV_ROOT_KEY|" \
      "$ROOT/templates/ov.conf.example" > "$OV_DATA_DIR/ov.conf"
  echo "  已生成 $OV_DATA_DIR/ov.conf（root key 随机）；重建容器生效：docker compose up -d openviking"
  docker compose -f "$ROOT/docker-compose.yml" up -d --force-recreate openviking 2>/dev/null && sleep 20
fi
OV_KEY=$(grep -o '"root_api_key":[^,}]*' "$OV_DATA_DIR/ov.conf" | sed 's/.*: *//; s/"//g')
# OV v0.5.x: admin users API is per-account; discover the account id (default on fresh installs)
OV_ACCT=$(curl -sf "http://127.0.0.1:${OV_PORT}/api/v1/admin/accounts" -H "Authorization: Bearer $OV_KEY" \
  | sed -n 's/.*"account_id":"\([^"]*\)".*/\1/p' | head -1)
OV_ACCT=${OV_ACCT:-default}
curl -sf -X POST "http://127.0.0.1:${OV_PORT}/api/v1/admin/accounts/${OV_ACCT}/users" \
  -H "Authorization: Bearer $OV_KEY" -H "Content-Type: application/json" \
  -d '{"user_name":"agent"}' | tee /tmp/ov-user.json || { echo "WARN: OV admin API 建 user 失败，检查容器日志"; FAILS=$((FAILS+1)); }
echo "→ 把返回的 user key 填入 Hermes 配置（memory backend = openviking），见 templates/SOUL-memory-discipline.md 同级的 hermes 记忆配置说明"

echo "== Hermes：memory MD 宪章行 =="
mkdir -p ~/.hermes/memories
grep -q "Memory = " ~/.hermes/memories/memory.md 2>/dev/null || \
  printf 'Memory = 只存与所有会话相关的事实；其余全部进素材层/skills。\n' >> ~/.hermes/memories/memory.md
cat "$ROOT/templates/SOUL-memory-discipline.md" >> ~/.hermes/SOUL.md

echo "== skills =="
mkdir -p ~/.hermes/skills
cp -r "$ROOT/skills/"* ~/.hermes/skills/
cp "$ROOT/scripts/skill_audit.py" ~/.hermes/scripts/ 2>/dev/null || { mkdir -p ~/.hermes/scripts; cp "$ROOT/scripts/skill_audit.py" ~/.hermes/scripts/; }

echo "== systemd timers（gbrain daily/dream + 备份见 scripts/backup-*.sh）=="
mkdir -p ~/.config/systemd/user
for u in gbrain-daily gbrain-dream brain-backup-daily brain-backup-weekly; do
  sed "s|__STACK_DIR__|$ROOT|g; s|__GBRAIN_DIR__|$HOME/Projects/gbrain|g" \
    "$ROOT/scripts/systemd/$u.service" > ~/.config/systemd/user/$u.service
  cp "$ROOT/scripts/systemd/$u.timer" ~/.config/systemd/user/$u.timer
done
systemctl --user daemon-reload
systemctl --user enable --now gbrain-daily.timer gbrain-dream.timer brain-backup-daily.timer brain-backup-weekly.timer

echo "== 备份仓库（私有，git-crypt）=="
if [[ "$BACKUP_REPO_URL" == *REPLACE_ME* ]]; then
  echo "  跳过：BACKUP_REPO_URL 未配置（配好 .env 后重跑 configure.sh 即可接入备份）"
elif [ ! -d "$BACKUP_LOCAL_DIR" ]; then
  git clone "$BACKUP_REPO_URL" "$BACKUP_LOCAL_DIR" && ( cd "$BACKUP_LOCAL_DIR" && git-crypt unlock "$GIT_CRYPT_KEY" )
fi

echo
[ $FAILS -eq 0 ] && echo "configure 完成 ✅ 下一步：./scripts/restore.sh（有备份）或开始使用" \
                 || echo "configure 有 $FAILS 处失败，见上 ⚠️"
