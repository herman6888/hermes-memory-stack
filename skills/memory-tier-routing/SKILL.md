---
name: memory-tier-routing
description: Route memory via gbrain journal, OV pointers, tiny MD.
triggers:
  - 每日日志 / daily journal
  - 记到 gbrain / 记到 OpenViking
  - 挖素材 / material mining
  - 远程机器要写 gbrain
---

# Memory Tier Routing

Standing user convention: heavy content lives in gbrain; OpenViking carries pointers ONLY; Hermes memory MD stays minimal. Decide the tier BEFORE writing, never write-then-migrate.

## The three tiers

| Tier | Store | Holds | Found via | Size rule |
|---|---|---|---|---|
| 素材仓库 | gbrain `agent/journal/YYYY-MM-DD.md` | full daily work logs, real numbers, publishable 选题候选, evidence chain | gbrain FTS + semantic | heavy, one page/day, never hoard |
| 语义指针 | OpenViking `viking_remember` | ONE pointer: journal lives in gbrain `agent/journal/`, plus structure+usage note | `viking_search` | one entry, NO body text |
| 常驻约定 | Hermes memory MD | the one-line fact that the journal lives in gbrain | injected every turn | minimal, fits 2200-char budget |

Core rule: **OV finds the entrance, gbrain holds the detail, memory MD guarantees the entrance is always remembered.** Never copy journal body text into OV — near-duplicate daily entries inflate the semantic index and degrade recall precision.

## Daily journal page format

- Two-layer split by `---`: above = compiled truth (摘要 / 关键成果 / 状态 / 待办 / 选题候选), rewritten as needed; below = append-only reverse-chronological timeline with timestamps, never rewritten.
- The 选题候选 section is mandatory: distill publishable angles at write time so future material mining needs zero re-processing.
- Only tool-verified numbers go in; no estimated or remembered stats.
- Frontmatter: `type: concept`, title, aliases (include the bare date), tags, provenance one-liner.

## Automation (Hermes `cronjob_manage`)

- `agent-daily-journal`, daily 08:30, **deliver='all'**: session_search yesterday's sessions → write journal page → `git add && git -c user.name=gbrain-agent -c user.email=agent@gbrain.local commit && git push` → `gbrain sync --all --missing-path skip` → `gbrain embed --stale` → final reply = ≤6-line morning digest.
- Idempotent: page exists → append timeline only, never recreate.
- Digest ≤6 lines: what was done / key numbers / today's todos / journal location. If nothing substantive happened, say so in one line and skip the commit — no padding.
- **Pitfall: jobs created from a CLI session default to `deliver='local'` — the digest saves but the user never sees it. Set `deliver='all'` (or an explicit platform) at create time, or update immediately after.**
- Verify after first embed: `gbrain search "<journal keyword>"` must return the new page with a strong score before claiming it's mineable.

## Remote machines without a local gbrain

A second machine (e.g. a Windows gaming box running its own Hermes) must NOT install a parallel brain. Its writes route to the host brain either via the LAN HTTP MCP endpoint or by delegating the write to the host agent. Full recipe: `references/gbrain-lan-mcp.md`.

## Correcting memory on request

When the user asks for a list of your environment understanding to correct it
(纠正一下你的记忆), re-probe live sources FIRST — read the actual config files
(`~/.gbrain/config.json`, `ov.conf`), curl the service endpoints — then present
a table: claim → verification method (live probe / config read / remembered-only)
→ status. Mark unverified items explicitly and end with open questions on the
fuzzy edges. Never present remembered topology as verified when you only
remembered it; the whole point of the exercise is exposing stale entries.

Tool pitfall: `memory` replace requires `old_text` to be an exact substring of
ONE existing entry, and a batch is all-or-nothing — one miss rolls back every
operation in the call. On failure the error response prints the current entries:
pick the exact substring from that printout and reissue. Do not guess the
substring from what you remember the entry saying, and do not retry the same
guess — the failure message already contains the ground truth.

## Mining material

1. `gbrain search "<topic>"` — FTS + semantic, primary path.
2. Browse `agent/journal/` directly for chronological sweep.
3. From an OV-first context: `viking_search` for the pointer, then switch to gbrain for depth.
4. Each journal's 选题候选 section is the ready-to-publish shortlist — cite from it rather than re-deriving angles.
