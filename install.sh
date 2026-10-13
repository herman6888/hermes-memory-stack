#!/usr/bin/env bash
# hermes-memory-stack installer — dependencies + services + data restore.
#
# 交互全部集中在开头「配置向导」（步骤 0），随后的安装步骤全自动：
# 每个组件先检测、已存在自动跳过，失败修复后可直接重跑续装。
#
#   ./install.sh                  # 弹配置向导；缺啥装啥
#   ./install.sh --restore        # 跳过询问，恢复数据
#   ./install.sh --no-restore --no-hermes --yes   # 全非交互（CI / 远程 ssh）
#   flags: --restore|--no-restore --hermes|--no-hermes --timers|--no-timers --yes
#   无 TTY（如 ssh 直接执行）时自动按 --yes 处理：向导不弹出，采用默认值。
#
# 支持发行版：Arch / CachyOS / Manjaro / Omarchy（pacman）；Ubuntu / Debian（apt）
set -uo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { cp .env.example .env; echo "已生成 .env —— 稍后由配置向导填写，或手动编辑"; }
set -a; . ./.env; set +a
SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"

# ---- 命令行参数 --------------------------------------------------------------
: "${ASSUME_YES:=}"
[ -t 0 ] || ASSUME_YES=yes          # 无终端 = 非交互
OPT_RESTORE=""; OPT_HERMES=""; OPT_TIMERS=""
while [ $# -gt 0 ]; do case "$1" in
    --restore)    OPT_RESTORE=yes ;;
    --no-restore) OPT_RESTORE=no ;;
    --hermes)     OPT_HERMES=yes ;;
    --no-hermes)  OPT_HERMES=no ;;
    --timers)     OPT_TIMERS=yes ;;
    --no-timers)  OPT_TIMERS=no ;;
    --yes)        ASSUME_YES=yes ;;
    *) echo "未知参数：$1"; exit 2 ;;
esac; shift; done

TOTAL=11; STEP=0
step() { STEP=$((STEP+1)); echo; echo "==> [$STEP/$TOTAL] $*"; }
ok()   { echo "      ✓ $*"; }
skip() { echo "      ~ 跳过：$*"; }
warn() { echo "      ! $*"; }
die()  { echo; echo "✗ 中止：$*"; echo "  修复后重跑本脚本即可——已完成的步骤会自动跳过。"; exit 1; }
ask()  { local a; read -rp "      ? $1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_pkg() { if [ "${PKG:-}" = pacman ]; then pacman -Qi "$1" >/dev/null 2>&1
            elif [ "${PKG:-}" = apt ]; then dpkg -s "$1" >/dev/null 2>&1; else return 1; fi; }
pg_ready() { $DOCKER exec "$POSTGRES_CONTAINER" pg_isready -q -U postgres >/dev/null 2>&1; }
ov_running() { [ -n "$($DOCKER ps -q -f name=openviking 2>/dev/null)" ]; }
envset() { # envset KEY VALUE：写入/替换 .env 中的键（值不含换行）
    if grep -q "^${1}=" .env; then sed -i "s|^${1}=.*|${1}=${2}|" .env
    else echo "${1}=${2}" >> .env; fi
    export "$1=$2"
}

echo "=============================================================="
echo "  Hermes Memory Stack 安装"
echo "  （组件自动检测：已安装的会跳过；所有询问集中在开头向导）"
echo "=============================================================="

# ---- 0 配置向导：所有用户交互都在这一处 ---------------------------------------
step "配置向导"
# 0a 发行版识别
DISTRO="未知"; PKG=""
if [ -r /etc/os-release ]; then . /etc/os-release
    case " $ID ${ID_LIKE:-} " in
        *arch*|*manjaro*|*cachyos*) DISTRO="${NAME:-$ID}（Arch 系 / pacman）"; PKG=pacman ;;
        *debian*|*ubuntu*)          DISTRO="${NAME:-$ID}（Debian 系 / apt）";   PKG=apt ;;
    esac
fi
[ -n "$PKG" ] || die "不支持的发行版：${DISTRO}（/etc/os-release: ID=${ID:-?}）—— 支持 Arch/CachyOS/Manjaro（pacman）与 Ubuntu/Debian（apt）"
ok "发行版：$DISTRO"

# 0b 环境现状一览
echo "      ── 当前检测 ──"
for c in git docker node bun uv pipx gbrain hermes; do
    has_cmd "$c" && echo "        ✓ $c 已安装" || echo "        · $c 未安装（将安装）"
done
if grep -E '^(EMBED|CHAT)_(BASE_URL|MODEL)=' .env | grep -q REPLACE_ME; then NEED_ENDPOINTS=yes
else NEED_ENDPOINTS=no; echo "        ✓ 模型端点已配置（.env）"; fi
BACKUP_CONFIGURED=no
grep -q 'REPLACE_ME' <<<"${BACKUP_REPO_URL:-}" || BACKUP_CONFIGURED=yes

# 0c 模型端点
RECONFIGURE=no
if [ "$NEED_ENDPOINTS" = yes ]; then
    RECONFIGURE=yes
    if [ -n "$ASSUME_YES" ]; then
        warn "端点仍是 REPLACE_ME 占位符（--yes 模式不弹向导）；配好 .env 后单独跑 ./configure.sh"
    else
        echo "      模型端点未配置。选择 OpenAI 兼容端点类型："
        echo "        1) LM Studio（局域网，免 key）        2) llama.cpp / llama-server（免 key）"
        echo "        3) OpenAI 或其他需要 API key 的端点"
        read -rp "      ? 选 1/2/3 [1] " pchoice; pchoice="${pchoice:-1}"
        case "$pchoice" in
            2) EP=llama-server ;;
            3) EP=openai; read -rp "      ? API key（本地端点填 local）: " ekey; envset OPENAI_API_KEY "${ekey:-local}" ;;
            *) EP=lmstudio ;;
        esac
        envset EMBED_PROVIDER "$EP"; envset CHAT_PROVIDER "$EP"
        read -rp "      ? Embedding 端点 Base URL [http://127.0.0.1:1234/v1]: " v; envset EMBED_BASE_URL "${v:-http://127.0.0.1:1234/v1}"
        read -rp "      ? Embedding 模型名: " v; [ -n "$v" ] && envset EMBED_MODEL "$v"
        read -rp "      ? Embedding 维度 [2560]: " v; envset EMBED_DIM "${v:-2560}"
        read -rp "      ? 对话端点 Base URL（留空=与 Embedding 相同）: " v; [ -n "$v" ] && envset CHAT_BASE_URL "$v"
        read -rp "      ? 对话模型名: " v; [ -n "$v" ] && envset CHAT_MODEL "$v"
        ok "端点已写入 .env"
    fi
fi

# 0d 数据恢复
DO_RESTORE="${OPT_RESTORE:-}"
if [ -z "$DO_RESTORE" ]; then
    if [ "$BACKUP_CONFIGURED" = yes ] && [ -z "$ASSUME_YES" ]; then
        ask "从加密备份仓库恢复数据？($BACKUP_REPO_URL)" && DO_RESTORE=yes || DO_RESTORE=no
    else DO_RESTORE=no; fi
fi
if [ "$DO_RESTORE" = yes ] && [ -z "$ASSUME_YES" ]; then
    echo "      恢复需要 git-crypt 密钥（当前 .env 指向：${GIT_CRYPT_KEY:-未设置}）"
    read -rp "      ? 密钥文件路径（留空保留当前值）: " v; [ -n "$v" ] && envset GIT_CRYPT_KEY "$v"
fi
[ "$DO_RESTORE" = no ] && [ "$BACKUP_CONFIGURED" = no ] && \
    echo "      ~ 备份仓库未配置（BACKUP_REPO_URL=REPLACE_ME），全新起步"

# 0e Hermes Agent
INSTALL_HERMES="${OPT_HERMES:-}"
if [ -z "$INSTALL_HERMES" ]; then
    if has_cmd hermes; then INSTALL_HERMES=no; echo "        ✓ hermes 已安装（不重装）"
    elif [ -n "$ASSUME_YES" ]; then INSTALL_HERMES=yes
    else ask "安装 Hermes Agent？（官方安装脚本）" && INSTALL_HERMES=yes || INSTALL_HERMES=no; fi
fi

# 0f systemd 定时器
INSTALL_TIMERS="${OPT_TIMERS:-yes}"
if [ -z "${OPT_TIMERS:-}" ] && [ -z "$ASSUME_YES" ]; then
    ask "安装并启用定时任务？（gbrain daily/dream + 备份，默认是）" || INSTALL_TIMERS=no
fi
ok "向导完成：恢复=$DO_RESTORE · Hermes=$INSTALL_HERMES · 定时器=$INSTALL_TIMERS"

# ---- 1 系统检查 --------------------------------------------------------------
step "系统检查"
grep -qE 'vmx|svm' /proc/cpuinfo || warn "CPU 无虚拟化扩展标志（虚拟机内正常，docker 不受影响）"
has_cmd systemctl >/dev/null || warn "无 systemd：定时器/服务步骤仅部分可用"
ok "包管理器：$PKG"

# ---- 2 基础包 -----------------------------------------------------------------
step "基础工具（git curl jq ripgrep zstd rsync sqlite git-crypt postgres 客户端）"
if [ "$PKG" = pacman ]; then
    PKGS=()
    for p in git curl jq ripgrep zstd rsync sqlite git-crypt postgresql-libs unzip; do has_pkg "$p" || PKGS+=("$p"); done
    if [ ${#PKGS[@]} -eq 0 ]; then skip "全部已安装"
    else echo "      需安装：${PKGS[*]}"
        $SUDO pacman -S --needed --noconfirm "${PKGS[@]}" || die "pacman 安装失败"
        ok "安装完成"; fi
else
    export DEBIAN_FRONTEND=noninteractive
    PKGS=()
    for p in git curl jq ripgrep zstd rsync sqlite3 git-crypt postgresql-client pipx ca-certificates unzip; do has_pkg "$p" || PKGS+=("$p"); done
    if [ ${#PKGS[@]} -eq 0 ]; then skip "全部已安装"
    else echo "      需安装：${PKGS[*]}"
        $SUDO apt-get update -qq && $SUDO apt-get install -y "${PKGS[@]}" || die "apt 安装失败"
        ok "安装完成"; fi
fi

# ---- 3 docker -----------------------------------------------------------------
step "Docker + compose"
if has_cmd docker && docker info >/dev/null 2>&1; then
    skip "docker 已安装、守护进程运行中"
else
    echo "      安装 docker…"
    if [ "$PKG" = pacman ]; then
        $SUDO pacman -S --needed --noconfirm docker docker-compose || die "docker 安装失败"
    else
        $SUDO apt-get install -y docker.io docker-compose-v2 2>/dev/null \
          || $SUDO apt-get install -y docker.io docker-compose-plugin 2>/dev/null \
          || $SUDO apt-get install -y docker.io docker-compose || die "docker 安装失败"
    fi
    $SUDO systemctl enable --now docker || die "docker 服务启动失败"
    ok "docker 已安装并启动"
fi
if id -nG "$USER" | grep -qw docker; then
    skip "用户已在 docker 组"
else
    $SUDO usermod -aG docker "$USER" && ok "已把 $USER 加入 docker 组（重新登录生效；本脚本继续用 sudo 执行 docker）"
fi
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="$SUDO docker"
if $DOCKER compose version >/dev/null 2>&1; then COMPOSE="$DOCKER compose"
elif has_cmd docker-compose; then COMPOSE="docker-compose"
else die "缺 docker compose v2（Ubuntu: docker-compose-v2；Debian: docker-compose-plugin；Arch: docker-compose）"; fi
ok "compose 可用：$COMPOSE"

# ---- 4 node / uv / bun / pipx ------------------------------------------------
step "语言工具链（node≥22、uv、bun、pipx）"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"
# persist PATH for future shells (gbrain/bun/uv live in ~/.local/bin, ~/.bun/bin)
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    grep -q '\.local/bin' "$rc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"' >> "$rc"
done
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
     [ "$PKG" = pacman ] && $SUDO pacman -S --needed --noconfirm -q python-pipx
     has_cmd pipx || { python3 -m pip install --user pipx --break-system-packages -q 2>/dev/null || python3 -m pip install --user pipx -q 2>/dev/null; }
     export PATH="$HOME/.local/bin:$PATH"
     has_cmd pipx && ok "pipx 已装" || warn "请手动安装 pipx"; fi

# ---- 5 端点检查（写入已在向导完成）----------------------------------------------
step "端点配置检查（.env）"
if [ "$NEED_ENDPOINTS" = no ]; then
    skip "已配置（要改端点运行 ./configure.sh）"
elif [ "$RECONFIGURE" = yes ] && grep -E '^(EMBED|CHAT)_(BASE_URL|MODEL)=' .env | grep -q REPLACE_ME; then
    warn ".env 端点仍是占位符——之后请补齐 .env 并重跑 ./configure.sh"
else
    ok "向导已写入 .env"
fi

# ---- 6 postgres 容器 ----------------------------------------------------------
step "Postgres 容器（$POSTGRES_CONTAINER + pgvector）"
if pg_ready; then
    skip "容器运行中，pg 可连接"
elif $DOCKER ps -a --format '{{.Names}}' | grep -qx "$POSTGRES_CONTAINER"; then
    echo "      启动已有容器…"
    $DOCKER start "$POSTGRES_CONTAINER" >/dev/null && for i in $(seq 1 30); do pg_ready && break; sleep 2; done
    pg_ready && ok "已启动" || die "容器存在但 pg 未就绪：docker logs $POSTGRES_CONTAINER"
else
    echo "      拉取镜像并启动（首次约 1-3 分钟）…"
    $COMPOSE up -d postgres || die "compose 启动失败"
    for i in $(seq 1 60); do pg_ready && break; sleep 2; done
    pg_ready && ok "postgres 就绪" || die "postgres 未就绪：docker logs $POSTGRES_CONTAINER"
fi

# ---- 7 OpenViking 容器 --------------------------------------------------------
step "OpenViking 容器"
if ov_running; then
    skip "容器运行中"
elif $DOCKER ps -a --format '{{.Names}}' | grep -qx openviking; then
    $DOCKER start openviking >/dev/null && ok "已启动已有容器"
else
    echo "      启动 OpenViking（首次拉镜像较慢）…"
    $COMPOSE up -d openviking || warn "启动失败——检查 .env 端点与日志：$COMPOSE logs openviking"
    ov_running && ok "OpenViking 运行中" || true
fi

# ---- 8 gbrain CLI（源码构建）---------------------------------------------------
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

# ---- 9 配置写入（幂等）---------------------------------------------------------
step "应用配置（gbrain / OpenViking 配置键）"
if [ "${RECONFIGURE:-no}" = "no" ] && grep -q database_url "$HOME/.gbrain/config.json" 2>/dev/null; then
    skip "端点未变更且 gbrain 已配置（./configure.sh 可重跑）"
else
    bash configure.sh || warn "configure.sh 有告警——按提示补齐后重跑 ./configure.sh"
fi

# ---- 10 数据恢复（询问已在向导完成）---------------------------------------------
step "数据恢复"
if [ "$DO_RESTORE" = yes ]; then
    bash scripts/restore.sh || warn "恢复有告警——处理后重跑 bash scripts/restore.sh"
else
    skip "未恢复数据（之后可随时 ./install.sh --restore）"
    [ "$BACKUP_CONFIGURED" = no ] && echo "      全新起步：向导未选恢复，配好私有仓库后重跑 ./install.sh --restore"
fi

# ---- 11 Hermes + 定时器 + skill 审计 -------------------------------------------
step "Hermes Agent → 备份定时器"
if [ "$INSTALL_HERMES" = yes ]; then
    if has_cmd hermes; then
        skip "Hermes Agent 已安装"
    else
        echo "      安装 Hermes Agent…"
        curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash || warn "Hermes 安装失败，见 https://hermes-agent.nousresearch.com/docs"
    fi
else
    skip "不安装 Hermes Agent（向导选择 / --no-hermes）"
fi
if [ "$INSTALL_TIMERS" = yes ]; then
    for tf in scripts/systemd/*.timer scripts/systemd/*.service; do
        base="$(basename "$tf")"
        if systemctl --user list-unit-files "$base" >/dev/null 2>&1 && systemctl --user is-enabled "$base" >/dev/null 2>&1; then
            skip "定时器 $base"
        else
            mkdir -p "$HOME/.config/systemd/user"
            sed "s|__STACK_DIR__|$PWD|g; s|__GBRAIN_DIR__|$HOME/Projects/gbrain|g" \
                "$tf" > "$HOME/.config/systemd/user/$base" && ok "安装 $base"
        fi
    done
    systemctl --user daemon-reload
    systemctl --user start gbrain-daily.timer gbrain-dream.timer brain-backup-daily.timer brain-backup-weekly.timer 2>/dev/null
    ok "定时器已启用（gbrain-daily 04:04 / gbrain-dream 01:00 / 备份每日+周日）"
else
    skip "不安装定时器（--no-timers）"
fi
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
