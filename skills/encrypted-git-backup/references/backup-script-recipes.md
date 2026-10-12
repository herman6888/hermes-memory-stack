# Backup script recipes (verified working)

## Dynamic column-exclusion export (Postgres)

pg_dump cannot exclude columns; use COPY with a column list built from `information_schema`:

```bash
COLS=$(docker exec <pgcontainer> psql -U postgres -d <db> -Atc \
  "SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position)
     FROM information_schema.columns
    WHERE table_name='<big_table>'
      AND column_name NOT IN ('embedding','embedding_image','embedding_multimodal','search_vector')")
docker exec <pgcontainer> psql -U postgres -d <db> \
  -c "\copy (SELECT $COLS FROM <big_table>) TO STDOUT CSV" > chunks.csv
```
Restored by `\copy <table>(<same cols>) FROM ... CSV` then regenerating vectors via the embed pipeline. Pair with `pg_dump --exclude-table=public.<big_table>` for the schema/part-A dump, and gate the plain dump with `grep "PostgreSQL database dump complete"`.

## WAL-safe sqlite snapshot loop

```bash
for db in "$HOME"/.hermes/state.db "$HOME"/.hermes/kanban.db "$HOME"/.hermes/profiles/*/state.db; do
  [ -f "$db" ] || continue
  rel=$(echo "$db" | sed "s|$HOME/.hermes/||; s|/|__|g")
  sqlite3 "$db" ".backup '$STAGE/$rel'" || fail "sqlite backup 失败: $db"
done
```

## tar of live app dirs (sockets/locks)

```bash
tar --warning=no-file-changed \
  --exclude='*.sock' --exclude='*.lock' --exclude='*.lock.*' --exclude='*.pid' \
  --exclude='*.wal' --exclude='*-shm' --exclude='*.bak*' \
  -czf out.tar.gz -C "$base" item1 item2 2>/dev/null   # exit code is NOT the gate
tar -tzf out.tar.gz >/dev/null || fail "tar 校验失败"     # the gate
```
Pipe form: `tar -cf - ... | zstd -q -3 -o f.zst`, gate on `zstd -t f.zst && [ -s f.zst ]`.

## Split + retention prune

```bash
split -b 95m -d big.dump "$outdir/big.dump.part"        # GitHub 100MB per-file cap
prune(){ local pat="$1" keep="$2"; ls -1tr $pat 2>/dev/null | head -n -"$keep" | xargs -r rm -f; }
prune "weekly/gbrain-full-*.dump.part*" 54              # 6 weeks × ~9 parts
```

## VPS git relay for large pushes (flaky proxy)

On the relay box (reachable over EasyTier):

```bash
mkdir -p /srv/git/<repo>.git && cd /srv/git/<repo>.git && git init --bare
git remote add github https://x-access-token:<TOKEN>@github.com/<owner>/<repo>.git
printf '#!/bin/sh\nwhile read old new ref; do git push -q github "$new:$ref"; done\n' > hooks/post-receive
chmod +x hooks/post-receive
```
Client: `git remote add vps ssh://root@<relay>/srv/git/<repo>.git`; push logic = 3 direct retries then `git push vps main:main`.

## Cron wiring (Hermes)

```bash
hermes cron create "30 23 * * *" --name "backup daily" --no-agent \
  --script <name>.sh --deliver local --failure-deliver "feishu:<chat_id>"
hermes cron create "30 22 * * 0" --name "backup weekly" --no-agent \
  --script <name>.sh --deliver "feishu:<chat_id>"
```
`--script` takes a **bare filename** under `~/.hermes/scripts/` (absolute path is refused). With `--no-agent`, stdout is delivered verbatim and empty stdout = silent — so: daily prints nothing on success (failure-only pings), weekly prints one heartbeat line.

## git-crypt quick sequence

```bash
pacman -S git-crypt   # Arch; apt: git-crypt
git-crypt init
printf '* filter=git-crypt diff=git-crypt\n.gitattributes !filter !diff\n' > .gitattributes
git-crypt export-key ~/.ssh/<name>.key && chmod 600 ~/.ssh/<name>.key
# escrow: scp key to off-box root@; verify: git show HEAD:file | head -1  → \x00GITCRYPT
```
