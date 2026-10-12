#!/usr/bin/env bash
# hermes-memory-stack installer — dependencies + services + data restore.
#
# Idempotent: every step checks whether the component is already present and
# SKIPS it, so re-running after a partial failure is safe. Output is a
# numbered step log:  ==> [n/N] what we're doing / ✓ done / ~ skipped.
#
#   ./install.sh              # install what's missing; asks about data restore
#   ./install.sh --restore    # also restore data from BACKUP_REPO_URL
set -uo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { cp .env.example .env; echo "已生成 .env —— 请先填写端点（或稍后由步骤5的配置向导完成）"; }
set -a; . ./.env; set +a
SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"

TOTAL=10; STEP=0
step() { STEP=$((STEP+1)); echo; echo "==> [$STEP/$TOTAL] $*"; }
ok()   { echo "      ✓ $*"; }
skip() { echo "      ~ 跳过：$*"; }
warn() { echo "      ! $*"; }
die()  { echo; echo "✗ 中止：$*"; echo "  修复后重跑本脚本即可——已完成的步骤会自动跳过。"; exit 1; }
ask()  { local a; read -rp "      ? $1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_pkg() { if has_cmd pacman; then pacman -Qi "$1" >/dev/null 2>&1
            elif has_cmd apt-get; then dpkg -s "$1" >/dev/null 2>&1; else return 1; fi; }
pg_ready() { docker exec "$POSTGRES_CONTAINER" pg_isready -q -U postgres >/dev/null 2>&1; }
ov_running() { [ -n "$(docker ps -q -f name=openviking 2>/dev/null)" ]; }

echo "=============================================================="
echo "  Hermes Memory Stack 安装（幂等：已装组件自动跳过）"
echo "=============================================================="

# ---- 1 系统检查 ------------------------------------------------------------
step "系统检查"
if has_cmd pacman; then ok "Arch 系（pacman）"
elif has_cmd apt-get; then ok "Debian/Ubuntu（apt）—— 本文脚本两者皆可"
else die "需要 pacman 或 apt 的 Linux 系统"; fi
grep -qE 'vmx|svm' /proc/cpuinfo || warn "CPU 无虚拟化扩展标志（虚拟机内正常，docker 不受影响）"

# ---- 2 基础包 ---------------------------------------------------------------
step "基础工具（git curl jq ripgrep zstd rsync sqlite git-crypt postgresql客户端）"
PKGS=()
for p in git curl jq ripgrep zstd rsync sqlite git-crypt postgresql-libs; do has_pkg "$p" || PKGS+=("$p"); done
if [ ${#PKGS[@]} -eq 0 ]; then
    skip "全部已安装"
else
    echo "      需安装：${PKGS[*]}"
    if has_cmd pacman; then
        $SUDO pacman -S --needed --noconfirm "${PKGS[@]}" || die "pacman 安装失败"
    else
        $SUDO apt-get update && $SUDO apt-get install -y git curl jq ripgrep zstd rsync sqlite3 git-crypt postgresql-client || die "apt 安装失败"
    fi
    ok "安装完成"
fi

# ---- 3 docker ---------------------------------------------------------------
step "Docker"
if has_cmd docker && docker info >/dev/null 2>&1; then
    skip "docker 已安装、守护进程运行中"
elif has_cmd docker; then
    echo "      启动 docker 服务…"
    $SUDO systemctl enable --now docker && ok "已启动并设为开机自启" || die "docker 服务启动失败"
else
    echo "      安装 docker…"
    if has_cmd pacman; then $SUDO pacman -S --needed --noconfirm docker docker-compose
    else $SUDO apt-get install -y docker.io docker-compose-plugin; fi || die "docker 安装失败"
    $SUDO systemctl enable --now docker && ok "已安装并启动" || die "docker 服务启动失败"
fi
if id -nG "$USER" | grep -qw docker; then
    skip "用户已在 docker 组"
else
    $SUDO usermod -aG docker "$USER" && ok "已把 $USER 加入 docker 组（重新登录生效；本脚本继续用 sudo 执行 docker）"
    DOCKER="$SUDO docker"
fi
DOCKER="${DOCKER:-docker}"

# ---- 4 node / uv / bun / pipx ----------------------------------------------
step "语言工具链（node≥22、uv、bun、pipx）"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"
if has_cmd node && [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -ge 22 ]; then
    skip "node $(node -v)"
else
    echo "      安装 node 22（mise）…"
    has_cmd mise || curl -fsSL https://mise.run | sh
    ~/.local/bin/mise install node@22 >/dev/null 2>&1
    eval "$(~/.local/bin/mise activate bash)" 2>/dev/null
    has_cmd node && ok "node $(node -v)" || warn "请手动安装 node ≥22"
fi
if has_cmd bun; then skip "bun $(bun -v 2>/dev/null)"
else echo "      安装 bun…"; curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1
     export PATH="$HOME/.bun/bin:$PATH"; has_cmd bun && ok "bun 已装" || warn "请手动安装 bun"; fi
if has_cmd uv; then skip "uv"
else echo "      安装 uv…"; curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
     has_cmd uv && ok "uv 已装" || warn "请手动安装 uv"; fi
if has_cmd pipx; then skip "pipx"
else echo "      安装 pipx…"
     has_cmd pacman && $SUDO pacman -S --needed --noconfirm -q python-pipx \
       || { python3 -m pip install --user pipx --break-system-packages -q 2>/dev/null || python3 -m pip install --user pipx -q 2>/dev/null; }
     export PATH="$HOME/.local/bin:$PATH"
     has_cmd pipx && ok "pipx 已装" || warn "请手动安装 pipx"; fi

# ---- 5 配置向导 -------------------------------------------------------------
step "端点配置（.env）"
if ! grep -E '^(EMBED|CHAT)_(BASE_URL|MODEL)=' .env 2>/dev/null | grep -q REPLACE_ME; then
    skip "已配置（无 REPLACE_ME；要改端点运行 ./configure.sh）"
    RECONFIGURE=no
else
    RECONFIGURE=yes
    echo "      需要你的模型端点（LM Studio / llama.cpp / OpenAI 兼容皆可）"
fi

# ---- 6 postgres 容器 --------------------------------------------------------
step "Postgres 容器（$POSTGRES_CONTAINER + pgvector）"
if pg_ready; then
    skip "容器运行中，pg 可连接"
elif $DOCKER ps -a --format '{{.Names}}' | grep -qx "$POSTGRES_CONTAINER"; then
    echo "      启动已有容器…"
    $DOCKER start "$POSTGRES_CONTAINER" >/dev/null && for i in $(seq 1 30); do pg_ready && break; sleep 2; done
    pg_ready && ok "已启动" || die "容器存在但 pg 未就绪：docker logs $POSTGRES_CONTAINER"
else
    echo "      拉取镜像并启动（首次约 1-3 分钟）…"
    $DOCKER compose up -d postgres || die "compose 启动失败"
    for i in $(seq 1 60); do pg_ready && break; sleep 2; done
    pg_ready && ok "postgres 就绪" || die "postgres 未就绪：docker logs $POSTGRES_CONTAINER"
fi

# ---- 7 OpenViking 容器 ------------------------------------------------------
step "OpenViking 容器"
if ov_running; then
    skip "容器运行中"
elif $DOCKER ps -a --format '{{.Names}}' | grep -qx openviking; then
    $DOCKER start openviking >/dev/null && ok "已启动已有容器"
else
    echo "      启动 OpenViking（首次拉镜像较慢）…"
    $DOCKER compose up -d openviking || warn "启动失败——检查 .env 端点与 compose 日志：docker compose logs openviking"
    ov_running && ok "OpenViking 运行中" || true
fi

# ---- 8 gbrain 上游 + CLI -----------------------------------------------------
step "gbrain CLI（上游源码构建）"
if has_cmd gbrain; then
    skip "已安装：$(gbrain --version 2>/dev/null | head -1)"
else
    echo "      clone gbrain 上游并构建（bun install + build，数分钟）…"
    GB_UP="$HOME/Projects/gbrain-upstream"
    [ -d "$GB_UP/.git" ] || git clone "${GBRAIN_UPSTREAM_URL:-https://github.com/garrytan/gbrain}" "$GB_UP" || die "gbrain clone 失败"
    ( cd "$GB_UP" && bun install && bun run build ) || die "gbrain 构建失败（见 README『gbrain 安装』）"
    mkdir -p "$HOME/.local/bin"
    ln -sf "$GB_UP/bin/gbrain" "$HOME/.local/bin/gbrain"
    export PATH="$HOME/.local/bin:$PATH"
    has_cmd gbrain && ok "gbrain $(gbrain --version 2>/dev/null | head -1)"
fi

# ---- 9 配置写入（幂等）-------------------------------------------------------
step "应用配置（gbrain / OpenViking 配置键）"
if [ "${RECONFIGURE:-no}" = "no" ] && grep -q database_url "$HOME/.gbrain/config.json" 2>/dev/null; then
    skip "端点未变更且 gbrain 已配置（./configure.sh 可重跑）"
else
    bash configure.sh || warn "configure.sh 有告警——按提示补齐后重跑 ./configure.sh"
fi

# ---- 10 数据恢复 + Hermes + 定时器 -------------------------------------------
step "数据恢复 → Hermes → 备份定时器"
DO_RESTORE=no
[ "${1:-}" = "--restore" ] && DO_RESTORE=yes
if [ "$DO_RESTORE" = "no" ] && ! grep -q 'REPLACE_ME' <<<"$BACKUP_REPO_URL" && ask "从备份仓库恢复数据？($BACKUP_REPO_URL)"; then
    DO_RESTORE=yes
fi
if [ "$DO_RESTORE" = "yes" ]; then
    bash scripts/restore.sh || warn "恢复有告警——处理后重跑 bash scripts/restore.sh"
else
    skip "未恢复数据（全新起步：cd ~/Projects/gbrain && gbrain init-db --yes）"
fi
if has_cmd hermes; then
    skip "Hermes Agent 已安装"
else
    echo "      安装 Hermes Agent…"
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash || warn "Hermes 安装失败，见 https://hermes-agent.nousresearch.com/docs"
fi
for tf in scripts/systemd/*.timer scripts/systemd/*.service; do
    base="$(basename "$tf")"
    if systemctl --user list-unit-files "$base" >/dev/null 2>&1 && systemctl --user is-enabled "$base" >/dev/null 2>&1; then
        skip "定时器 $base"
    else
        cp "$tf" "$HOME/.config/systemd/user/" && ok "安装 $base"
    fi
done
systemctl --user daemon-reload
systemctl --user start gbrain-daily.timer gbrain-dream.timer brain-backup-daily.timer brain-backup-weekly.timer 2>/dev/null
ok "定时器已启用（gbrain-daily 04:04 / gbrain-dream 01:00 / 备份每日+周日）"
mkdir -p "$HOME/.hermes/scripts" && cp scripts/skill_audit.py "$HOME/.hermes/scripts/" 2>/dev/null
echo "      Hermes cron 两个作业请在 Hermes 里创建（skill审计 23:30 每日 / 备份 22:30 周日）——见 docs/restore.md"

echo
echo "=============================================================="
echo "  完成 $STEP/$TOTAL。上面 ~ 行 = 已存在被跳过的组件。"
echo
echo "  验证："
echo "    docker exec $POSTGRES_CONTAINER pg_isready -U postgres"
echo "    gbrain stats"
echo "    curl -s -o /dev/null -w '%{http_code}\n' localhost:${OV_PORT}/health   # 401 即正常"
echo "    systemctl --user list-timers | grep -E 'brain|gbrain'"
echo "=============================================================="
