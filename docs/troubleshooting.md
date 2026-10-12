# 实测踩坑记录（全新机器安装 + 恢复演练得出）

以下每一条都在一台干净的 Arch 虚拟机上真实复现并修复，不是理论推导。

## 1. git-crypt 报 `encrypted file has been tampered with!`（最坑）

**症状**：新机器 `git-crypt unlock` 成功，但 checkout 个别文件时报 tampered；`.90` 老机器一切"正常"。

**根因**：备份内容里 rsync 进来的第三方 skill 自带嵌套 `.gitattributes`（如 `*.sh text eol=lf`）。
`text` 属性会强制对文件做 CRLF↔LF 转换——git-crypt 加密后的密文 blob 是伪随机字节，里面自然出现
`0d 0a` 序列，被 eol 转换改写后**密文本身损坏**。clean 时损坏 = 仓库里的 blob 从写下那刻就解不开。
老机器"正常"是因为工作区从未触发 smudge（工作树一直是明文），损坏只在第一次真实 clone 时暴露。

**修复**：所有 git-crypt 管辖的文件必须禁 eol 转换：

```gitattributes
* filter=git-crypt diff=git-crypt -text
.gitattributes !filter !diff
```

嵌套 `.gitattributes`（比根文件优先级高）也要追加 `*.sh -text` 之类的覆盖行；
损坏的历史 blob 需 `touch 文件 && git add` 重新加密提交。
**纪律：备份系统必须定期做"新机器 clone + unlock + 解密验证"演练，只查 `git-crypt status` 是查不出来的。**

## 2. gbrain 连 Postgres：`password authentication failed`（bun 运行时）

**症状**：psql 用同样连接串成功，gbrain（bun 编译的二进制）报认证失败；scram 和 md5 都失败，
hba 改 trust 后成功。

**根因**：bun 下 node-pg 的密码认证（SASL/scram）路径有兼容问题。生产端一直是 loopback trust
所以从未暴露。

**修复**：compose 起的 Postgres 给容器加 hba 规则，让 **容器内/宿主机 127.0.0.1 走 trust**
（端口映射的流量在容器侧源地址是 docker 网段，需要一并放行本机网段），对外局域网保持 md5：

```
host all all 127.0.0.1/32 trust
host all all 172.17.0.0/16 trust   # docker bridge 网段
host all all 0.0.0.0/0 md5
```

## 3. pg_restore 报 `unrecognized configuration parameter "transaction_timeout"`

**根因**：pg_dump 18.x 生成的 dump，灌回 pg16 服务器时带新参数。
**修复**：`sed '/SET transaction_timeout/d'` 清洗后再灌，并用**容器内的 pg_restore**
（与服务端同版本），`--create --clean` 换成先 drop/create database 再 `--clean --if-exists`。

## 4. gbrain 对本地模型端点报价格闸门 / `unknown_provider`

- 上游 ≥0.60.177 给 embed 调用加了付费成本闸门，本地免费端点没有价格条目会被拒。
  注册零价格即可：`gbrain pricing set "<provider>:<model>" --rate 0 --source local`
- LM Studio 端点用 `lmstudio` provider（免 key），非默认地址用环境变量
  `LMSTUDIO_BASE_URL=http://<host>:1234/v1` 指定（systemd 服务的 env 里也要配）。
- embed 模型配置不写在 config.json 的 `embedding_model`（被新配置平面忽略），
  由 `gbrain migrate embeddings --to <provider>:<model> --dim <N> --yes` 写入。

## 5. compose 的简单变量插值

老版 docker-compose 不认识 `${VAR:-default}` 写法时报错。用简单 `${VAR}`。

## 6. OpenViking 官方镜像与配置生成

`ghcr.io/volcengine/openviking` 官方镜像的 ov.conf 里 `server.host` 必须
`0.0.0.0`（容器内 127.0.0.1 会让端口映射失效）；缺 ov.conf 时容器以 503 挂起并打印修复提示。
admin/user-key API 以你自己部署的 OV 版本为准（官方镜像与自构建版接口有差异）。
