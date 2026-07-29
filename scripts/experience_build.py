#!/usr/bin/env python3
"""
Fleet Desk Phase 0 generator — read-only static projection.
Law: docs/proposals/experience-console-SYNTHESIS.md
"""
from __future__ import annotations

import html
import json
import os
import re
import shutil
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

REPO = Path(__file__).resolve().parents[1]
OUT = REPO / "site" / "experience"
GENERATED = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

DEFAULT_PACKS = {"evidence-first", "untrusted-prior", "git-ship"}
TOKENISH = re.compile(
    r"(?i)(api[_-]?key|secret|token|password|bearer\s+[a-z0-9._\-]{12,}|ghp_[a-z0-9]{20,}|sk-[a-z0-9]{20,})"
)


def esc(s: Any) -> str:
    return html.escape("" if s is None else str(s), quote=True)


def redact(s: str) -> str:
    if not s:
        return s
    return TOKENISH.sub("[redacted]", s)


def parse_frontmatter(text: str) -> Tuple[Dict[str, str], str]:
    if not text.startswith("---"):
        return {}, text
    parts = text.split("---", 2)
    if len(parts) < 3:
        return {}, text
    meta: Dict[str, str] = {}
    for line in parts[1].splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        k, v = line.split(":", 1)
        meta[k.strip()] = v.strip().strip("\"'")
    return meta, parts[2].lstrip("\n")


def parse_role_skills(path: Path) -> Tuple[List[str], Dict[str, List[str]]]:
    """Parse config/role-skills.yaml — roles: maps; defaults: are limits, not packs."""
    roles: Dict[str, List[str]] = {}
    section = None
    if not path.is_file():
        return list(DEFAULT_PACKS), roles
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if re.match(r"^roles:\s*$", line):
            section = "roles"
            continue
        if re.match(r"^[a-zA-Z]", line) and not line.startswith(" "):
            if not line.startswith("roles:"):
                section = None
            continue
        m = re.match(r"^  ([a-zA-Z0-9_-]+):\s*(.*)$", line)
        if section == "roles" and m:
            roles[m.group(1)] = m.group(2).split()
    defaults = roles.get("default") or list(DEFAULT_PACKS)
    return defaults, roles


def load_joins() -> Dict[str, str]:
    """Optional config/experience-joins.yaml: pattern: company_id"""
    path = REPO / "config" / "experience-joins.yaml"
    out: Dict[str, str] = {}
    if not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or ":" not in line:
            continue
        k, v = line.split(":", 1)
        out[k.strip().strip("\"'")] = v.strip().strip("\"'")
    return out


@dataclass
class Company:
    id: str
    name: str
    status: str
    repo: str
    github_repo: str
    phase_note: str = ""


@dataclass
class Trail:
    task_id: str
    wave: Optional[int]
    agent: str
    status: str
    branch: str
    vendor: str
    model: str
    host: str
    base_sha: str
    head_sha: str
    ts: str
    agent_exit: Optional[int]
    files_touched: List[str]
    log: str
    plan_hint: str
    handoff_md: str
    handoff_jsonl_path: str
    company_id: Optional[str] = None
    join_method: str = "unlinked"
    project_label: str = ""
    conductor: bool = False
    issue_links: List[str] = field(default_factory=list)


@dataclass
class Skill:
    id: str
    version: int
    scope: str
    summary: str
    body: str
    status: str  # active | candidate
    path: str


@dataclass
class Learning:
    slug: str
    title: str
    body: str
    path: str
    status: str  # documented | promoted


def load_companies() -> List[Company]:
    companies: List[Company] = []
    for p in sorted((REPO / "companies").glob("*.md")):
        if p.name.startswith("_"):
            continue
        meta, body = parse_frontmatter(p.read_text(encoding="utf-8", errors="replace"))
        cid = meta.get("name") or p.stem
        phase = ""
        for line in body.splitlines():
            if "active phase" in line.lower() or line.strip().startswith("| Wave plan"):
                phase = line.strip()[:120]
                break
        companies.append(
            Company(
                id=cid,
                name=cid,
                status=meta.get("status", "unknown"),
                repo=meta.get("repo", ""),
                github_repo=meta.get("github_repo", ""),
                phase_note=phase,
            )
        )
    return companies


def extract_sections(md: str) -> Dict[str, str]:
    sections: Dict[str, str] = {}
    current = None
    buf: List[str] = []
    for line in md.splitlines():
        if line.startswith("## "):
            if current:
                sections[current] = "\n".join(buf).strip()
            current = line[3:].strip().lower()
            buf = []
        else:
            buf.append(line)
    if current:
        sections[current] = "\n".join(buf).strip()
    return sections


def parse_issue_links(text: str) -> List[str]:
    links = []
    for m in re.finditer(r"https://github\.com/[^\s\)\]]+", text):
        links.append(m.group(0).rstrip(".,)"))
    for m in re.finditer(r"\b([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d+)\b", text):
        links.append(f"https://github.com/{m.group(1)}/issues/{m.group(2)}")
    for m in re.finditer(r"(?<![/\w])#(\d+)\b", text):
        links.append(f"#{m.group(1)}")
    # dedupe preserve order
    seen = set()
    out = []
    for x in links:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out[:8]


def join_company(trail: Trail, companies: List[Company], joins: Dict[str, str]) -> None:
    blob = " ".join(
        [
            trail.task_id,
            trail.branch,
            trail.plan_hint,
            trail.handoff_md[:2000],
            trail.handoff_jsonl_path,
        ]
    ).lower()
    for pat, cid in joins.items():
        if pat.lower() in blob:
            trail.company_id = cid
            trail.join_method = "config_map"
            return
    for c in companies:
        slug = c.github_repo.lower() if c.github_repo else ""
        if slug and slug in blob:
            trail.company_id = c.id
            trail.join_method = "github_repo"
            return
        if c.repo:
            base = Path(c.repo).name.lower()
            if base and base in blob:
                trail.company_id = c.id
                trail.join_method = "repo_path"
                return
        if c.id.lower() in blob:
            trail.company_id = c.id
            trail.join_method = "name_token"
            return
    # project label heuristics
    for token in ("black-aces", "dev-agents", "olympus", "safeplace"):
        if token in blob:
            trail.project_label = token
            break
    if "conductor" in trail.handoff_jsonl_path or trail.conductor:
        trail.project_label = trail.project_label or "conductor"
    trail.join_method = "unlinked"


def load_trails(companies: List[Company], joins: Dict[str, str]) -> List[Trail]:
    trails: List[Trail] = []
    for jsonl in (REPO / "wave-plans").rglob("*.jsonl"):
        if "/handoffs/" not in str(jsonl).replace("\\", "/"):
            continue
        # last non-empty line wins (append-only)
        lines = [ln for ln in jsonl.read_text(encoding="utf-8", errors="replace").splitlines() if ln.strip()]
        if not lines:
            continue
        try:
            d = json.loads(lines[-1])
        except json.JSONDecodeError:
            continue
        task_id = d.get("task_id") or jsonl.stem
        md_path = jsonl.with_suffix(".md")
        md = md_path.read_text(encoding="utf-8", errors="replace") if md_path.is_file() else ""
        prov = d.get("provenance") or {}
        orch = d.get("orchestrator_fields") or {}
        wave = d.get("wave")
        if wave is None:
            m = re.match(r"wave-plans/(\d+)/", str(jsonl.relative_to(REPO)).replace("\\", "/"))
            if m:
                wave = int(m.group(1))
        conductor = "conductor" in str(jsonl).replace("\\", "/")
        plan_hint = ""
        # try plan line from sibling plan files is expensive; use task text from md title
        if md.startswith("#"):
            plan_hint = md.splitlines()[0].lstrip("# ").strip()
        trail = Trail(
            task_id=str(task_id),
            wave=int(wave) if wave is not None and str(wave).isdigit() else (int(wave) if isinstance(wave, int) else None),
            agent=str(d.get("agent") or "unknown"),
            status=str(d.get("status") or "unknown"),
            branch=str(d.get("branch") or ""),
            vendor=str(prov.get("vendor") or ""),
            model=str(prov.get("model") or prov.get("effective_model") or ""),
            host=str(prov.get("host") or ""),
            base_sha=str(d.get("base_sha") or "")[:12],
            head_sha=str(d.get("head_sha") or "")[:12],
            ts=str(d.get("ts") or ""),
            agent_exit=orch.get("agent_exit") if isinstance(orch.get("agent_exit"), int) else None,
            files_touched=list(orch.get("files_touched") or []) if isinstance(orch.get("files_touched"), list) else [],
            log=str(orch.get("log") or ""),
            plan_hint=plan_hint,
            handoff_md=redact(md),
            handoff_jsonl_path=str(jsonl.relative_to(REPO)),
            conductor=conductor,
            issue_links=parse_issue_links(md + " " + plan_hint),
        )
        join_company(trail, companies, joins)
        trails.append(trail)
    # newest first
    trails.sort(key=lambda t: t.ts or "", reverse=True)
    return trails


def load_skills() -> List[Skill]:
    skills: List[Skill] = []
    root = REPO / "skills"
    for skill_md in sorted(root.glob("*/SKILL.md")):
        pack = skill_md.parent.name
        if pack.startswith("_"):
            continue
        meta, body = parse_frontmatter(skill_md.read_text(encoding="utf-8", errors="replace"))
        ver = 1
        try:
            ver = int(meta.get("version", "1"))
        except ValueError:
            ver = 1
        skills.append(
            Skill(
                id=meta.get("id") or pack,
                version=ver,
                scope=meta.get("scope", "global"),
                summary=meta.get("summary", ""),
                body=body,
                status="active",
                path=str(skill_md.relative_to(REPO)),
            )
        )
    cand = root / "_candidates"
    if cand.is_dir():
        for skill_md in sorted(cand.glob("*/SKILL.md")):
            meta, body = parse_frontmatter(skill_md.read_text(encoding="utf-8", errors="replace"))
            pack = skill_md.parent.name
            skills.append(
                Skill(
                    id=meta.get("id") or pack,
                    version=int(meta.get("version", "0") or 0) if str(meta.get("version", "0")).isdigit() else 0,
                    scope=meta.get("scope", "global"),
                    summary=meta.get("summary", ""),
                    body=body,
                    status="candidate",
                    path=str(skill_md.relative_to(REPO)),
                )
            )
    return skills


def load_learnings(skills: List[Skill]) -> List[Learning]:
    learnings: List[Learning] = []
    cited = " ".join(s.body for s in skills)
    for p in sorted((REPO / "learnings").glob("*.md")):
        text = p.read_text(encoding="utf-8", errors="replace")
        title = p.stem
        for line in text.splitlines():
            if line.startswith("# "):
                title = line[2:].strip()
                break
        status = "promoted" if f"learnings/{p.name}" in cited or p.name in cited else "documented"
        learnings.append(
            Learning(slug=p.stem, title=title, body=redact(text), path=str(p.relative_to(REPO)), status=status)
        )
    # product learnings if companies repos exist on disk
    for c in load_companies():
        if not c.repo:
            continue
        prod = (REPO / c.repo).resolve() if not Path(c.repo).is_absolute() else Path(c.repo)
        # companies often use ../olympus-platform relative to companies/
        if not prod.exists():
            prod = (REPO / "companies" / c.repo).resolve()
        if not prod.exists():
            prod = (REPO.parent / Path(c.repo).name).resolve()
        for pattern in ("docs/qa/learning-*.md", "learnings/*.md"):
            for p in prod.glob(pattern):
                if not p.is_file():
                    continue
                text = p.read_text(encoding="utf-8", errors="replace")
                title = p.stem
                for line in text.splitlines():
                    if line.startswith("# "):
                        title = line[2:].strip()
                        break
                slug = f"{c.id}-{p.stem}"
                status = "promoted" if p.name in cited else "documented"
                learnings.append(
                    Learning(slug=slug, title=f"[{c.id}] {title}", body=redact(text), path=str(p), status=status)
                )
    return learnings


def watchlist_themes(trails: List[Trail]) -> List[Tuple[str, int]]:
    counter: Counter = Counter()
    for t in trails:
        secs = extract_sections(t.handoff_md)
        block = secs.get("do not repeat") or secs.get("do_not_repeat") or ""
        for line in block.splitlines():
            line = line.strip().lstrip("-* ").strip()
            if len(line) < 12:
                continue
            key = line[:100]
            counter[key] += 1
    return [(k, n) for k, n in counter.most_common(12) if n >= 2]


def role_stats(trails: List[Trail], role_packs: Dict[str, List[str]], defaults: List[str]) -> Dict[str, Dict[str, Any]]:
    by: Dict[str, List[Trail]] = defaultdict(list)
    for t in trails:
        by[t.agent].append(t)
    out: Dict[str, Dict[str, Any]] = {}
    default_set = set(defaults) | DEFAULT_PACKS
    for role, items in by.items():
        n = len(items)
        n_done = sum(1 for t in items if t.status == "done")
        n_fail = sum(
            1
            for t in items
            if t.status in ("failed", "fail", "unavailable")
            or (t.status != "done" and isinstance(t.agent_exit, int) and t.agent_exit != 0)
        )
        # avoid double-count: prefer status labels
        n_fail = sum(1 for t in items if t.status in ("failed", "fail", "unavailable"))
        n_unknown = max(0, n - n_done - n_fail)
        known = n_done + n_fail
        success = (n_done / known) if known else 0.0
        vendors = Counter(t.vendor for t in items if t.vendor)
        packs = list(role_packs.get(role) or defaults)
        specialized = [p for p in packs if p not in default_set]
        pmi, reason = compute_pmi(n, n_done, n_fail, success, specialized)
        out[role] = {
            "n": n,
            "n_done": n_done,
            "n_fail": n_fail,
            "n_unknown": n_unknown,
            "success": success,
            "vendors": vendors,
            "packs": packs,
            "specialized": specialized,
            "pmi": pmi,
            "pmi_reason": reason,
            "critic": "critic" in role,
        }
    return out


def compute_pmi(n: int, n_done: int, n_fail: int, success: float, specialized: List[str]) -> Tuple[str, str]:
    if n < 3:
        return "P0", f"Ad hoc — n={n} < 3"
    known = n_done + n_fail
    # P2 requires outcomes bar
    if n_done >= 5 and known > 0 and success >= 0.70:
        label = "P2"
        reason = f"Playbooked — n_done={n_done}, success={success:.0%} (n_known={known})"
        if specialized:
            reason += f"; specialized packs: {', '.join(specialized)}"
        # Phase 0 hard cap — never P3
        return label, reason + " · P3 capped (Phase 1)"
    if n >= 3:
        extra = f"; specialized: {', '.join(specialized)}" if specialized else " (defaults only — pack alone does not grant P2)"
        return "P1", f"Instrumented — n={n}{extra}"
    return "P0", f"Ad hoc — n={n}"


# ── HTML ──────────────────────────────────────────────────────────────

CSS = """
:root {
  --bg: #fafaf7;
  --ink: #16161a;
  --muted: #5c5c66;
  --line: #e4e2da;
  --card: #ffffff;
  --ok: #2e7d4f;
  --bad: #b3402e;
  --accent: #b8892b;
  --chip: #f0eee6;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #121214;
    --ink: #f2f1ec;
    --muted: #a0a0aa;
    --line: #2a2a30;
    --card: #1a1a1f;
    --chip: #24242b;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, sans-serif;
  background: var(--bg);
  color: var(--ink);
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
.wrap { max-width: 1120px; margin: 0 auto; padding: 16px 20px 48px; }
header.site {
  border-bottom: 1px solid var(--line);
  padding: 12px 0 14px;
  margin-bottom: 18px;
  position: sticky; top: 0; background: var(--bg); z-index: 10;
}
.brand { font-weight: 700; letter-spacing: -0.02em; font-size: 15px; }
.tag { color: var(--muted); font-size: 12px; margin-top: 2px; }
.nav { display: flex; flex-wrap: wrap; gap: 10px 14px; margin-top: 10px; font-size: 13px; }
.nav a { color: var(--ink); opacity: 0.85; }
.nav a:hover { opacity: 1; color: var(--accent); }
.scope { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }
.chip {
  display: inline-block; padding: 3px 9px; border-radius: 999px;
  background: var(--chip); color: var(--ink); font-size: 12px;
  border: 1px solid var(--line);
}
.chip.active { border-color: var(--accent); color: var(--accent); font-weight: 600; }
.chip.placeholder { opacity: 0.55; }
.grid { display: grid; gap: 14px; }
.grid.two { grid-template-columns: 1.4fr 1fr; }
@media (max-width: 800px) { .grid.two { grid-template-columns: 1fr; } }
.card {
  background: var(--card); border: 1px solid var(--line);
  border-radius: 10px; padding: 12px 14px;
}
.card h2 { margin: 0 0 8px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); font-weight: 600; }
.card h1 { margin: 0 0 10px; font-size: 20px; letter-spacing: -0.02em; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.03em; }
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; }
.status-done { color: var(--ok); font-weight: 600; }
.status-fail { color: var(--bad); font-weight: 600; }
.status-unk { color: var(--muted); }
.wave-h { margin: 16px 0 6px; font-size: 13px; color: var(--muted); font-weight: 600; }
.empty { color: var(--muted); font-size: 13px; padding: 8px 0; }
.footer { margin-top: 28px; padding-top: 12px; border-top: 1px solid var(--line); color: var(--muted); font-size: 12px; }
.skip { position: absolute; left: -999px; }
.skip:focus { left: 8px; top: 8px; background: var(--card); padding: 6px 10px; z-index: 20; }
pre, .body {
  white-space: pre-wrap; word-break: break-word;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px; line-height: 1.4;
  background: var(--chip); padding: 10px; border-radius: 8px; max-height: 420px; overflow: auto;
}
details { margin-top: 8px; }
summary { cursor: pointer; color: var(--accent); font-size: 13px; }
.pmi { font-weight: 700; }
.muted { color: var(--muted); }
.companies { display: flex; flex-wrap: wrap; gap: 8px; }
.company-card {
  min-width: 120px; padding: 10px 12px; border: 1px solid var(--line);
  border-radius: 10px; background: var(--card);
}
.company-card strong { display: block; }
"""


def depth_prefix(depth: int) -> str:
    return "" if depth == 0 else "../" * depth


def page(
    title: str,
    body: str,
    depth: int,
    companies: List[Company],
    scope: str = "global",
) -> str:
    pre = depth_prefix(depth)
    nav = [
        ("Home", f"{pre}index.html"),
        ("Work", f"{pre}work/index.html"),
        ("Skills", f"{pre}skills/index.html"),
        ("Learn", f"{pre}learnings/index.html"),
        ("Roles", f"{pre}roles/index.html"),
        ("Conductor", f"{pre}conductor/index.html"),
        ("About", f"{pre}about/index.html"),
    ]
    scope_html = [f'<a class="chip {"active" if scope=="global" else ""}" href="{pre}index.html">Global</a>']
    for c in companies:
        active = "active" if scope == c.id else ""
        ph = " placeholder" if c.status not in ("active", "Active") else ""
        scope_html.append(
            f'<a class="chip {active}{ph}" href="{pre}company/{esc(c.id)}/index.html">{esc(c.id)}</a>'
        )
    nav_html = " ".join(f'<a href="{href}">{esc(label)}</a>' for label, href in nav)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>{esc(title)} · Fleet Desk</title>
  <style>{CSS}</style>
</head>
<body>
  <a class="skip" href="#main">Skip to content</a>
  <div class="wrap">
    <header class="site">
      <div class="brand">Fleet Desk</div>
      <div class="tag">What the fleet did, learned, and now knows how to do. · generated {esc(GENERATED)}</div>
      <nav class="nav" aria-label="Primary">{nav_html}</nav>
      <div class="scope" aria-label="Scope">{"".join(scope_html)}</div>
    </header>
    <main id="main">
      {body}
    </main>
    <footer class="footer">
      Fleet Desk Phase 0 · read-only · <span class="mono">make experience</span> · law:
      <span class="mono">docs/proposals/experience-console-SYNTHESIS.md</span>
    </footer>
  </div>
</body>
</html>
"""


def status_class(status: str) -> str:
    if status == "done":
        return "status-done"
    if status in ("failed", "fail", "unavailable"):
        return "status-fail"
    return "status-unk"


def trail_row(t: Trail, depth: int) -> str:
    pre = depth_prefix(depth)
    href = f"{pre}trail/{esc(t.task_id)}/index.html"
    label = t.company_id or t.project_label or "unlinked"
    wave = f"wave {t.wave}" if t.wave is not None else "wave —"
    return (
        f"<tr>"
        f'<td class="{status_class(t.status)}">{esc(t.status)}</td>'
        f'<td><a href="{href}">{esc(t.agent)}</a></td>'
        f'<td class="mono">{esc(label)}</td>'
        f"<td>{esc(wave)}</td>"
        f'<td class="mono"><a href="{href}">{esc(t.task_id)}</a></td>'
        f'<td class="muted mono">{esc(t.ts[:16] if t.ts else "")}</td>'
        f"</tr>"
    )


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def build() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    companies = load_companies()
    joins = load_joins()
    trails = load_trails(companies, joins)
    skills = load_skills()
    learnings = load_learnings(skills)
    defaults, role_packs = parse_role_skills(REPO / "config" / "role-skills.yaml")
    if not defaults:
        defaults = list(DEFAULT_PACKS)
    stats = role_stats(trails, role_packs, defaults)
    themes = watchlist_themes(trails)
    skill_by_id = {s.id: s for s in skills if s.status == "active"}

    # pack → roles
    pack_roles: Dict[str, List[str]] = defaultdict(list)
    for role, packs in role_packs.items():
        for p in packs:
            pack_roles[p].append(role)
    for p in defaults:
        if not pack_roles[p]:
            pack_roles[p].append("(defaults)")

    # ── Home ──
    recent = "".join(trail_row(t, 0) for t in trails[:15])
    if not recent:
        recent = '<tr><td colspan="6" class="empty">No handoffs yet — run <span class="mono">./scripts/dispatch.sh …</span> then <span class="mono">make experience</span>.</td></tr>'
    co_cards = []
    for c in companies:
        n = sum(1 for t in trails if t.company_id == c.id)
        co_cards.append(
            f'<a class="company-card" href="company/{esc(c.id)}/index.html">'
            f"<strong>{esc(c.id)}</strong>"
            f'<span class="muted">{esc(c.status)} · {n} trails</span></a>'
        )
    role_rows = []
    for role, st in sorted(stats.items(), key=lambda kv: -kv[1]["n"])[:8]:
        role_rows.append(
            f'<tr><td><a href="role/{esc(role)}/index.html">{esc(role)}</a></td>'
            f'<td>{st["n"]}</td><td>{st["n_done"]}</td>'
            f'<td class="pmi">{esc(st["pmi"])}</td></tr>'
        )
    skill_bits = "".join(
        f'<div><a href="skill/{esc(s.id)}/index.html">{esc(s.id)}</a> '
        f'<span class="muted mono">v{s.version}</span></div>'
        for s in skills
        if s.status == "active"
    )
    learn_bits = (
        f"documented {sum(1 for L in learnings if L.status=='documented')} · "
        f"promoted {sum(1 for L in learnings if L.status=='promoted')}"
    )
    watch = (
        "<ul>"
        + "".join(f"<li>{esc(k)} <span class='muted'>×{n}</span></li>" for k, n in themes[:6])
        + "</ul>"
        if themes
        else '<p class="empty">No recurring do-not-repeat themes (need ≥2 similar lines).</p>'
    )
    home = f"""
    <div class="card"><h2>Companies</h2><div class="companies">{"".join(co_cards) or '<p class="empty">No companies/</p>'}</div></div>
    <div class="grid two" style="margin-top:14px">
      <div class="card">
        <h2>Recent work <a href="work/index.html" style="float:right;font-weight:500">View all Work →</a></h2>
        <table>
          <thead><tr><th>Status</th><th>Role</th><th>Scope</th><th>Wave</th><th>Task</th><th>When</th></tr></thead>
          <tbody>{recent}</tbody>
        </table>
      </div>
      <div class="card">
        <h2>Do-not-repeat watchlist</h2>
        {watch}
      </div>
    </div>
    <div class="grid two" style="margin-top:14px">
      <div class="card">
        <h2>Roles (top)</h2>
        <table><thead><tr><th>Role</th><th>n</th><th>done</th><th>PMI</th></tr></thead>
        <tbody>{"".join(role_rows) or '<tr><td colspan="4" class="empty">No trails</td></tr>'}</tbody></table>
        <p><a href="roles/index.html">Full roles →</a></p>
      </div>
      <div class="card">
        <h2>Skills</h2>{skill_bits or '<p class="empty">No skills</p>'}
        <p style="margin-top:10px"><a href="skills/index.html">Library →</a></p>
        <h2 style="margin-top:16px">Learnings</h2>
        <p class="muted">{esc(learn_bits)}</p>
        <p><a href="learnings/index.html">Index →</a></p>
      </div>
    </div>
    """
    write(OUT / "index.html", page("Home", home, 0, companies, "global"))

    # ── Work index ──
    def work_body(subset: List[Trail], depth: int, scope: str) -> str:
        by_wave: Dict[str, List[Trail]] = defaultdict(list)
        for t in subset:
            key = f"Wave {t.wave}" if t.wave is not None else "Unlinked / no wave"
            by_wave[key].append(t)
        # sort wave keys numeric desc
        def sk(k: str) -> Tuple[int, str]:
            m = re.match(r"Wave (\d+)", k)
            return (0, f"{int(m.group(1)):05d}") if m else (1, k)

        parts = [
            f'<div class="card"><h1>Work</h1>'
            f'<p class="muted">Scope: <strong>{esc(scope)}</strong> · group by wave · '
            f'{len(subset)} trails · trail is the atom; wave clusters atoms.</p></div>'
        ]
        if not subset:
            parts.append(
                '<div class="card empty">No handoffs in this scope. Run dispatch, then '
                '<span class="mono">make experience</span>.</div>'
            )
        for key in sorted(by_wave.keys(), key=sk, reverse=True):
            rows = "".join(trail_row(t, depth) for t in by_wave[key])
            parts.append(
                f'<div class="card" style="margin-top:12px">'
                f'<div class="wave-h">{esc(key)} · {len(by_wave[key])} tasks</div>'
                f"<table><thead><tr><th>Status</th><th>Role</th><th>Scope</th><th>Wave</th><th>Task</th><th>When</th></tr></thead>"
                f"<tbody>{rows}</tbody></table></div>"
            )
        return "\n".join(parts)

    write(OUT / "work" / "index.html", page("Work", work_body(trails, 1, "global"), 1, companies, "global"))

    # ── Trails ──
    for t in trails:
        secs = extract_sections(t.handoff_md)
        built = redact(secs.get("built") or "")
        dnr = redact(secs.get("do not repeat") or secs.get("do_not_repeat") or "")
        decisions = redact(secs.get("decisions") or secs.get("decisions (+why)") or "")
        evidence = redact(secs.get("evidence") or "")
        links = " · ".join(
            f'<a href="{esc(u)}">{esc(u)}</a>' if u.startswith("http") else esc(u) for u in t.issue_links
        ) or '<span class="muted">none parsed</span>'
        scope_label = t.company_id or t.project_label or "unlinked"
        body = f"""
        <div class="card">
          <h1 class="mono">{esc(t.task_id)}</h1>
          <p>
            <span class="{status_class(t.status)}">{esc(t.status)}</span>
            · role <strong>{esc(t.agent)}</strong>
            · wave <strong>{esc(t.wave if t.wave is not None else "—")}</strong>
            · scope <strong>{esc(scope_label)}</strong>
            · join <span class="mono">{esc(t.join_method)}</span>
            {"· conductor" if t.conductor else ""}
          </p>
          <p class="mono muted">
            vendor {esc(t.vendor)} {esc(t.model)} · branch {esc(t.branch)} ·
            {esc(t.base_sha)}→{esc(t.head_sha)} · exit {esc(t.agent_exit)} · {esc(t.ts)}
          </p>
          <p>Links: {links}</p>
          <p class="muted mono">source {esc(t.handoff_jsonl_path)}</p>
        </div>
        <div class="card" style="margin-top:12px">
          <h2>Plan / title</h2>
          <p>{esc(t.plan_hint) or '<span class="muted">—</span>'}</p>
          <h2>Built</h2><div class="body">{esc(built) or "—"}</div>
          <h2>Decisions</h2><div class="body">{esc(decisions) or "—"}</div>
          <h2>Do not repeat</h2><div class="body">{esc(dnr) or "—"}</div>
          <h2>Evidence</h2><div class="body">{esc(evidence) or "—"}</div>
          <details><summary>Handoff markdown (redacted)</summary><pre>{esc(t.handoff_md[:12000])}</pre></details>
        </div>
        """
        write(
            OUT / "trail" / t.task_id / "index.html",
            page(t.task_id, body, 2, companies, t.company_id or "global"),
        )

    # ── Companies ──
    for c in companies:
        subset = [t for t in trails if t.company_id == c.id]
        recent_c = "".join(trail_row(t, 2) for t in subset[:20])
        if not recent_c:
            recent_c = (
                f'<tr><td colspan="6" class="empty">No handoffs joined to {esc(c.id)} yet '
                f"(join gaps are OK in Phase 0).</td></tr>"
            )
        body = f"""
        <div class="card">
          <h1>{esc(c.id)}</h1>
          <p class="muted">{esc(c.status)} · repo <span class="mono">{esc(c.repo)}</span>
          · github <span class="mono">{esc(c.github_repo)}</span></p>
          <p class="muted">{esc(c.phase_note)}</p>
          <p><a href="work/index.html">Open Work for {esc(c.id)} →</a></p>
        </div>
        <div class="card" style="margin-top:12px">
          <h2>Work trails (joined)</h2>
          <table><thead><tr><th>Status</th><th>Role</th><th>Scope</th><th>Wave</th><th>Task</th><th>When</th></tr></thead>
          <tbody>{recent_c}</tbody></table>
        </div>
        """
        write(OUT / "company" / c.id / "index.html", page(c.id, body, 2, companies, c.id))
        write(
            OUT / "company" / c.id / "work" / "index.html",
            page(f"Work · {c.id}", work_body(subset, 3, c.id), 3, companies, c.id),
        )

    # ── Roles ──
    role_table = []
    for role, st in sorted(stats.items(), key=lambda kv: -kv[1]["n"]):
        vendors = ", ".join(f"{v} {n}" for v, n in st["vendors"].most_common()) or "—"
        role_table.append(
            f'<tr><td><a href="../role/{esc(role)}/index.html">{esc(role)}</a></td>'
            f'<td>{st["n"]}</td><td>{st["n_done"]}</td><td>{st["n_fail"]}</td>'
            f'<td>{st["success"]:.0%} · n={st["n_done"]+st["n_fail"]}</td>'
            f'<td class="mono">{esc(vendors)}</td>'
            f'<td class="pmi">{esc(st["pmi"])}</td></tr>'
        )
    roles_index = f"""
    <div class="card">
      <h1>Roles</h1>
      <p class="muted">Usage + Playbook Maturity Index (PMI). P2 requires outcomes; pack alone does not grant P2. Phase 0 caps at P2.</p>
      <table>
        <thead><tr><th>Role</th><th>n</th><th>done</th><th>fail</th><th>success</th><th>vendors</th><th>PMI</th></tr></thead>
        <tbody>{"".join(role_table) or '<tr><td colspan="7" class="empty">No data</td></tr>'}</tbody>
      </table>
    </div>
    """
    write(OUT / "roles" / "index.html", page("Roles", roles_index, 1, companies))

    for role, st in stats.items():
        subset = [t for t in trails if t.agent == role]
        rows = "".join(trail_row(t, 2) for t in subset[:50])
        packs = ", ".join(st["packs"]) or "—"
        body = f"""
        <div class="card">
          <h1>{esc(role)}</h1>
          <p>n={st["n"]} · done={st["n_done"]} · fail={st["n_fail"]} ·
          success {st["success"]:.0%} · <span class="pmi">{esc(st["pmi"])}</span></p>
          <p class="muted">{esc(st["pmi_reason"])}</p>
          <details open><summary>PMI inputs</summary>
            <ul class="mono">
              <li>n={st["n"]}</li>
              <li>n_done={st["n_done"]} n_fail={st["n_fail"]}</li>
              <li>specialized_packs={esc(", ".join(st["specialized"]) or "(none)")}</li>
              <li>packs={esc(packs)}</li>
              <li>source=wave-plans/*/handoffs/*.jsonl · config/role-skills.yaml</li>
            </ul>
          </details>
          <p class="muted">Injected packs: <span class="mono">{esc(packs)}</span></p>
        </div>
        <div class="card" style="margin-top:12px">
          <h2>Trails</h2>
          <table><thead><tr><th>Status</th><th>Role</th><th>Scope</th><th>Wave</th><th>Task</th><th>When</th></tr></thead>
          <tbody>{rows or '<tr><td colspan="6" class="empty">None</td></tr>'}</tbody></table>
        </div>
        """
        write(OUT / "role" / role / "index.html", page(role, body, 2, companies))

    # ── Skills ──
    skill_rows = []
    for s in skills:
        roles = ", ".join(pack_roles.get(s.id, [])) or "—"
        skill_rows.append(
            f'<tr><td><a href="../skill/{esc(s.id)}/index.html">{esc(s.id)}</a></td>'
            f'<td class="mono">v{s.version}</td><td>{esc(s.status)}</td>'
            f'<td class="muted">{esc(s.summary)}</td><td class="mono">{esc(roles)}</td></tr>'
        )
    skills_index = f"""
    <div class="card">
      <h1>Skills</h1>
      <p class="muted">Promotion is PR-only (skills-evolution SYNTHESIS). This page is read-only status.</p>
      <table>
        <thead><tr><th>Pack</th><th>Ver</th><th>Status</th><th>Summary</th><th>Roles</th></tr></thead>
        <tbody>{"".join(skill_rows)}</tbody>
      </table>
    </div>
    """
    write(OUT / "skills" / "index.html", page("Skills", skills_index, 1, companies))

    for s in skills:
        roles = ", ".join(pack_roles.get(s.id, [])) or "—"
        body = f"""
        <div class="card">
          <h1 class="mono">{esc(s.id)}</h1>
          <p>v{s.version} · {esc(s.status)} · scope {esc(s.scope)}</p>
          <p>{esc(s.summary)}</p>
          <p class="muted mono">{esc(s.path)}</p>
          <p>Injected by: <span class="mono">{esc(roles)}</span></p>
          <p class="muted">To promote candidates or change packs: open a PR — never from this UI.</p>
        </div>
        <div class="card" style="margin-top:12px">
          <h2>Body</h2>
          <div class="body">{esc(s.body[:15000])}</div>
        </div>
        """
        write(OUT / "skill" / s.id / "index.html", page(s.id, body, 2, companies))

    # ── Learnings ──
    learn_rows = []
    for L in learnings:
        learn_rows.append(
            f'<tr><td><a href="../learning/{esc(L.slug)}/index.html">{esc(L.slug)}</a></td>'
            f"<td>{esc(L.status)}</td><td>{esc(L.title)}</td>"
            f'<td class="mono muted">{esc(L.path)}</td></tr>'
        )
    learn_index = f"""
    <div class="card">
      <h1>Learnings</h1>
      <p class="muted">documented = file exists · promoted = cited from a skill via [ev:]. Promotion remains PR-only.</p>
      <table>
        <thead><tr><th>Slug</th><th>Status</th><th>Title</th><th>Path</th></tr></thead>
        <tbody>{"".join(learn_rows) or '<tr><td colspan="4" class="empty">No learnings</td></tr>'}</tbody>
      </table>
    </div>
    """
    write(OUT / "learnings" / "index.html", page("Learnings", learn_index, 1, companies))

    for L in learnings:
        body = f"""
        <div class="card">
          <h1>{esc(L.title)}</h1>
          <p>status <strong>{esc(L.status)}</strong> · <span class="mono">{esc(L.path)}</span></p>
        </div>
        <div class="card" style="margin-top:12px"><div class="body">{esc(L.body[:20000])}</div></div>
        """
        write(OUT / "learning" / L.slug / "index.html", page(L.slug, body, 2, companies))

    # ── Conductor ──
    cond = [t for t in trails if t.conductor]
    cond_rows = "".join(trail_row(t, 1) for t in cond)
    cond_body = f"""
    <div class="card">
      <h1>Conductor</h1>
      <p class="muted">One-shot plans under <span class="mono">wave-plans/conductor/</span> · Session Modes Phase 0.</p>
      <table><thead><tr><th>Status</th><th>Role</th><th>Scope</th><th>Wave</th><th>Task</th><th>When</th></tr></thead>
      <tbody>{cond_rows or '<tr><td colspan="6" class="empty">No conductor handoffs yet.</td></tr>'}</tbody></table>
    </div>
    """
    write(OUT / "conductor" / "index.html", page("Conductor", cond_body, 1, companies))

    # ── About ──
    about = f"""
    <div class="card">
      <h1>About Fleet Desk</h1>
      <p>Phase 0 read-only projection. Law: <span class="mono">docs/proposals/experience-console-SYNTHESIS.md</span></p>
      <p>Generated <strong>{esc(GENERATED)}</strong> · {len(trails)} trails · {len(skills)} skill packs · {len(learnings)} learnings</p>
      <h2>Sources</h2>
      <ul class="mono">
        <li>companies/*.md</li>
        <li>wave-plans/**/handoffs/*.jsonl + *.md</li>
        <li>skills/*/SKILL.md · config/role-skills.yaml</li>
        <li>learnings/* · product docs/qa/learning-*.md when on disk</li>
      </ul>
      <h2>Join rules</h2>
      <ol>
        <li>config/experience-joins.yaml</li>
        <li>github_repo / repo slug match</li>
        <li>company name token</li>
        <li>else unlinked on Global</li>
      </ol>
      <h2>PMI</h2>
      <p>P0 n&lt;3 · P1 n≥3 · P2 n_done≥5 and success≥70% · P3 Phase 1 only (capped).</p>
      <h2>How to refresh</h2>
      <pre>make experience
make experience-open   # build + open browser
make desk              # alias</pre>
      <p class="muted">See <span class="mono">docs/experience.md</span> and operator-guide.</p>
    </div>
    """
    write(OUT / "about" / "index.html", page("About", about, 1, companies))

    print(f"Fleet Desk wrote {OUT} ({len(trails)} trails, {len(companies)} companies)")


if __name__ == "__main__":
    build()
