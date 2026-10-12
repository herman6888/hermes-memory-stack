---
name: agent-journal
description: Daily work journal into gbrain; OV pointer only.
---

# Agent Daily Journal (tiered material library)

Standing contract (Herman): heavy daily work logs live in gbrain `agent/journal/`;
OpenViking stores ONLY a pointer; Hermes memory MD stores ONLY the tiering
convention. Never copy journal body into OpenViking — duplicating bulk content
into the semantic store bloats it and raises retrieval noise.

## Three-tier contract

| Tier | Store | Carries | Weight |
|---|---|---|---|
| Material library | gbrain `agent/journal/YYYY-MM-DD.md` | Full daily log, real evidence, publishable angles | Heavy, one page/day |
| Semantic pointer | OpenViking `viking_remember` | One pointer: journal lives in gbrain `agent/journal/` + a few keywords | One entry, never the body |
| Resident convention | Hermes memory MD | The tiering rule itself | Minimal (hard char budget) |

Why: gbrain has the MECE filing tree, two-layer pages, git versioning and
FTS+semantic search — built to carry heavy material. OV is the find-the-door
layer; gbrain is the dig-the-detail layer. Hermes memory is injected every turn
and must stay tiny.

## Daily journal procedure

1. **Recover the day.** `session_search` (no args = browse recent; `query=` +
   `sort=newest` for a topic). Default roles are user/assistant; add
   `role_filter=user,assistant,tool` only when you need exact commands/values,
   since tool output is noise.
2. **Write the page** at `<gbrain-repo>/agent/journal/YYYY-MM-DD.md` with YAML
   frontmatter (`type: concept`, `title`, `aliases` incl. `journal-YYYY-MM-DD`,
   `tags`) and the two-layer structure: compiled truth (summary, key results,
   state, todos) ABOVE a `---`, append-only reverse-chronological timeline
   BELOW. Follow the repo's RESOLVER.md conventions.
3. **Every number must come from real tool output** in the session — never
   estimated. The journal's value as future content material IS its evidence.
4. **End with a 选题候选 section**: 2–4 concrete publishable angles, each a
   one-line hook. This is what makes the journal mineable later without
   re-deriving.
5. **Update `agent/journal/INDEX.md`** log list with a `[[link]]` to the new
   page (INDEX also documents the tier contract for future readers).
6. **Commit then sync** — gbrain sync skips uncommitted files:
   ```
   git add agent/journal/ && git -c user.name=gbrain-agent -c user.email=agent@gbrain.local commit -m "journal: YYYY-MM-DD"
   git branch --show-current   # confirm the REAL branch before pushing
   gbrain sync --all --missing-path skip
   gbrain embed --stale
   ```
   - Push to the branch `git branch --show-current` reports (this repo: `master`), never a
     hardcoded `main` — a wrong branch name makes the push fail while the chain keeps going,
     and the commit silently stays local.
   - When chaining push → sync → embed in one background command, verify each stage's result
     independently afterwards (`git status -sb` shows ahead/behind vs origin); a failed early
     stage must not be assumed to have run. If the chain stalls, kill it and re-run the failed
     stage alone rather than the whole chain.
   - If the proxy-relay push path is needed (TLS EOF on direct), the SOCKS5 tunnel must be
     established before the push and torn down after; a hung `ssh -f -N -D` left behind blocks
     the port on the next attempt.
7. **Verify retrievable before reporting success**: `gbrain search "<topic>"`
   must return the new page with a high score. A page that synced but wasn't
   embedded won't surface in semantic search — run embed first, then verify.
8. **OV pointer**: ensure exactly one `viking_remember` entry points at the
   gbrain journal location. If the pointer already exists, do not re-add or
   expand it with journal content.

## Cron automation

One nightly job (e.g. 23:30 HKT): session_search the day → write/append the
journal → commit/push/sync/embed. Make it idempotent: if today's page exists,
append only to the timeline section; never recreate the page or rewrite
compiled truth wholesale.

**Pitfall — delivery silently off:** `cronjob_manage` jobs created from a
CLI/TUI session default to `deliver='local'` — output is saved but never
reaches any chat. Set `deliver='all'` (or an explicit platform) at create,
or update immediately after; the create response states this — read it instead
of assuming the job will notify.

## Claim tracking on distilled facts (Muse-inspired, added 2026-10-06)

The journal's compiled-truth sections decay: facts get overturned and prose has
no way to show it. gbrain's `takes` subsystem is the claims table for this —
use it on the **distilled layers (weekly/monthly, L2/L3)**, not on every daily page.

1. **During weekly distill** (`agent/journal/weekly/`), after merging the week's
   pages, register the durable facts that survived distillation as takes on the
   relevant concept page(s):
   ```
   gbrain takes add <slug> --claim "<one durable fact>" --kind fact --who hermes --weight <0.5-0.9> --source "journal YYYY-Wnn"
   ```
   Register only facts that will matter weeks later (system state, measured
   results, standing decisions) — not ephemeral task chatter.
2. **When a later log overturns a registered fact, supersede — never edit in place:**
   ```
   gbrain takes supersede <slug> --row N --claim "<new claim>" --kind fact --who hermes --source "journal YYYY-MM-DD"
   ```
   The old row is struck through in the page markdown and linked to the new row
   (`supersedes` chain); `gbrain find-trajectory --entity-slug <slug>` audits the
   claim trajectory over time. The strikethrough + link is the audit trail — this
   is what plain prose cannot do.
3. **Supersede pass at the end of every distill (weekly/monthly):** scan the
   newly distilled period for facts that contradict existing takes
   (`gbrain takes list --json` + `takes search`); supersede overturned ones on the
   spot, and prune/replace Hermes memory MD entries and OV pointers the same way
   — memory layers must not keep entries that the journal has already overturned.
4. Run `gbrain takes embed` after adding takes so they surface in semantic think/search.

One-time host setup (done 2026-10-06 on .90): `takes add` on a canonical-file page
requires the source writer to be claimed —
`gbrain sources writer claim default --path <repo> --admin-intent writer_claim --expected-state <admin_state>`
(admin_state from `gbrain sources writer status default --json`). Unclaimed → `owner_unavailable`.

## Mining material

- `gbrain search "<keyword>"` (FTS + semantic) or browse `agent/journal/`.
- The 选题候选 sections are the fastest harvest for content pipelines.
- OV search finds the pointer → resolves here / to INDEX.
- `gbrain takes list` / `takes search "<topic>"` for the curated claim layer
  (durable facts with weight + provenance + supersede history).

## Pitfalls

- Never paste journal bodies into OpenViking or Hermes memory — that is
  exactly the bloat the tiering exists to prevent.
- Sync-before-commit silently drops the page from the brain; commit first.
- A journal page missing from INDEX is still searchable but breaks the human
  browsing path; keep INDEX current every write.
- Embed timeouts on the shared local embed endpoint do not kill retrieval — `gbrain search`
  salvages survivors and FTS still hits. Re-run `gbrain embed --stale` later rather than
  treating one timeout as a failed journal entry.
- Never "update" a take by editing its row in the markdown fence — the DB is the
  source of truth and the fence is regenerated; use `takes supersede`/`takes update`.
- `takes embed` failing with `takes_embedding_width_mismatch` means the takes column
  is on an old embedding width (e.g. 1024d) while the model moved on (2560d). Fix with
  `gbrain migrate embeddings --to <provider:model> --dim <N> --max-cost-usd <cap> --yes`
  (check `gbrain migrate embeddings --status` first); the schema-change is fast, the
  remaining vectors drain via `gbrain embed --stale`.
- The embedding endpoint lives in `~/.gbrain/config.json` under
  `provider_base_urls` — probe the model named by `embedding_model` with a direct
  curl to `/v1/embeddings` before blaming gbrain for embed timeouts.
- Answering from memory layers with a key fact: cite the page/row it came from
  (`assemble_evidence` / `get_chunks` / takes row #) so the claim is traceable —
  Muse's `memory_explain` pattern.

Related: the gbrain-workspace `reports` skill covers one-off agent
deliverables (briefings/digests) under `reports/`; this skill owns the
recurring daily material log.