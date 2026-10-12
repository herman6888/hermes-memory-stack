#!/usr/bin/env python3
"""Skill library audit (provenance-aware), pattern from r/hermesagent ct06033.

Classifies every SKILL.md by provenance (bundled / gbrain-pack / hermes-agent),
flags idle candidates (atime+mtime >= idle-days), pins (frontmatter
`pinned: true`) are protected from prune suggestions, and reports merge
candidates via Jaccard token overlap of name+description.

Default is dry-run: prints a markdown proposal report, writes nothing.
--report writes agent/skill-audit/{latest.md,YYYY-MM-DD.md} into the gbrain
repo (picked up by the nightly sync). No destructive action here — pruning is
executed by a human after weekly review.
"""
import argparse, json, os, re, sys, time, datetime, itertools, pathlib

HOME = pathlib.Path.home()
ROOTS = [  # (kind, path)
    ("hermes-agent", HOME / ".hermes/skills"),
    ("gbrain-pack",  HOME / "Projects/gbrain/workspace/skills"),
]
for prof in sorted((HOME / ".hermes/profiles").glob("*/skills")):
    ROOTS.append((f"profile:{prof.parent.name}", prof))

def bundled_names():
    names = set()
    base = HOME / ".hermes-web-ui/desktop-runtime/hermes"
    for ver in sorted(base.glob("*/linux-x64/python/skills")):
        for p in ver.glob("*/SKILL.md"):
            names.add(p.parent.name)
    return names

def frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    fm = {}
    if m:
        for line in m.group(1).splitlines():
            kv = re.match(r"^(name|description|version|pinned)\s*:\s*(.+)$", line.strip())
            if kv:
                fm[kv.group(1)] = kv.group(2).strip().strip("\"'")
    return fm

def tokens(s):
    return set(re.findall(r"[a-z0-9\u4e00-\u9fff]+", (s or "").lower()))

def used_skills(days):
    """Skill names loaded via skill_view in the last N days (state.db, ro)."""
    db = HOME / ".hermes/state.db"
    used = set()
    try:
        import sqlite3
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        cut = time.time() - days * 86400
        for (tc,) in con.execute(
                "SELECT tool_calls FROM messages "
                "WHERE tool_name='skill_view' AND timestamp > ?", (cut,)):
            if not tc:
                continue
            for m in re.finditer(r'"name"\s*:\s*"([^"]+)"', tc):
                used.add(m.group(1))
        con.close()
    except Exception as e:
        print(f"WARN: state.db 用量查询失败（回退 mtime 口径）: {e}", file=sys.stderr)
        return None
    return used

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--idle-days", type=int, default=90)
    ap.add_argument("--merge-threshold", type=float, default=0.55)
    ap.add_argument("--report", action="store_true", help="write report page into gbrain repo")
    args = ap.parse_args()

    bundled = bundled_names()
    now = time.time()
    used = used_skills(args.idle_days)  # None => db unavailable, mtime fallback
    seen = {}
    prio = {"hermes-agent": 0, "gbrain-pack": 1}
    for kind, root in ROOTS:
        if not root.is_dir():
            continue
        for md in sorted(root.glob("**/SKILL.md")):
            d = md.parent
            try:
                text = md.read_text(errors="replace")[:4000]
            except OSError:
                continue
            fm = frontmatter(text)
            st = md.stat()
            is_bundled = d.name in bundled or fm.get("name") in bundled
            name = fm.get("name", d.name)
            rec = {
                "name": name, "kind": "bundled" if is_bundled else kind,
                "bundled": is_bundled,
                "pinned": fm.get("pinned", "").lower() in ("true", "yes", "1"),
                "desc": fm.get("description", ""),
                "idle_days": round((now - max(st.st_atime, st.st_mtime)) / 86400),
                "mtime_days": round((now - st.st_mtime) / 86400),
                "path": str(d),
            }
            prev = seen.get(name)
            if prev is None or prio.get(rec["kind"], 9) < prio.get(prev["kind"], 9):
                seen[name] = rec
    skills = list(seen.values())
    for s in skills:
        s["used_recent"] = (s["name"] in used) if used is not None else False
    prov = {}
    for s in skills:
        prov[s["kind"]] = prov.get(s["kind"], 0) + 1

    def is_idle(s):
        if used is not None:
            return (not s["used_recent"]) and s["mtime_days"] >= args.idle_days
        return s["idle_days"] >= args.idle_days
    prune = [s for s in skills
             if not s["bundled"] and not s["pinned"]
             and s["kind"] != "gbrain-pack" and is_idle(s)]
    merge = []
    for a, b in itertools.combinations(skills, 2):
        if a["name"] == b["name"]:
            continue
        ta, tb = tokens(a["name"] + " " + a["desc"]), tokens(b["name"] + " " + b["desc"])
        if not ta or not tb:
            continue
        j = len(ta & tb) / len(ta | tb)
        if j >= args.merge_threshold:
            merge.append((round(j, 2), a["name"], b["name"]))
    merge.sort(reverse=True)
    merge = merge[:20]
    prune.sort(key=lambda s: -s["idle_days"])

    today = datetime.date.today().isoformat()
    lines = [f"# Skill 库审计报告 {today}", "",
             f"- 总数 {len(skills)}；provenance: " + ", ".join(f"{k}={v}" for k, v in sorted(prov.items())),
             f"- 剪枝候选（闲置≥{args.idle_days}d，非bundled非pinned，dry-run仅建议）: {len(prune)}",
             "", "## 剪枝候选（闲置天数降序，前30）", ""]
    for s in prune[:30]:
        lines.append(f"- `{s['name']}`（{s['kind']}，闲置 {s['idle_days']}d）— {s['desc'][:60]}")
    lines += ["", f"## 合并候选（Jaccard≥{args.merge_threshold}，前20，仅报告）", ""]
    for j, a, b in merge:
        lines.append(f"- {j:.2f}: `{a}` ↔ `{b}`")
    lines += ["", "> 纪律：合并前必须先声明 absorbed_into，并在替代 skill 上重跑被删 skill 的 skill-autobench 回归用例。"]
    report = "\n".join(lines) + "\n"

    if args.report:
        outdir = HOME / "Projects/gbrain/agent/skill-audit"
        outdir.mkdir(parents=True, exist_ok=True)
        (outdir / "latest.md").write_text(report)
        (outdir / f"{today}.md").write_text(report)
        print(f"skill-audit: {len(skills)} skills, {len(prune)} prune candidates, "
              f"{len(merge)} merge candidates -> agent/skill-audit/{today}.md")
    else:
        print(report)

if __name__ == "__main__":
    main()
