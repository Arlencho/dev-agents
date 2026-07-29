#!/usr/bin/env python3
"""
Fleet Desk — HTML renderer (Wave 2 presentation).

Reads ONLY the data contract emitted by scripts/experience_data.py:

    site/experience/data/index.json    (schema: docs/experience-data.md)

and writes static pages plus a copied stylesheet next to it:

    site/experience/assets/site.css    (from templates/experience/site.css)

No repo scanning happens here — if a field is missing from the JSON it does not
belong on the page. Law: docs/proposals/experience-console-SYNTHESIS.md
"""
from __future__ import annotations

import argparse
import html
import json
import re
import shutil
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import experience_data

CSS_SOURCE = Path(__file__).resolve().parents[1] / "templates" / "experience" / "site.css"


def esc(s: Any) -> str:
    return html.escape("" if s is None else str(s), quote=True)


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def clean_html(out: Path) -> None:
    """Drop previously rendered HTML so pages for vanished trails cannot linger.

    Owns HTML only: `<out>/data` (the contract written by experience_data.py)
    and `<out>/assets` (the stylesheet) are never touched, and non-HTML files
    are left alone.
    """
    if not out.is_dir():
        return
    keep = {out / "data", out / "assets"}
    for page in out.rglob("*.html"):
        if any(k == page.parent or k in page.parents for k in keep):
            continue
        page.unlink()
    # Prune directories the removed pages left empty (deepest first).
    for d in sorted((p for p in out.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
        if d in keep or any(k in d.parents for k in keep):
            continue
        if not any(d.iterdir()):
            d.rmdir()


def write_assets(out: Path) -> None:
    if not CSS_SOURCE.is_file():
        raise SystemExit(f"missing stylesheet template: {CSS_SOURCE}")
    target = out / "assets" / "site.css"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(CSS_SOURCE, target)


NAV = [
    ("home", "Home", "index.html"),
    ("work", "Work", "work/index.html"),
    ("skills", "Skills", "skills/index.html"),
    ("learn", "Learn", "learnings/index.html"),
    ("roles", "Roles", "roles/index.html"),
    ("conductor", "Conductor", "conductor/index.html"),
    ("about", "About", "about/index.html"),
]


class Renderer:
    def __init__(self, data: Dict[str, Any], out: Path):
        self.d = data
        self.out = out
        self.companies = data["companies"]
        self.trails = data["trails"]
        self.generated = data["generated_at"]

    # ── shell ─────────────────────────────────────────────────────────
    @staticmethod
    def pre(depth: int) -> str:
        return "" if depth == 0 else "../" * depth

    def page(
        self,
        title: str,
        body: str,
        depth: int,
        scope: str = "global",
        section: Optional[str] = None,
    ) -> str:
        pre = self.pre(depth)
        nav_bits = []
        for key, label, href in NAV:
            current = ' aria-current="page"' if key == section else ""
            nav_bits.append(f'<a href="{pre}{href}"{current}>{esc(label)}</a>')
        nav_html = " ".join(nav_bits)
        global_current = ' aria-current="true"' if scope == "global" else ""
        chips = [f'<a class="chip" href="{pre}index.html"{global_current}>Global</a>']
        for c in self.companies:
            current = ' aria-current="true"' if scope == c["id"] else ""
            dim = " dim" if str(c["status"]).lower() != "active" else ""
            status = esc(c["status"])
            chips.append(
                f'<a class="chip{dim}" href="{pre}company/{esc(c["id"])}/index.html"'
                f' title="{esc(c["id"])} · {status}"{current}>{esc(c["id"])}</a>'
            )
        return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>{esc(title)} · Fleet Desk</title>
  <link rel="stylesheet" href="{pre}assets/site.css"/>
</head>
<body>
  <a class="skip" href="#main">Skip to content</a>
  <div class="wrap">
    <header class="site">
      <div class="brandrow">
        <span class="brand"><a href="{pre}index.html">Fleet Desk</a></span>
        <span class="tag">What the fleet did, learned, and now knows how to do.<span class="dot">·</span>read-only<span class="dot">·</span>generated {esc(self.generated)}</span>
      </div>
      <nav class="nav" aria-label="Primary">{nav_html}</nav>
      <div class="scope" aria-label="Scope">
        <span class="scope-label">Scope</span>{"".join(chips)}
      </div>
    </header>
    <main id="main">
{body}
    </main>
    <footer class="footer">
      <span>Fleet Desk Phase 0 · read-only</span>
      <span>rebuild: <span class="mono">make experience</span></span>
      <span>data: <a href="{pre}data/index.json">data/index.json</a> (schema v{esc(self.d["schema_version"])})</span>
      <span>law: <span class="mono">{esc(self.d["law"])}</span></span>
    </footer>
  </div>
</body>
</html>
"""

    # ── fragments ─────────────────────────────────────────────────────
    @staticmethod
    def status_kind(status: str) -> str:
        if status == "done":
            return "done"
        if status in ("failed", "fail", "unavailable", "error"):
            return "fail"
        return "unk"

    def status_pill(self, status: str) -> str:
        kind = self.status_kind(status)
        return f'<span class="st st-{kind}">{esc(status)}</span>'

    @staticmethod
    def pmi_badge(band: str) -> str:
        return f'<span class="pmi band-{esc(band.lower())}">{esc(band)}</span>'

    def crumb(self, items: List[Tuple[str, Optional[str]]]) -> str:
        parts = []
        for label, href in items:
            parts.append(f'<a href="{href}">{esc(label)}</a>' if href else f"<span>{esc(label)}</span>")
        sep = '<span class="sep">·</span>'
        return f'<p class="crumb">{sep.join(parts)}</p>'

    def trail_row(self, t: Dict[str, Any], depth: int) -> str:
        pre = self.pre(depth)
        href = f"{pre}trail/{esc(t['task_id'])}/index.html"
        label = t["company_id"] or t["project_label"] or "unlinked"
        wave = f"wave {t['wave']}" if t["wave"] is not None else "wave —"
        return (
            "<tr>"
            f"<td>{self.status_pill(t['status'])}</td>"
            f'<td><a href="{pre}role/{esc(t["role"])}/index.html">{esc(t["role"])}</a></td>'
            f'<td class="mono">{esc(label)}</td>'
            f"<td>{esc(wave)}</td>"
            f'<td class="mono"><a href="{href}">{esc(t["task_id"])}</a></td>'
            f'<td class="muted mono">{esc((t["ts"] or "")[:16])}</td>'
            "</tr>"
        )

    def trail_table(self, subset: List[Dict[str, Any]], depth: int, empty: str) -> str:
        head = (
            "<thead><tr><th>Status</th><th>Role</th><th>Scope</th>"
            "<th>Wave</th><th>Task</th><th>When</th></tr></thead>"
        )
        rows = "".join(self.trail_row(t, depth) for t in subset)
        if not rows:
            return f'<p class="empty">{empty}</p>'
        return f'<div class="tablewrap"><table>{head}<tbody>{rows}</tbody></table></div>'

    @staticmethod
    def wave_key(t: Dict[str, Any]) -> str:
        return f"Wave {t['wave']}" if t["wave"] is not None else "Unlinked / no wave"

    def wave_sections(self, subset: List[Dict[str, Any]], depth: int, empty: str) -> str:
        if not subset:
            return f'<p class="empty">{empty}</p>'
        by_wave: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
        for t in subset:
            by_wave[self.wave_key(t)].append(t)

        def sk(k: str) -> Tuple[int, str]:
            m = re.match(r"Wave (\d+)", k)
            return (0, f"{int(m.group(1)):05d}") if m else (1, k)

        parts = []
        for key in sorted(by_wave.keys(), key=sk, reverse=True):
            trails = by_wave[key]
            parts.append(
                f'<section class="wave">'
                f'<div class="wavehead"><h2>{esc(key)}</h2>'
                f'<span class="count">{len(trails)} task{"s" if len(trails) != 1 else ""}</span>'
                f'<span class="rule"></span></div>'
                f"{self.trail_table(trails, depth, empty)}</section>"
            )
        return "\n".join(parts)

    @staticmethod
    def seg(grouped: bool, wave_href: str, flat_href: str) -> str:
        wave_cur = ' aria-current="true"' if grouped else ""
        flat_cur = ' aria-current="true"' if not grouped else ""
        return (
            '<span class="seg" role="group" aria-label="Group work">'
            f'<a href="{wave_href}"{wave_cur}>by wave</a>'
            f'<a href="{flat_href}"{flat_cur}>flat</a>'
            "</span>"
        )

    def empty_teaches(self, what: str = "in this scope") -> str:
        return (
            f"No handoffs {esc(what)} yet. Run a dispatch wave, then "
            f"<code>make experience</code> to rebuild this page."
        )

    # ── work (grouped + flat, global and per-company) ─────────────────
    def work_pages(self, subset: List[Dict[str, Any]], base: Path, depth: int, scope: str) -> None:
        n = len(subset)
        noun = "trail" if n == 1 else "trails"
        head = f"""
    <div class="pagehead">
      <h1>Work</h1>
      <p class="lede">Scope <strong>{esc(scope)}</strong> · {n} {noun}.
      Trail is the atom; wave clusters atoms. Group by wave, or switch to a flat newest-first list.</p>
      <p>Group: {self.seg(True, "index.html", "flat/index.html")}</p>
    </div>
"""
        grouped = head + self.wave_sections(subset, depth, self.empty_teaches())
        write(base / "index.html", self.page(f"Work · {scope}" if scope != "global" else "Work", grouped, depth, scope, "work"))

        # Flat view lives one directory deeper; its segment links point back up.
        flat_head = f"""
    <div class="pagehead">
      <h1>Work — flat</h1>
      <p class="lede">Scope <strong>{esc(scope)}</strong> · {len(subset)} trail{"s" if len(subset) != 1 else ""}, newest first.</p>
      <p>Group: {self.seg(False, "../index.html", "index.html")}</p>
    </div>
"""
        flat = flat_head + self.trail_table(subset, depth + 1, self.empty_teaches())
        write(
            base / "flat" / "index.html",
            self.page(f"Work (flat) · {scope}" if scope != "global" else "Work (flat)", flat, depth + 1, scope, "work"),
        )

    # ── pages ─────────────────────────────────────────────────────────
    def home(self) -> None:
        c = self.d["counts"]
        fleet = self.d["fleet"]
        n_trails = c["trails"]
        done_pct = f"{fleet['n_done'] / n_trails:.0%}" if n_trails else "—"
        vendor_mix = " · ".join(f"{v} {n}" for v, n in fleet["vendor_mix"].items()) or "—"
        stats = f"""
    <div class="stats" role="group" aria-label="Fleet totals">
      <div class="stat"><div class="num">{n_trails}</div><div class="lbl">trails</div></div>
      <div class="stat"><div class="num">{esc(done_pct)} <small>· n={fleet["n_done"]}</small></div><div class="lbl">done</div></div>
      <div class="stat"><div class="num">{fleet["critic_rate"]:.0%} <small>of trails</small></div><div class="lbl">critic share</div></div>
      <div class="stat"><div class="num">{c["waves"]}</div><div class="lbl">waves</div></div>
      <div class="stat"><div class="num">{c["companies"]}</div><div class="lbl">companies</div></div>
      <div class="stat"><div class="num fit">{esc(vendor_mix)}</div><div class="lbl">vendor mix</div></div>
    </div>
"""
        co_cards = "".join(
            f'<a class="company-card{" dim" if str(co["status"]).lower() != "active" else ""}"'
            f' href="company/{esc(co["id"])}/index.html">'
            f'<strong>{esc(co["id"])}</strong>'
            f'<span class="sub">{esc(co["status"])} · n={co["trail_count"]}</span></a>'
            for co in self.companies
        )
        companies_card = f"""
      <div class="card">
        <div class="cardhead"><h2>Companies</h2></div>
        <div class="companies">{co_cards or '<p class="empty">No <code>companies/*.md</code> manifests yet.</p>'}</div>
      </div>
"""
        watchlist = self.d["watchlist"]
        watch = (
            '<ul class="tight">'
            + "".join(
                f'<li>{esc(w["theme"])} <span class="muted">×{w["count"]}</span></li>' for w in watchlist[:6]
            )
            + "</ul>"
            if watchlist
            else '<p class="empty">No recurring do-not-repeat themes (needs ≥2 similar lines across handoffs).</p>'
        )
        role_rows = "".join(
            f'<tr><td><a href="role/{esc(r)}/index.html">{esc(r)}</a></td>'
            f'<td class="num">{st["n"]}</td><td class="num">{st["n_done"]}</td>'
            f"<td>{self.pmi_badge(st['pmi']['band'])}</td></tr>"
            for r, st in sorted(self.d["role_stats"].items(), key=lambda kv: -kv[1]["n"])[:6]
        )
        roles_table = (
            f'<div class="tablewrap"><table><thead><tr><th>Role</th><th class="num">n</th>'
            f'<th class="num">done</th><th>PMI</th></tr></thead><tbody>{role_rows}</tbody></table></div>'
            if role_rows
            else '<p class="empty">No role usage yet — dispatch a task, then <code>make experience</code>.</p>'
        )
        skill_bits = "".join(
            f'<div><a href="skill/{esc(s["id"])}/index.html">{esc(s["id"])}</a> '
            f'<span class="muted mono">v{esc(s["version"])}</span></div>'
            for s in self.d["skills"]
            if s["status"] == "active"
        )
        candidates = [s for s in self.d["skills"] if s["status"] == "candidate"]
        cand_bit = f'<p class="muted">+ {len(candidates)} candidate{"s" if len(candidates) != 1 else ""}</p>' if candidates else ""
        n_doc = sum(1 for L in self.d["learnings"] if L["status"] == "documented")
        n_pro = sum(1 for L in self.d["learnings"] if L["status"] == "promoted")
        body = f"""
    <div class="pagehead">
      <h1>Global</h1>
      <p class="lede">The whole fleet: every trail, role, pack, and lesson projected from git artifacts.</p>
    </div>
    {stats}
    {companies_card}
    <div class="grid g2 mt">
      <div class="card">
        <div class="cardhead"><h2>Recent work</h2><a class="more" href="work/index.html">View all Work →</a></div>
        {self.trail_table(self.trails[:10], 0, self.empty_teaches("yet"))}
      </div>
      <div class="card">
        <div class="cardhead"><h2>Do-not-repeat watchlist</h2></div>
        {watch}
      </div>
    </div>
    <div class="grid g2r">
      <div class="card">
        <div class="cardhead"><h2>Roles (top)</h2><a class="more" href="roles/index.html">All roles →</a></div>
        {roles_table}
      </div>
      <div class="card">
        <div class="cardhead"><h2>Skills</h2><a class="more" href="skills/index.html">Library →</a></div>
        {skill_bits or '<p class="empty">No skill packs found under <code>skills/</code>.</p>'}
        {cand_bit}
        <h2 class="sec">Learnings</h2>
        <p class="muted">documented {n_doc} · promoted {n_pro}</p>
        <p><a href="learnings/index.html">Index →</a></p>
      </div>
    </div>
"""
        write(self.out / "index.html", self.page("Home", body, 0, "global", "home"))

    def trail_pages(self) -> None:
        for t in self.trails:
            sec = t["handoff_sections"]
            links = (
                " · ".join(
                    f'<a href="{esc(u)}">{esc(u)}</a>' if u.startswith("http") else f'<span class="mono">{esc(u)}</span>'
                    for u in t["issue_links"]
                )
                or '<span class="muted">none parsed</span>'
            )
            scope_label = t["company_id"] or t["project_label"] or "unlinked"
            if t["company_id"]:
                work_href = f"../../company/{esc(t['company_id'])}/work/index.html"
            else:
                work_href = "../../work/index.html"
            wave_label = f"wave {t['wave']}" if t["wave"] is not None else "no wave"
            crumb = self.crumb([("← Work", work_href), (scope_label, None), (wave_label, None)])
            prov = t["provenance"]
            join_note = f' <span class="muted">({esc(t["join_evidence"])})</span>' if t["join_evidence"] else ""
            conductor = ' <span class="pill accent">conductor</span>' if t["conductor"] else ""

            def section_block(title: str, key: str) -> str:
                text = sec[key]["text"].strip()
                if not text:
                    return ""
                return f'<h2 class="sec">{esc(title)}</h2><div class="body">{esc(text)}</div>'

            body = f"""
    {crumb}
    <div class="pagehead">
      <h1 class="mono">{esc(t["task_id"])}</h1>
      <p class="lede">{self.status_pill(t["status"])} {conductor}
      · role <strong>{esc(t["role"])}</strong> · {esc(wave_label)} · scope <strong>{esc(scope_label)}</strong></p>
    </div>
    <div class="card">
      <dl class="meta">
        <div><dt>Vendor · model</dt><dd class="mono">{esc(prov["vendor"])} · {esc(prov["model"])} <span class="muted">({esc(prov["host"])})</span></dd></div>
        <div><dt>Branch</dt><dd class="mono">{esc(t["branch"] or "—")}</dd></div>
        <div><dt>Base → head</dt><dd class="mono">{esc(t["base_sha"])}→{esc(t["head_sha"])}</dd></div>
        <div><dt>Exit</dt><dd class="mono">{esc(t["agent_exit"])}</dd></div>
        <div><dt>When</dt><dd class="mono">{esc(t["ts"])}</dd></div>
        <div><dt>Join</dt><dd><span class="mono">{esc(t["join_method"])}</span>{join_note}</dd></div>
        <div><dt>Links</dt><dd>{links}</dd></div>
        <div><dt>Source</dt><dd class="mono muted">{esc(t["source"]["jsonl"])}</dd></div>
      </dl>
    </div>
    <div class="card mt">
      <h2 class="sec">Plan line</h2>
      <p>{esc(t["plan_hint"]) or '<span class="muted">—</span>'}</p>
      {section_block("Built", "built")}
      {section_block("Decisions", "decisions")}
      {section_block("Do not repeat", "do_not_repeat")}
      {section_block("Evidence", "evidence")}
      {section_block("Open questions", "open_questions")}
      {section_block("Next hint", "next_hint")}
      <details><summary>Raw handoff record (audit, redacted)</summary><pre>{esc(t["handoff_markdown"])}</pre></details>
    </div>
"""
            write(
                self.out / "trail" / t["task_id"] / "index.html",
                self.page(t["task_id"], body, 2, t["company_id"] or "global", "work"),
            )

    def company_pages(self) -> None:
        learnings = self.d["learnings"]
        for c in self.companies:
            cid = c["id"]
            subset = [t for t in self.trails if t["company_id"] == cid]
            empty = (
                f"No handoffs joined to {esc(cid)} yet — join gaps are OK in Phase 0. "
                f"See join rules on <a href=\"../../about/index.html\">About</a>, then "
                f"<code>make experience</code> after the next dispatch."
            )
            gh = c["github_repo"]
            gh_html = (
                f'<a class="mono" href="https://github.com/{esc(gh)}">{esc(gh)}</a>' if gh else '<span class="mono">—</span>'
            )
            status_kind = "ok" if str(c["status"]).lower() == "active" else ""
            co_learnings = [L for L in learnings if L.get("company_id") == cid]
            learn_bits = "".join(
                f'<div><a href="../../learning/{esc(L["slug"])}/index.html">{esc(L["title"])}</a> '
                f'<span class="pill">{esc(L["status"])}</span></div>'
                for L in co_learnings
            )
            body = f"""
    {self.crumb([("← Home", "../../index.html"), ("companies", None), (cid, None)])}
    <div class="pagehead">
      <h1>{esc(cid)} <span class="pill {status_kind}">{esc(c["status"])}</span></h1>
      <p class="lede">{esc(c["phase_note"] or "No phase note recorded.")}</p>
    </div>
    <div class="card">
      <dl class="meta">
        <div><dt>Repo</dt><dd class="mono">{esc(c["repo"] or "—")}</dd></div>
        <div><dt>GitHub</dt><dd>{gh_html}</dd></div>
        <div><dt>Joined trails</dt><dd>n={c["trail_count"]}</dd></div>
        <div><dt>Manifest</dt><dd class="mono muted">{esc(c["source"])}</dd></div>
      </dl>
      <p class="flush"><a href="work/index.html">Open Work for {esc(cid)} →</a></p>
    </div>
    <div class="card mt">
      <div class="cardhead"><h2>Work trails (joined only)</h2></div>
      {self.trail_table(subset[:20], 2, empty)}
    </div>
    <div class="card mt">
      <div class="cardhead"><h2>Learnings</h2></div>
      {learn_bits or f'<p class="empty">No learnings discovered for {esc(cid)} yet. Fleet learnings live under <code>learnings/</code>; product learnings are picked up when the repo is on disk.</p>'}
      <p class="muted flush">Skill packs are fleet-global in Phase 0 — see <a href="../../skills/index.html">Skills</a>.</p>
    </div>
"""
            write(self.out / "company" / cid / "index.html", self.page(cid, body, 2, cid))
            self.work_pages(subset, self.out / "company" / cid / "work", 3, cid)

    def role_pages(self) -> None:
        stats = self.d["role_stats"]
        rows = "".join(
            f'<tr><td><a href="../role/{esc(r)}/index.html">{esc(r)}</a></td>'
            f'<td class="num">{st["n"]}</td><td class="num">{st["n_done"]}</td><td class="num">{st["n_fail"]}</td>'
            f'<td>{st["success_rate"]:.0%} · n={st["n_known"]}</td>'
            f'<td class="mono muted">{esc(", ".join(f"{v} {n}" for v, n in st["vendor_mix"].items()) or "—")}</td>'
            f"<td>{self.pmi_badge(st['pmi']['band'])}</td></tr>"
            for r, st in sorted(stats.items(), key=lambda kv: -kv[1]["n"])
        )
        policy = self.d["pmi_policy"]
        body = f"""
    <div class="pagehead">
      <h1>Roles</h1>
      <p class="lede">Usage plus the Playbook Maturity Index (PMI) — a score over each role's
      playbook system and recorded outcomes, never an agent IQ badge.</p>
    </div>
    <div class="card">
      <p class="muted">P2 requires outcomes: n_done ≥ {policy["p2_min_done"]} and success ≥
      {policy["p2_min_success"]:.0%} — a dedicated pack alone never grants P2.
      Phase 0 caps display at {esc(policy["phase0_cap"])}: {esc(policy["cap_reason"])}.
      Percentages always sit next to their <em>n</em>.</p>
      {('<div class="tablewrap"><table><thead><tr><th>Role</th><th class="num">n</th><th class="num">done</th><th class="num">fail</th><th>success</th><th>vendors</th><th>PMI</th></tr></thead><tbody>' + rows + "</tbody></table></div>") if rows else '<p class="empty">No role data yet — dispatch a task, then <code>make experience</code>.</p>'}
    </div>
"""
        write(self.out / "roles" / "index.html", self.page("Roles", body, 1, "global", "roles"))

        for role, st in stats.items():
            subset = [t for t in self.trails if t["role"] == role]
            pmi = st["pmi"]
            inputs = pmi["inputs"]
            input_rows = "".join(
                f"<li>{esc(k)} = {esc(', '.join(map(str, v)) if isinstance(v, list) else v)}</li>"
                for k, v in inputs.items()
            )
            packs = ", ".join(st["packs"]) or "—"
            specialized = ", ".join(st["specialized_packs"]) or "none"
            critic = ' <span class="pill">critic seat</span>' if st["is_critic"] else ""
            body = f"""
    {self.crumb([("← Roles", "../index.html"), (role, None)])}
    <div class="pagehead">
      <h1>{esc(role)} {self.pmi_badge(pmi["band"])}{critic}</h1>
      <p class="lede">{esc(pmi["reason"])}</p>
    </div>
    <div class="card">
      <div class="stats">
        <div class="stat"><div class="num">{st["n"]}</div><div class="lbl">trails</div></div>
        <div class="stat"><div class="num">{st["n_done"]}</div><div class="lbl">done</div></div>
        <div class="stat"><div class="num">{st["n_fail"]}</div><div class="lbl">fail</div></div>
        <div class="stat"><div class="num">{st["success_rate"]:.0%} <small>· n={st["n_known"]}</small></div><div class="lbl">success</div></div>
      </div>
      <p class="muted">Display capped at {esc(pmi["cap"])} — {esc(pmi["cap_reason"])}.</p>
      <details open><summary>PMI inputs (from data/index.json)</summary>
        <ul class="tight mono">{input_rows}</ul>
      </details>
      <p class="muted flush">Injected packs: <span class="mono">{esc(packs)}</span><br/>
      Specialized packs (beyond shared defaults): <span class="mono">{esc(specialized)}</span> — a boost label, never a P2 shortcut.</p>
    </div>
    <div class="card mt">
      <div class="cardhead"><h2>Trails</h2></div>
      {self.trail_table(subset[:50], 2, "None recorded.")}
    </div>
"""
            write(self.out / "role" / role / "index.html", self.page(role, body, 2, "global", "roles"))

    def skill_pages(self) -> None:
        def pill(status: str) -> str:
            cls = "accent" if status == "candidate" else "ok"
            return f'<span class="pill {cls}">{esc(status)}</span>'

        rows = "".join(
            f'<tr><td><a href="../skill/{esc(s["id"])}/index.html" class="mono">{esc(s["id"])}</a></td>'
            f'<td class="mono">v{esc(s["version"])}</td><td>{pill(s["status"])}</td>'
            f'<td class="muted">{esc(s["summary"])}</td>'
            f'<td class="mono muted">{esc(", ".join(s["roles"]) or "—")}</td></tr>'
            for s in self.d["skills"]
        )
        body = f"""
    <div class="pagehead">
      <h1>Skills</h1>
      <p class="lede">Pack library with promotion status. Promotion stays PR-only — this page never writes skills.</p>
    </div>
    <div class="card">
      {('<div class="tablewrap"><table><thead><tr><th>Pack</th><th>Ver</th><th>Status</th><th>Summary</th><th>Injected by</th></tr></thead><tbody>' + rows + "</tbody></table></div>") if rows else '<p class="empty">No skill packs found under <code>skills/</code>.</p>'}
    </div>
"""
        write(self.out / "skills" / "index.html", self.page("Skills", body, 1, "global", "skills"))
        for s in self.d["skills"]:
            body = f"""
    {self.crumb([("← Skills", "../index.html"), (s["id"], None)])}
    <div class="pagehead">
      <h1 class="mono">{esc(s["id"])} {pill(s["status"])}</h1>
      <p class="lede">{esc(s["summary"])}</p>
    </div>
    <div class="card">
      <dl class="meta">
        <div><dt>Version</dt><dd class="mono">v{esc(s["version"])}</dd></div>
        <div><dt>Scope</dt><dd class="mono">{esc(s["scope"])}</dd></div>
        <div><dt>Injected by</dt><dd class="mono">{esc(", ".join(s["roles"]) or "—")}</dd></div>
        <div><dt>Path</dt><dd class="mono muted">{esc(s["path"])}</dd></div>
      </dl>
      <p class="muted flush">To promote a candidate or change a pack: open a PR — never from this UI.</p>
    </div>
    <div class="card mt">
      <div class="cardhead"><h2>Body</h2></div>
      <div class="body">{esc(s["body"])}</div>
    </div>
"""
            write(self.out / "skill" / s["id"] / "index.html", self.page(s["id"], body, 2, "global", "skills"))

    def learning_pages(self) -> None:
        def pill(status: str) -> str:
            cls = "ok" if status == "promoted" else ""
            return f'<span class="pill {cls}">{esc(status)}</span>'

        rows = "".join(
            f'<tr><td><a href="../learning/{esc(L["slug"])}/index.html">{esc(L["title"])}</a></td>'
            f"<td>{pill(L['status'])}</td>"
            f'<td class="mono muted">{esc(L.get("company_id") or "fleet")}</td>'
            f'<td class="mono muted">{esc(L["path"])}</td></tr>'
            for L in self.d["learnings"]
        )
        body = f"""
    <div class="pagehead">
      <h1>Learn</h1>
      <p class="lede">documented = the file exists · promoted = a skill body cites it via [ev:]. Promotion remains PR-only.</p>
    </div>
    <div class="card">
      {('<div class="tablewrap"><table><thead><tr><th>Title</th><th>Status</th><th>Scope</th><th>Path</th></tr></thead><tbody>' + rows + "</tbody></table></div>") if rows else '<p class="empty">No learnings yet — write one under <code>learnings/</code>, then <code>make experience</code>.</p>'}
    </div>
"""
        write(self.out / "learnings" / "index.html", self.page("Learn", body, 1, "global", "learn"))
        for L in self.d["learnings"]:
            scope = L.get("company_id") or "fleet"
            body = f"""
    {self.crumb([("← Learn", "../index.html"), (L["slug"], None)])}
    <div class="pagehead">
      <h1>{esc(L["title"])} {pill(L["status"])}</h1>
      <p class="lede">scope <span class="mono">{esc(scope)}</span> · <span class="mono muted">{esc(L["path"])}</span></p>
    </div>
    <div class="card"><div class="body">{esc(L["body"])}</div></div>
"""
            write(self.out / "learning" / L["slug"] / "index.html", self.page(L["slug"], body, 2, "global", "learn"))

    def conductor(self) -> None:
        subset = [t for t in self.trails if t["conductor"]]
        body = f"""
    <div class="pagehead">
      <h1>Conductor</h1>
      <p class="lede">One-shot plans under <span class="mono">wave-plans/conductor/</span> — Session Modes Phase 0.</p>
    </div>
    <div class="card">
      {self.trail_table(subset, 1, "No conductor handoffs yet. Conductor plans live under <code>wave-plans/conductor/</code>; run one, then <code>make experience</code>.")}
    </div>
"""
        write(self.out / "conductor" / "index.html", self.page("Conductor", body, 1, "global", "conductor"))

    def about(self) -> None:
        c = self.d["counts"]
        joins = "".join(
            f'<li><span class="mono">{esc(r["method"])}</span> — {esc(r["source"])}</li>' for r in self.d["join_rules"]
        )
        policy = self.d["pmi_policy"]
        warnings = (
            '<ul class="tight">' + "".join(f"<li>{esc(w)}</li>" for w in self.d["warnings"]) + "</ul>"
            if self.d["warnings"]
            else '<p class="muted">none</p>'
        )
        body = f"""
    <div class="pagehead">
      <h1>About Fleet Desk</h1>
      <p class="lede">A Phase 0 read-only projection of git artifacts. Law: <span class="mono">{esc(self.d["law"])}</span></p>
    </div>
    <div class="card">
      <h2 class="sec">This build</h2>
      <p>Generated <strong>{esc(self.generated)}</strong> · {c["trails"]} trails · {c["companies"]} companies ·
      {c["skills"]} skill packs · {c["learnings"]} learnings · {c["unlinked_trails"]} unlinked trails</p>
      <h2 class="sec">Data contract</h2>
      <p>Every page is rendered from <a href="../data/index.json" class="mono">data/index.json</a>
      (schema v{esc(self.d["schema_version"])}, documented in <span class="mono">docs/experience-data.md</span>).
      The HTML never reads the repo directly.</p>
      <h2 class="sec">Sources</h2>
      <ul class="tight mono">
        <li>companies/*.md</li>
        <li>wave-plans/**/handoffs/*.jsonl + *.md</li>
        <li>skills/*/SKILL.md · config/role-skills.yaml</li>
        <li>learnings/* · product docs/qa/learning-*.md when on disk</li>
      </ul>
      <p class="muted">Agent transcript logs are never ingested — only the log filename is used as a join hint.</p>
      <h2 class="sec">Join rules (in order)</h2>
      <ol class="tight">{joins}</ol>
      <h2 class="sec">PMI</h2>
      <p>P0 n&lt;{policy["p1_min_n"]} · P1 n≥{policy["p1_min_n"]} ·
      P2 n_done≥{policy["p2_min_done"]} AND success≥{policy["p2_min_success"]:.0%} ·
      P3 Phase 1 only (display capped at {esc(policy["phase0_cap"])}: {esc(policy["cap_reason"])}).</p>
      <h2 class="sec">Build warnings</h2>
      {warnings}
      <h2 class="sec">How to refresh</h2>
      <pre>make experience
make experience-open   # build + open browser
make desk              # alias</pre>
      <p class="muted flush">See <span class="mono">docs/experience.md</span> and
      <span class="mono">docs/experience-data.md</span>.</p>
    </div>
"""
        write(self.out / "about" / "index.html", self.page("About", body, 1, "global", "about"))

    def render(self) -> None:
        clean_html(self.out)
        write_assets(self.out)
        self.home()
        self.work_pages(self.trails, self.out / "work", 1, "global")
        self.trail_pages()
        self.company_pages()
        self.role_pages()
        self.skill_pages()
        self.learning_pages()
        self.conductor()
        self.about()


def main() -> None:
    default_repo = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description="Fleet Desk HTML renderer — reads site/experience/data/index.json")
    ap.add_argument("--repo", default=str(default_repo), help="repo root (used only to locate the default site dir)")
    ap.add_argument("--out", default="", help="site dir containing data/index.json")
    ap.add_argument("--data", default="", help="explicit path to data/index.json")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    out = Path(args.out).resolve() if args.out else repo / "site" / "experience"
    data_path = Path(args.data).resolve() if args.data else out / "data" / "index.json"

    if not data_path.is_file():
        # Convenience: standalone runs still work — build the contract first.
        experience_data.write_dataset(repo, out)

    data = json.loads(data_path.read_text(encoding="utf-8"))
    if data.get("schema_version") != experience_data.SCHEMA_VERSION:
        raise SystemExit(
            f"schema mismatch: {data_path} is v{data.get('schema_version')}, "
            f"renderer expects v{experience_data.SCHEMA_VERSION} — re-run scripts/experience_data.py"
        )
    Renderer(data, out).render()
    print(f"Fleet Desk wrote {out} ({data['counts']['trails']} trails, {data['counts']['companies']} companies)")


if __name__ == "__main__":
    main()
