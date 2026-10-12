# 记忆架构设计

## 要解决的问题

长寿命 agent 的记忆必然腐坏（rot）：注入记忆被 infra 细节挤爆、技能库出现重叠/过期条目、日志越堆越厚检索噪音飙升。本架构的目标：**跑半年不用清空重开**。

## 三层记忆

| 层 | 载体 | 存什么 | 铁律 |
|---|---|---|---|
| 素材仓库 | gbrain（Postgres + pgvector） | 完整日志、真实数字、选题候选、证据链；日页 `agent/journal/YYYY-MM-DD.md` | 重，随便加厚 |
| 语义索引 | OpenViking | 一条指针：日志在 gbrain 哪里 + 结构说明 | 绝不把日志正文复制进语义索引 |
| 常驻极小集 | Hermes memory MD（~2.2KB 预算） | 一行版约定 | 最小 |

**语义索引负责找到入口，素材仓库负责挖细节，memory MD 保证永远记得入口存在。**
近重复的日志正文进语义索引会稀释召回精度——这是"指针而非复制"的原因。

## 素材金字塔（gbrain 内部）

- **L0** 原始会话：transcripts 每日 ingest → `conversations/sessions/...`
- **L1** 日：`agent/journal/YYYY-MM-DD.md`，双层结构（上=编译真相含选题候选，可重写；下=append-only 时间线，永不重写）
- **L2 周 / L3 月**：distill 作业合并同类项；长期检索优先指向 L3/L2，不下沉翻日页

## 维护循环（nightly dream）

每晚定时任务（限定工具集、本地模型跑）：回看当日会话 → 自我批评 → 写反思/模式页 → lint/backlinks/embed → **skill 库审计（只出建议清单）**。
上下文纪律：综合阶段 turn 预算硬上限（`dream.synthesize.max_turns`），共享本地推理池时防止大上下文打死服务。

## 记忆卫生纪律（写进 SOUL.md，见 templates/SOUL-memory-discipline.md）

1. **75% 主动 triage**：memory MD 用量到 ~75% 就清扫（infra 细节卸载到素材层、删敏感/过期），不等挤爆被动压缩。写入前自问：这条是否适用于每一个会话？不是→素材层。
2. **合并回归闸门**：skill 合并/删除必须声明 absorbed_into，且**在替代 skill 上重跑被删 skill 的回归用例**——声明被吸收 ≠ 行为存活。
3. **剪枝定时化、默认 dry-run**：provenance 分类（bundled / 打包 / agent 自建），按真实调用记录判使用，闲置 ≥90d 进候选；pinned 保护；**建议清单人周审后放权执行**。
4. **infra 事实（IP/端口/路径）绝不路由进注入记忆**——它们是素材层 reference 页的内容，带日期行维护。

## 备份纪律（见 docs/restore.md）

- 每日 = 文本增量（git 原生 diff）；每周 = 全量二进制分片。派生数据（向量）只进每周全量，可再生。
- 备份 = 私有 git repo + git-crypt 全加密，密钥双托管（本机 + 异地机器），仓库内嵌 RESTORE.md 自恢复说明书。
- 备份 job 纯脚本无 LLM；成功静默、失败 ping；产物级完整性校验（pg_restore --list / zstd -t / tar -t）作为唯一通过闸门。

## 多机约定

素材层真共享（同一 gbrain 工作区仓库）；语义索引按 user 隔离（每台机器自己的 user key），跨机记忆不自动可见；Hermes memory MD 纯本地。远程机要写素材层：走 LAN HTTP MCP 或委托主脑 agent 写，不装平行 brain。
