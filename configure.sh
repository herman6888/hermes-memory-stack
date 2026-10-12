#!/usr/bin/env bash
# Post-install configuration: gbrain config keys, OpenViking keys, systemd timers, skills.
set -uo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a
FAILS=0

echo "== gbrain 配置（键名与 v0.60.x 对齐；API key 走 provider_base_urls + 环境密钥）=="
cd ~/Projects/gbrain || exit 1
gbrain config set engine postgres 2>/dev/null
gbrain config set database_url "postgresql://${PG_USER}:${PG_PASSWORD}@127.0.0.1:${PG_PORT}/gbrain" || FAILS=$((FAILS+1))
gbrain config set embedding_model "openai:${EMBED_MODEL}" || FAILS=$((FAILS+1))
gbrain config set embedding_dimensions "$EMBED_DIM" || FAILS=$((FAILS+1))
gbrain config set chat_model "openai:${CHAT_MODEL}" || FAILS=$((FAILS+1))
gbrain config set provider_base_urls "{\"openai\":\"${EMBED_BASE_URL}\"}" || FAILS=$((FAILS+1))
# 长转录分块（超长页不截断）：
gbrain config set chunk_overlap_chars 2000 2>/dev/null || true
# dream 上下文硬上限（共享本地推理池必备）：
gbrain config set dream.synthesize.max_turns 8 || FAILS=$((FAILS+1))
gbrain sync --repo ~/Projects/gbrain --no-pull || echo "WARN: 首次 sync 需要 DB 建好（install.sh 已建）"
gbrain embed --stale || true

echo "== OpenViking：root key 在 ov.conf；用 admin API 发 user key =="
OV_KEY=$(grep -o '"root_api_key":[^,}]*' "$OV_DATA_DIR/ov.conf" | sed 's/.*: *//; s/"//g')
curl -sf -X POST "http://127.0.0.1:${OV_PORT}/api/v1/admin/users" \
  -H "Authorization: Bearer $OV_KEY" -H "Content-Type: application/json" \
  -d '{"user_name":"agent"}' | tee /tmp/ov-user.json || { echo "WARN: OV admin API 建 user 失败，检查容器日志"; FAILS=$((FAILS+1)); }
echo "→ 把返回的 user key 填入 Hermes 配置（memory backend = openviking），见 templates/SOUL-memory-discipline.md 同级的 hermes 记忆配置说明"

echo "== Hermes：memory MD 宪章行 =="
mkdir -p ~/.hermes/memories
grep -q "Memory = " ~/.hermes/memories/memory.md 2>/dev/null || \
  printf 'Memory = 只存与所有会话相关的事实；其余全部进素材层/skills。\n' >> ~/.hermes/memories/memory.md
cat templates/SOUL-memory-discipline.md >> ~/.hermes/SOUL.md

echo "== skills =="
mkdir -p ~/.hermes/skills
cp -r skills/* ~/.hermes/skills/
cp scripts/skill_audit.py ~/.hermes/scripts/ 2>/dev/null || { mkdir -p ~/.hermes/scripts; cp scripts/skill_audit.py ~/.hermes/scripts/; }

echo "== systemd timers（gbrain daily/dream + 备份见 scripts/backup-*.sh）=="
mkdir -p ~/.config/systemd/user
for u in gbrain-daily gbrain-dream brain-backup-daily brain-backup-weekly; do
  sed "s|__STACK_DIR__|$PWD|g; s|__GBRAIN_DIR__|$HOME/Projects/gbrain|g" \
    "scripts/systemd/$u.service" > ~/.config/systemd/user/$u.service
  cp "scripts/systemd/$u.timer" ~/.config/systemd/user/$u.timer
done
systemctl --user daemon-reload
systemctl --user enable --now gbrain-daily.timer gbrain-dream.timer brain-backup-daily.timer brain-backup-weekly.timer

echo "== 备份仓库（私有，git-crypt）=="
if [ ! -d "$BACKUP_LOCAL_DIR" ]; then
  git clone "$BACKUP_REPO_URL" "$BACKUP_LOCAL_DIR" && ( cd "$BACKUP_LOCAL_DIR" && git-crypt unlock "$GIT_CRYPT_KEY" )
fi

echo
[ $FAILS -eq 0 ] && echo "configure 完成 ✅ 下一步：./scripts/restore.sh（有备份）或开始使用" \
                 || echo "configure 有 $FAILS 处失败，见上 ⚠️"
