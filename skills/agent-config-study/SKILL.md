---
name: agent-config-study
version: 1.0.0
author: 烧卖 (Hermes)
license: MIT
description: Use when studying a public agent-config post for ideas.
---

# Study a public agent-config post, land the borrowable parts

## When to use

User shares a Reddit/X/blog post about someone's Hermes/agent configuration and asks what can be borrowed to improve our memory/backup architecture.

## Procedure

1. **Fetch, full content including comments** — routing that works when plain fetch is blocked: Reddit post pages return 403 on `www/.json` and `api.reddit.com`, and old.reddit's `.json` may serve a 200 **interstitial HTML** masquerading as JSON (validate: first bytes start with `{`, not `<!DOCTYPE`). Reliable path: `curl -A "<browser UA>" https://www.reddit.com/r/<sub>/comments/<id>/.rss` → parse `<entry>` blocks with `html.unescape` + tag strip (gives post selftext + all comments). arctic-shift is TLS-intercepted on this network; do not bother.
2. **Distill to mechanisms, not narrative** — numbered core ideas + the top independent insights from comments (comments often carry the sharpest improvements, e.g. regression tests before consolidation).
3. **Compare against our architecture** — list what we already have (avoid re-adopting), what is better here, then a **prioritized adopt list P1..Pn** with the concrete gap for each. Present the table to the user before implementing when they asked for research; implement on approval.
4. **Land each adopted item where it belongs**: standing discipline → SOUL.md; procedures → skills; scheduled jobs → scripts + systemd/Hermes cron; write the outcome into the day's gbrain journal timeline.
5. Record findings + implementation facts in `agent/journal/YYYY-MM-DD.md` timeline (append-only), per the agent-journal convention.

## Pitfalls

- **Check our current state before declaring a gap** — grep the timers/crons/backup dirs first; "we have no backups" claims must be evidence-based (`ls ~/backups`, `systemctl --user list-timers`, `hermes cron list`).
- Do not adopt the poster's stack wholesale — map each of their components to the local equivalent (their Obsidian vault = our gbrain; their dream cron = gbrain-dream) and only adopt what's genuinely missing.
