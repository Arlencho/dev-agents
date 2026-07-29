#!/usr/bin/env python3
"""
Fleet Desk — HTML renderer (Phase 0 presentation).

Reads ONLY the data contract emitted by scripts/experience_data.py:

    site/experience/data/index.json    (schema: docs/experience-data.md)

and writes static pages next to it. No repo scanning happens here — if a field
is missing from the JSON it does not belong on the page. Law:
docs/proposals/experience-console-SYNTHESIS.md
"""
from __future__ import annotations

import argparse
import html
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List

import experience_data


def esc(s: Any) -> str:
    return html.escape("" if s is None else str(s), quote=True)


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


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

TRAIL_COLS = "<tr><th>Status</th><th>Role</th><th>Scope</th><th>Wave</th><th>Task</th><th>When</th></tr>"


class Renderer:
    def __init__(self, data: Dict[str, Any], out: Path):
        self.d = data
        self.out = out
        self.companies = data["companies"]
        self.trails = data["trails"]
        self.generated = data["generated_at"]

    # ── shell ─────────────────────────────────────────────────────────
    def pre(self, depth: int) -> str:
        return "" if depth == 0 else "../" * depth

    def page(self, title: str, body: str, depth: int, scope: str = "global") -> str:
        pre = self.pre(depth)
        nav = [
            ("Home", f"{pre}index.html"),
            ("Work", f"{pre}work/index.html"),
            ("Skills", f"{pre}skills/index.html"),
            ("Learn", f"{pre}learnings/index.html"),
            ("Roles", f"{pre}roles/index.html"),
            ("Conductor", f"{pre}conductor/index.html"),
            ("About", f"{pre}about/index.html"),
        ]
        chips = [f'<a class="chip {"active" if scope == "global" else ""}" href="{pre}index.html">Global</a>']
        for c in self.companies:
            active = "active" if scope == c["id"] else ""
            ph = " placeholder" if str(c["status"]).lower() != "active" else ""
            chips.append(
                f'<a class="chip {active}{ph}" href="{pre}company/{esc(c["id"])}/index.html">{esc(c["id"])}</a>'
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
      <div class="tag">What the fleet did, learned, and now knows how to do. · generated {esc(self.generated)}</div>
      <nav class="nav" aria-label="Primary">{nav_html}</nav>
      <div class="scope" aria-label="Scope">{"".join(chips)}</div>
    </header>
    <main id="main">
      {body}
    </main>
    <footer class="footer">
      Fleet Desk Phase 0 · read-only · <span class="mono">make experience</span> ·
      data <a href="{self.pre(depth)}data/index.json">data/index.json</a> (schema v{esc(self.d["schema_version"])}) ·
      law: <span class="mono">{esc(self.d["law"])}</span>
    </footer>
  </div>
</body>
</html>
"""

    # ── fragments ─────────────────────────────────────────────────────
    @staticmethod
    def status_class(status: str) -> str:
        if status == "done":
            return "status-done"
        if status in ("failed", "fail", "unavailable", "error"):
            return "status-fail"
        return "status-unk"

    def trail_row(self, t: Dict[str, Any], depth: int) -> str:
        pre = self.pre(depth)
        href = f"{pre}trail/{esc(t['task_id'])}/index.html"
        label = t["company_id"] or t["project_label"] or "unlinked"
        wave = f"wave {t['wave']}" if t["wave"] is not None else "wave —"
        return (
            "<tr>"
            f'<td class="{self.status_class(t["status"])}">{esc(t["status"])}</td>'
            f'<td><a href="{href}">{esc(t["agent"])}</a></td>'
            f'<td class="mono">{esc(label)}</td>'
            f"<td>{esc(wave)}</td>"
            f'<td class="mono"><a href="{href}">{esc(t["task_id"])}</a></td>'
            f'<td class="muted mono">{esc((t["ts"] or "")[:16])}</td>'
            "</tr>"
        )

    def trail_table(self, subset: List[Dict[str, Any]], depth: int, empty: str) -> str:
        rows = "".join(self.trail_row(t, depth) for t in subset)
        if not rows:
            rows = f'<tr><td colspan="6" class="empty">{empty}</td></tr>'
        return f"<table><thead>{TRAIL_COLS}</thead><tbody>{rows}</tbody></table>"

    def work_body(self, subset: List[Dict[str, Any]], depth: int, scope: str) -> str:
        by_wave: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
        for t in subset:
            key = f"Wave {t['wave']}" if t["wave"] is not None else "Unlinked / no wave"
            by_wave[key].append(t)

        def sk(k: str):
            m = re.match(r"Wave (\d+)", k)
            return (0, f"{int(m.group(1)):05d}") if m else (1, k)

        parts = [
            '<div class="card"><h1>Work</h1>'
            f'<p class="muted">Scope: <strong>{esc(scope)}</strong> · group by wave · '
            f"{len(subset)} trails · trail is the atom; wave clusters atoms.</p></div>"
        ]
        if not subset:
            parts.append(
                '<div class="card empty">No handoffs in this scope. Run dispatch, then '
                '<span class="mono">make experience</span>.</div>'
            )
        for key in sorted(by_wave.keys(), key=sk, reverse=True):
            parts.append(
                '<div class="card" style="margin-top:12px">'
                f'<div class="wave-h">{esc(key)} · {len(by_wave[key])} tasks</div>'
                f'{self.trail_table(by_wave[key], depth, "none")}</div>'
            )
        return "\n".join(parts)

    # ── pages ─────────────────────────────────────────────────────────
    def home(self) -> None:
        co_cards = "".join(
            f'<a class="company-card" href="company/{esc(c["id"])}/index.html">'
            f'<strong>{esc(c["id"])}</strong>'
            f'<span class="muted">{esc(c["status"])} · {c["trail_count"]} trails</span></a>'
            for c in self.companies
        )
        role_rows = "".join(
            f'<tr><td><a href="role/{esc(r)}/index.html">{esc(r)}</a></td>'
            f'<td>{st["n"]}</td><td>{st["n_done"]}</td>'
            f'<td class="pmi">{esc(st["pmi"]["band"])}</td></tr>'
            for r, st in sorted(self.d["role_stats"].items(), key=lambda kv: -kv[1]["n"])[:8]
        )
        skill_bits = "".join(
            f'<div><a href="skill/{esc(s["id"])}/index.html">{esc(s["id"])}</a> '
            f'<span class="muted mono">v{s["version"]}</span></div>'
            for s in self.d["skills"]
            if s["status"] == "active"
        )
        learn_bits = (
            f"documented {sum(1 for L in self.d['learnings'] if L['status'] == 'documented')} · "
            f"promoted {sum(1 for L in self.d['learnings'] if L['status'] == 'promoted')}"
        )
        themes = self.d["watchlist"]
        watch = (
            "<ul>" + "".join(f'<li>{esc(w["theme"])} <span class="muted">×{w["count"]}</span></li>' for w in themes[:6]) + "</ul>"
            if themes
            else '<p class="empty">No recurring do-not-repeat themes (need ≥2 similar lines).</p>'
        )
        empty_work = (
            'No handoffs yet — run <span class="mono">./scripts/dispatch.sh …</span> then '
            '<span class="mono">make experience</span>.'
        )
        body = f"""
    <div class="card"><h2>Companies</h2><div class="companies">{co_cards or '<p class="empty">No companies/</p>'}</div></div>
    <div class="grid two" style="margin-top:14px">
      <div class="card">
        <h2>Recent work <a href="work/index.html" style="float:right;font-weight:500">View all Work →</a></h2>
        {self.trail_table(self.trails[:15], 0, empty_work)}
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
        <tbody>{role_rows or '<tr><td colspan="4" class="empty">No trails</td></tr>'}</tbody></table>
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
        write(self.out / "index.html", self.page("Home", body, 0, "global"))

    def work(self) -> None:
        write(self.out / "work" / "index.html", self.page("Work", self.work_body(self.trails, 1, "global"), 1))

    def trail_pages(self) -> None:
        for t in self.trails:
            sec = t["handoff_sections"]
            links = (
                " · ".join(
                    f'<a href="{esc(u)}">{esc(u)}</a>' if u.startswith("http") else esc(u) for u in t["issue_links"]
                )
                or '<span class="muted">none parsed</span>'
            )
            scope_label = t["company_id"] or t["project_label"] or "unlinked"
            join_note = f' <span class="muted">({esc(t["join_evidence"])})</span>' if t["join_evidence"] else ""
            prov = t["provenance"]
            body = f"""
        <div class="card">
          <h1 class="mono">{esc(t["task_id"])}</h1>
          <p>
            <span class="{self.status_class(t["status"])}">{esc(t["status"])}</span>
            · role <strong>{esc(t["agent"])}</strong>
            · wave <strong>{esc(t["wave"] if t["wave"] is not None else "—")}</strong>
            · scope <strong>{esc(scope_label)}</strong>
            · join <span class="mono">{esc(t["join_method"])}</span>{join_note}
            {"· conductor" if t["conductor"] else ""}
          </p>
          <p class="mono muted">
            vendor {esc(prov["vendor"])} {esc(prov["model"])} · branch {esc(t["branch"])} ·
            {esc(t["base_sha"])}→{esc(t["head_sha"])} · exit {esc(t["agent_exit"])} · {esc(t["ts"])}
          </p>
          <p>Links: {links}</p>
          <p class="muted mono">source {esc(t["source"]["jsonl"])}</p>
        </div>
        <div class="card" style="margin-top:12px">
          <h2>Plan / title</h2>
          <p>{esc(t["plan_hint"]) or '<span class="muted">—</span>'}</p>
          <h2>Built</h2><div class="body">{esc(sec["built"]["text"]) or "—"}</div>
          <h2>Decisions</h2><div class="body">{esc(sec["decisions"]["text"]) or "—"}</div>
          <h2>Do not repeat</h2><div class="body">{esc(sec["do_not_repeat"]["text"]) or "—"}</div>
          <h2>Evidence</h2><div class="body">{esc(sec["evidence"]["text"]) or "—"}</div>
          <details><summary>Handoff markdown (redacted)</summary><pre>{esc(t["handoff_markdown"])}</pre></details>
        </div>
        """
            write(
                self.out / "trail" / t["task_id"] / "index.html",
                self.page(t["task_id"], body, 2, t["company_id"] or "global"),
            )

    def company_pages(self) -> None:
        for c in self.companies:
            subset = [t for t in self.trails if t["company_id"] == c["id"]]
            empty = f"No handoffs joined to {esc(c['id'])} yet (join gaps are OK in Phase 0)."
            body = f"""
        <div class="card">
          <h1>{esc(c["id"])}</h1>
          <p class="muted">{esc(c["status"])} · repo <span class="mono">{esc(c["repo"] or "—")}</span>
          · github <span class="mono">{esc(c["github_repo"] or "—")}</span></p>
          <p class="muted">{esc(c["phase_note"])}</p>
          <p><a href="work/index.html">Open Work for {esc(c["id"])} →</a></p>
        </div>
        <div class="card" style="margin-top:12px">
          <h2>Work trails (joined)</h2>
          {self.trail_table(subset[:20], 2, empty)}
        </div>
        """
            write(self.out / "company" / c["id"] / "index.html", self.page(c["id"], body, 2, c["id"]))
            write(
                self.out / "company" / c["id"] / "work" / "index.html",
                self.page(f"Work · {c['id']}", self.work_body(subset, 3, c["id"]), 3, c["id"]),
            )

    def role_pages(self) -> None:
        stats = self.d["role_stats"]
        rows = "".join(
            f'<tr><td><a href="../role/{esc(r)}/index.html">{esc(r)}</a></td>'
            f'<td>{st["n"]}</td><td>{st["n_done"]}</td><td>{st["n_fail"]}</td>'
            f'<td>{st["success_rate"]:.0%} · n={st["n_known"]}</td>'
            f'<td class="mono">{esc(", ".join(f"{v} {n}" for v, n in st["vendor_mix"].items()) or "—")}</td>'
            f'<td class="pmi">{esc(st["pmi"]["band"])}</td></tr>'
            for r, st in sorted(stats.items(), key=lambda kv: -kv[1]["n"])
        )
        policy = self.d["pmi_policy"]
        index = f"""
    <div class="card">
      <h1>Roles</h1>
      <p class="muted">Usage + Playbook Maturity Index (PMI). P2 requires outcomes
      (n_done ≥ {policy["p2_min_done"]} and success ≥ {policy["p2_min_success"]:.0%});
      a dedicated pack alone does not grant P2. Phase 0 caps display at {esc(policy["phase0_cap"])} —
      {esc(policy["cap_reason"])}.</p>
      <table>
        <thead><tr><th>Role</th><th>n</th><th>done</th><th>fail</th><th>success</th><th>vendors</th><th>PMI</th></tr></thead>
        <tbody>{rows or '<tr><td colspan="7" class="empty">No data</td></tr>'}</tbody>
      </table>
    </div>
    """
        write(self.out / "roles" / "index.html", self.page("Roles", index, 1))

        for role, st in stats.items():
            subset = [t for t in self.trails if t["agent"] == role]
            packs = ", ".join(st["packs"]) or "—"
            inputs = st["pmi"]["inputs"]
            input_rows = "".join(
                f"<li>{esc(k)}={esc(', '.join(map(str, v)) if isinstance(v, list) else v)}</li>"
                for k, v in inputs.items()
            )
            body = f"""
        <div class="card">
          <h1>{esc(role)}</h1>
          <p>n={st["n"]} · done={st["n_done"]} · fail={st["n_fail"]} ·
          success {st["success_rate"]:.0%} · n_known={st["n_known"]} ·
          <span class="pmi">{esc(st["pmi"]["band"])}</span></p>
          <p class="muted">{esc(st["pmi"]["reason"])}</p>
          <p class="muted">Display capped at {esc(st["pmi"]["cap"])} — {esc(st["pmi"]["cap_reason"])}.</p>
          <details open><summary>PMI inputs (from data/index.json)</summary>
            <ul class="mono">{input_rows}</ul>
          </details>
          <p class="muted">Injected packs: <span class="mono">{esc(packs)}</span></p>
        </div>
        <div class="card" style="margin-top:12px">
          <h2>Trails</h2>
          {self.trail_table(subset[:50], 2, "None")}
        </div>
        """
            write(self.out / "role" / role / "index.html", self.page(role, body, 2))

    def skill_pages(self) -> None:
        rows = "".join(
            f'<tr><td><a href="../skill/{esc(s["id"])}/index.html">{esc(s["id"])}</a></td>'
            f'<td class="mono">v{s["version"]}</td><td>{esc(s["status"])}</td>'
            f'<td class="muted">{esc(s["summary"])}</td>'
            f'<td class="mono">{esc(", ".join(s["roles"]) or "—")}</td></tr>'
            for s in self.d["skills"]
        )
        index = f"""
    <div class="card">
      <h1>Skills</h1>
      <p class="muted">Promotion is PR-only (skills-evolution SYNTHESIS). This page is read-only status.</p>
      <table>
        <thead><tr><th>Pack</th><th>Ver</th><th>Status</th><th>Summary</th><th>Roles</th></tr></thead>
        <tbody>{rows or '<tr><td colspan="5" class="empty">No skills</td></tr>'}</tbody>
      </table>
    </div>
    """
        write(self.out / "skills" / "index.html", self.page("Skills", index, 1))
        for s in self.d["skills"]:
            body = f"""
        <div class="card">
          <h1 class="mono">{esc(s["id"])}</h1>
          <p>v{s["version"]} · {esc(s["status"])} · scope {esc(s["scope"])}</p>
          <p>{esc(s["summary"])}</p>
          <p class="muted mono">{esc(s["path"])}</p>
          <p>Injected by: <span class="mono">{esc(", ".join(s["roles"]) or "—")}</span></p>
          <p class="muted">To promote candidates or change packs: open a PR — never from this UI.</p>
        </div>
        <div class="card" style="margin-top:12px">
          <h2>Body</h2>
          <div class="body">{esc(s["body"])}</div>
        </div>
        """
            write(self.out / "skill" / s["id"] / "index.html", self.page(s["id"], body, 2))

    def learning_pages(self) -> None:
        rows = "".join(
            f'<tr><td><a href="../learning/{esc(L["slug"])}/index.html">{esc(L["slug"])}</a></td>'
            f'<td>{esc(L["status"])}</td><td>{esc(L["title"])}</td>'
            f'<td class="mono muted">{esc(L["path"])}</td></tr>'
            for L in self.d["learnings"]
        )
        index = f"""
    <div class="card">
      <h1>Learnings</h1>
      <p class="muted">documented = file exists · promoted = cited from a skill via [ev:]. Promotion remains PR-only.</p>
      <table>
        <thead><tr><th>Slug</th><th>Status</th><th>Title</th><th>Path</th></tr></thead>
        <tbody>{rows or '<tr><td colspan="4" class="empty">No learnings</td></tr>'}</tbody>
      </table>
    </div>
    """
        write(self.out / "learnings" / "index.html", self.page("Learnings", index, 1))
        for L in self.d["learnings"]:
            body = f"""
        <div class="card">
          <h1>{esc(L["title"])}</h1>
          <p>status <strong>{esc(L["status"])}</strong> · <span class="mono">{esc(L["path"])}</span></p>
        </div>
        <div class="card" style="margin-top:12px"><div class="body">{esc(L["body"])}</div></div>
        """
            write(self.out / "learning" / L["slug"] / "index.html", self.page(L["slug"], body, 2))

    def conductor(self) -> None:
        subset = [t for t in self.trails if t["conductor"]]
        body = f"""
    <div class="card">
      <h1>Conductor</h1>
      <p class="muted">One-shot plans under <span class="mono">wave-plans/conductor/</span> · Session Modes Phase 0.</p>
      {self.trail_table(subset, 1, "No conductor handoffs yet.")}
    </div>
    """
        write(self.out / "conductor" / "index.html", self.page("Conductor", body, 1))

    def about(self) -> None:
        c = self.d["counts"]
        joins = "".join(
            f'<li><span class="mono">{esc(r["method"])}</span> — {esc(r["source"])}</li>' for r in self.d["join_rules"]
        )
        policy = self.d["pmi_policy"]
        warnings = (
            "<ul>" + "".join(f"<li>{esc(w)}</li>" for w in self.d["warnings"]) + "</ul>"
            if self.d["warnings"]
            else '<p class="muted">none</p>'
        )
        body = f"""
    <div class="card">
      <h1>About Fleet Desk</h1>
      <p>Phase 0 read-only projection. Law: <span class="mono">{esc(self.d["law"])}</span></p>
      <p>Generated <strong>{esc(self.generated)}</strong> · {c["trails"]} trails · {c["companies"]} companies ·
      {c["skills"]} skill packs · {c["learnings"]} learnings · {c["unlinked_trails"]} unlinked trails</p>
      <h2>Data contract</h2>
      <p>Every page on this site is rendered from
      <a href="../data/index.json"><span class="mono">data/index.json</span></a>
      (schema v{esc(self.d["schema_version"])}, documented in <span class="mono">docs/experience-data.md</span>).
      HTML never reads the repo directly.</p>
      <h2>Sources</h2>
      <ul class="mono">
        <li>companies/*.md</li>
        <li>wave-plans/**/handoffs/*.jsonl + *.md</li>
        <li>skills/*/SKILL.md · config/role-skills.yaml</li>
        <li>learnings/* · product docs/qa/learning-*.md when on disk</li>
      </ul>
      <p class="muted">Agent transcript logs are never ingested — only the log filename is used as a join hint.</p>
      <h2>Join rules (in order)</h2>
      <ol>{joins}</ol>
      <h2>PMI</h2>
      <p>P0 n&lt;{policy["p1_min_n"]} · P1 n≥{policy["p1_min_n"]} ·
      P2 n_done≥{policy["p2_min_done"]} AND success≥{policy["p2_min_success"]:.0%} ·
      P3 Phase 1 only (display capped at {esc(policy["phase0_cap"])}: {esc(policy["cap_reason"])}).</p>
      <h2>Build warnings</h2>
      {warnings}
      <h2>How to refresh</h2>
      <pre>make experience
make experience-open   # build + open browser
make desk              # alias</pre>
      <p class="muted">See <span class="mono">docs/experience.md</span> and
      <span class="mono">docs/experience-data.md</span>.</p>
    </div>
    """
        write(self.out / "about" / "index.html", self.page("About", body, 1))

    def render(self) -> None:
        self.home()
        self.work()
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
