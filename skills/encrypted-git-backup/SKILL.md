---
name: encrypted-git-backup
version: 1.0.0
author: 烧卖 (Hermes)
license: MIT
description: Use when backing up data to a private encrypted git repo.
---

# Encrypted git backup for agent brain data

## When to use

Asked to back up hermes / OpenViking / gbrain (or any DB+config set) to a private git repo with encryption, versioned rollback, and scheduled jobs; also when asked "can git do incremental backups".

Answer the user's implicit question first: **git IS incremental** — each commit stores deltas against its parent, natively for text. "Weekly full + daily incremental" is only needed for compressed binaries (pg custom dumps, tars), which do not delta. So the design is:

- **Daily = text** (uncompressed SQL/CSV/config files) → git diffs them natively.
- **Weekly = full binaries** (with regenerable bulk), split under the GitHub 100MB per-file cap, keep N copies.

## Procedure

1. **Inventory before designing**: per-table sizes (`pg_total_relation_size` per relname), `du -sh` each target dir. Separate **derived/regenerable data** (vector embeddings, caches, build outputs) from source-of-truth text — derived data is excluded from daily dumps entirely, it is re-generatable at restore time (this is what keeps the daily text dump tiny and diffable).
2. **Repo + crypto**: create private repo (`gh api -X POST /user/repos` — REST survives transient graphql EOF where `gh repo create` fails; retry loop). `pacman -S git-crypt`; `git-crypt init`; `.gitattributes` = `* filter=git-crypt diff=git-crypt` + `!.gitattributes !filter !diff` + plaintext `.gitignore`. `git-crypt export-key ~/.ssh/<name>.key` (chmod 600) and **escrow off-box immediately** (e.g. scp to VPS /root/). Verify encryption landed: `git show HEAD:<file> | head -1` must start `\x00GITCRYPT`.
3. **RESTORE.md inside the repo** — self-restore instructions a fresh instance can follow: key locations, layout, restore ladder from smallest to largest disaster scope, retention policy, and the periodic history-pruning maintenance note (git history grows with binary weeklies; quarterly `git filter-repo` prune + force-push, documented).
4. **Daily script** (see `references/backup-script-recipes.md` for the working shells): text dumps of DB (full plain SQL excluding the vector-heavy table + COPY of that table's non-vector columns via dynamic `information_schema` column list), rsync snapshot of config dirs, 30-day retention of dated files, commit + push with retries, status JSON file. Success = **empty stdout (silent)**; failure = message + nonzero exit.
5. **Weekly script**: full dumps (with vectors), sqlite `.backup` of live DBs, tar+zstd, `split -b 95m -d`, prune to N weeks, commit + push. Success = one heartbeat line (delivered).
6. **Cron (no LLM in the loop)**: `hermes cron create "<cron>" --no-agent --script <filename> --deliver ...` — `--script` must be a **bare filename** under `~/.hermes/scripts/` (absolute path is refused). Daily: `--deliver local --failure-deliver feishu:<chat>`; weekly: `--deliver feishu:<chat>` for the heartbeat.
7. **Verify end-to-end, not just "script exited 0"**: reassemble the split parts (`cat *.part* > f`), then gate on artifact verification — `pg_restore --list`, `zstd -t`, `tar -tf` listing expected members.

## Pitfalls

- **Gate on artifact verification, never tar's exit code** — tarring live app dirs exits nonzero on sockets ("socket ignored") and files modified during read; exclude `*.sock *.lock *.pid *.wal *-shm` and let `zstd -t`/`tar -tzf` be the sole pass/fail gate.
- **rsync trailing slashes are load-bearing**: `rsync -a src/ dest/` copies contents; `rsync -a src dest` with dest existing **nests** `dest/src/` on rerun. Always use trailing slashes on both sides for snapshot trees.
- **pg_dump plain text needs a completeness check** (`grep "PostgreSQL database dump complete"`) — a truncated dump on a dead docker side passes exit codes.
- **GitHub hard limit is 100MB per file** — `split -b 95m -d` all binary artifacts; reassembly is `cat <base>.part* > <base>`.
- **Encrypted blobs don't delta**: git-crypt ciphertext compresses to ~its full size each commit; budget repo growth as (dump size) × (frequency) and note the quarterly prune in RESTORE.md.
- **Large pushes through flaky proxies EOF**: push with 3 direct retries, then fall back to a VPS bare-repo relay whose `post-receive` hook pushes refs to GitHub (token lives only on the VPS remote URL).
- **Exclude regenerable bulk from dailies**: full pg dumps with embeddings were 175MB while the text-only heap was ~19MB — dropping vector columns kept the daily dump diffable.

## Supporting files

- `references/backup-script-recipes.md` — working shell snippets: dynamic column-exclusion COPY, WAL-safe sqlite loop, split/prune, VPS relay setup.
