# 灾难恢复手册

前提：你有两个私有 repo 的访问权（`.env` 里的 `BACKUP_REPO_URL` 备份仓库 + `WORKSPACE_REPO_URL` 工作区仓库），以及 git-crypt 密钥。

## 第 0 步：解锁备份仓库

```bash
pacman -S git-crypt   # 或 apt install git-crypt
git clone "$BACKUP_REPO_URL" brain-backup && cd brain-backup
git-crypt unlock ~/.ssh/<git-crypt-key>.key   # 密钥托管位置见仓库内 RESTORE.md
```

备份仓库布局（详见仓库内 RESTORE.md）：
- `daily/gbrain-meta-*.sql` + `daily/gbrain-chunks-*.csv` —— 文本增量（不含向量）
- `weekly/gbrain-full-*.dump.part*` —— 全量（含向量），95MB 分片
- `weekly/ov-data-*.tar.zst.part*` —— OpenViking 数据
- `weekly/hermes-state-*.tar.zst.part*` —— Hermes state.db / kanban.db / profiles
- `secrets/` + `hermes-config/snap/` —— Hermes 配置全量

## 第 1 步：起基础服务

```bash
cd hermes-memory-stack && ./install.sh   # 会拉起 postgres + openviking
```

## 第 2 步：gbrain（素材层）

优先全量（快，含向量，无需重新 embed）：
```bash
cat weekly/gbrain-full-*.dump.part* > full.dump
pg_restore -d gbrain --create full.dump
```
或文本重建（小、慢，需重新 embed，向量由 embedding 模型再生）：
```bash
psql -d gbrain -f daily/gbrain-meta-<最新>.sql
psql -d gbrain -c "\copy content_chunks(<csv 列名>) FROM 'daily/gbrain-chunks-<最新>.csv' CSV"
gbrain embed --stale   # 重建向量
```
工作区页面源文件另有版本历史：`git clone "$WORKSPACE_REPO_URL" ~/Projects/gbrain`。

## 第 3 步：OpenViking（语义索引）

```bash
docker stop openviking
cat weekly/ov-data-*.tar.zst.part* | zstd -d | tar -x -f - -C ~/.hermes/.local/share/
docker start openviking
# 注意： vectordb 与 embedding 模型维度绑定；换 embedding 模型需重建索引
```

## 第 4 步：Hermes

```bash
tar -xzf secrets/hermes-config-latest.tar.gz -C ~/.hermes/    # 配置（含 skills/cron/hooks/SOUL）
tar -xzf <(cat weekly/hermes-state-*.tar.zst.part* | zstd -d)  # 可选：会话状态回滚
# state 包内文件解到 ~/.hermes/ 对应路径（state.db / kanban.db / profiles/<p>/state.db）
./configure.sh   # 重建 systemd timers；hermes cron 作业随配置包恢复
```
恢复后验证：`hermes cron list`、`gbrain search <关键词>`、`viking_search` 各出一发。

## 日常纪律（防灾难）

- 备份脚本成功静默、失败 ping；每周一次成功心跳 ping。看到连续告警立即人工介入。
- git 历史随周全量增长：每季度按备份仓库 RESTORE.md 的瘦身程序处理（filter-repo + force push）。
