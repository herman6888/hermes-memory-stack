# hermes-memory-stack

一套可自助重建的 **Hermes Agent 记忆架构**：三层记忆（素材仓库 / 语义索引 / 常驻极小集）+ 每晚 dream 自我维护 + 加密 git 备份。

机器炸了？照 [docs/restore.md](docs/restore.md) 从两个私有 git repo（备份仓库 + 工作区仓库）重建整套系统。

## 架构一览

```
┌─ 常驻极小集 ─ Hermes memory MD（2.2KB 预算，只放一行版约定）
├─ 语义索引   ─ OpenViking（Docker, :1933, pg 无关；向量=本地 embedding 模型）
├─ 素材仓库   ─ gbrain（Postgres+pgvector；日记/事实/取词；L0会话→L1日→L2周→L3月金字塔）
└─ 纪律层     ─ SOUL.md 记忆卫生纪律（75% triage / 合并回归闸门 / 剪枝人审）
```

核心规则：**语义索引找到入口，素材仓库存细节，memory MD 保证入口永远被记得。**
原始事实绝不写进注入记忆（memory MD）——写入前自问"这条是否适用于每一个会话？"，不是就写素材层。

详见 [docs/architecture.md](docs/architecture.md)。

## 快速重建（新机器）

```bash
git clone https://github.com/herman6888/hermes-memory-stack.git
cd hermes-memory-stack
cp .env.example .env        # 填 LLM/embedding 端点等
./install.sh                # 开头「配置向导」统一询问，之后全自动：依赖+容器+gbrain+恢复
./scripts/restore.sh        # （安装时未选恢复的话）单独恢复
```

- **发行版支持**：Arch / CachyOS / Manjaro / Omarchy（pacman）、Ubuntu / Debian（apt）；
  Windows 用 `install.cmd`（winget + Docker Desktop + MSYS2）。
- **所有询问集中在 install.sh 开头的配置向导**（步骤 0）：端点、数据恢复、Hermes、定时器。
  之后全自动：组件先检测、已装自动跳过（`~` 行），中断修复后直接重跑续装。
- **非交互**：`./install.sh --yes --restore --no-hermes`（无 TTY 自动 --yes）。
  flags：`--restore|--no-restore` `--hermes|--no-hermes` `--timers|--no-timers` `--yes`。
- `./configure.sh` 可单独重跑（幂等，写 gbrain/OV 配置 + skills + timers）。

## 组成

| 路径 | 内容 |
|---|---|
| `docs/architecture.md` | 三层记忆 + 金字塔 + 卫生纪律（设计文档） |
| `docs/restore.md` | 灾难恢复手册（按灾难范围从小到大） |
| `docs/troubleshooting.md` | 全新机器安装/恢复演练的实测踩坑（git-crypt eol、bun+pg 认证、pg 版本、价格闸门） |
| `docker-compose.yml` | Postgres(pgvector) + OpenViking |
| `templates/` | ov.conf / gbrain 配置 / SOUL 纪律段（占位符化） |
| `scripts/` | 每日/每周备份、skill 审计、dream/daily、恢复脚本、systemd 单元 |
| `skills/` | 架构配套 skills（tier-routing / journal / encrypted-git-backup / config-study） |

## 数据在哪（本 repo 不含任何本地数据）

| Repo | 可见性 | 内容 |
|---|---|---|
| 本 repo | 公开 | 架构 + 脚本 + 模板（占位符，无 IP/密钥/日志） |
| 备份仓库 | 私有 | git-crypt 全加密：DB dump、OV 数据、Hermes 全配置、state.db |
| 工作区仓库 | 私有 | gbrain 页面内容（日记/知识页） |

## 设计原则

1. **派生数据不进每日备份**——向量索引等可再生 bulk 只进每周全量；每日只备份文本（git 原生 diff 即增量，"全备+增量"由 git 的 packfile 天然完成）。
2. **定时任务不进 LLM**——备份是纯脚本 cron（no-agent），成功静默、失败告警。
3. **自动化的破坏性动作先当建议**——skill 剪枝等由 dream 出建议清单，人周审后放权。
4. **恢复说明书放在备份里**——每个备份仓库自带 RESTORE.md，新实例能自救。

## 上游

[Hermes Agent](https://hermes-agent.nousresearch.com/docs) · [gbrain](https://github.com/garrytan/gbrain) · [OpenViking](https://github.com/volcengine/OpenViking)

MIT
