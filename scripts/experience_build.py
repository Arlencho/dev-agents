#!/usr/bin/env python3
"""
Fleet Desk — HTML renderer (v2: Almanac restyle + hierarchy + mission shells).

Reads ONLY the data contract emitted by scripts/experience_data.py:

    site/experience/data/index.json    (schema: docs/experience-data.md)

and writes static pages plus a copied stylesheet next to it:

    site/experience/assets/site.css    (from templates/experience/site.css)

No repo scanning happens here — if a field is missing from the JSON it does not
belong on the page. Missions are a pure derivation over schema v2 fields
(issue_links, company_id, wave, status) — see docs/experience-data.md
§ Derived views; the schema itself is unchanged. The /live/ Ops Floor renders a
labeled snapshot of data/live.json (schema live/1, written by
scripts/desk_live.py) when present, and the honest empty shell otherwise;
assets/floor.js re-reads the projection over http so the page refreshes under
`make desk-live`. Phase C adds REPLAY scrubber + trail↔mission↔floor links.
Live state is never merged into index.json.
Law: docs/proposals/experience-console-SYNTHESIS.md
     docs/proposals/fleet-desk-v2-SYNTHESIS.md (Phases A–C)
"""
from __future__ import annotations

import argparse
import html
import json
import re
import shutil
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import quote

import experience_data

CSS_SOURCE = Path(__file__).resolve().parents[1] / "templates" / "experience" / "site.css"
JS_SOURCE = Path(__file__).resolve().parents[1] / "templates" / "experience" / "floor.js"


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
    if not JS_SOURCE.is_file():
        raise SystemExit(f"missing floor script template: {JS_SOURCE}")
    target = out / "assets" / "site.css"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(CSS_SOURCE, target)
    shutil.copyfile(JS_SOURCE, out / "assets" / "floor.js")


NAV = [
    ("home", "Home", "index.html"),
    ("missions", "Missions", "missions/index.html"),
    ("work", "Work", "work/index.html"),
    ("skills", "Skills", "skills/index.html"),
    ("learn", "Learn", "learnings/index.html"),
    ("roles", "Roles", "roles/index.html"),
    ("conductor", "Conductor", "conductor/index.html"),
    ("floor", "Floor", "live/index.html"),
    ("about", "About", "about/index.html"),
]

# Pipeline language (Fleet Desk v2 SYNTHESIS §1): every surface talks in
# Queued · In flight · Blocked · Settled. The Almanac only sees settled
# trails, so Queued / In flight are honest dashes — never invented counts.
BLOCKED_STATUSES = ("failed", "fail", "unavailable", "error", "no-delivery", "out-of-credit")

ISSUE_URL_RE = re.compile(r"github\.com/([^/\s]+)/([^/\s]+)/issues/(\d+)")


def _mission_anchor(t: Dict[str, Any]) -> Optional[Dict[str, str]]:
    """Primary issue anchor for a trail, or None when it cites no issue.

    A mission is usually a GitHub issue (SYNTHESIS §1 hierarchy). Prefer a
    gh-resolved issue link (carries title/state); fall back to raw refs.
    Bare `#123` refs are repo-ambiguous, so they group per company scope
    instead of merging unrelated issues that share a number.
    """
    for x in t.get("issue_links_resolved") or []:
        if x.get("kind") != "issue":
            continue
        m = ISSUE_URL_RE.search(x.get("url") or "")
        if m:
            slug = f"{m.group(1)}/{m.group(2)}"
            return {
                "key": f"{slug}#{m.group(3)}",
                "ref": f"{slug}#{m.group(3)}",
                "url": x.get("url") or "",
                "title": x.get("title") or "",
                "issue_state": (x.get("state") or "").lower(),
            }
    for ref in t.get("issue_links") or []:
        m = ISSUE_URL_RE.search(str(ref))
        if m:
            slug = f"{m.group(1)}/{m.group(2)}"
            return {
                "key": f"{slug}#{m.group(3)}",
                "ref": f"{slug}#{m.group(3)}",
                "url": str(ref),
                "title": "",
                "issue_state": "",
            }
        m2 = re.fullmatch(r"#(\d+)", str(ref).strip())
        if m2:
            # Bare refs are repo-ambiguous, so they group per company scope
            # instead of merging unrelated issues that share a number.
            # 6+ digit tokens are IDs/colors (e.g. the hex `#050505` in a
            # theme handoff), not issue numbers — never a mission anchor.
            if len(m2.group(1)) > 5:
                continue
            scope = t.get("company_id") or "unlinked"
            return {
                "key": f"{scope}#{m2.group(1)}",
                "ref": f"#{m2.group(1)}",
                "url": "",
                "title": "",
                "issue_state": "",
            }
    return None


def _slugify(key: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", key.lower()).strip("-") or "mission"


def derive_missions(
    trails: List[Dict[str, Any]], companies: List[Dict[str, Any]]
) -> Tuple[List[Dict[str, Any]], Dict[str, str]]:
    """Group trails into missions by primary issue anchor.

    Pure derivation over the schema v2 contract (issue_links,
    issue_links_resolved, company_id, wave, status) — documented in
    docs/experience-data.md § Derived views. Returns (missions newest-first,
    task_id → mission slug).
    """
    groups: Dict[str, Dict[str, Any]] = {}
    for t in trails:
        a = _mission_anchor(t)
        if not a:
            continue
        g = groups.setdefault(a["key"], {**a, "trails": []})
        # Resolved metadata may arrive on a later trail of the same mission.
        for k in ("url", "title", "issue_state"):
            if not g[k] and a[k]:
                g[k] = a[k]
        g["trails"].append(t)

    gh_by_company = {c["id"]: c.get("github_repo") or "" for c in companies}
    missions: List[Dict[str, Any]] = []
    used_slugs: Dict[str, int] = {}
    for key, g in groups.items():
        ts = g["trails"]  # trails arrive newest-first
        company_id = next((t["company_id"] for t in ts if t["company_id"]), None)
        repo = key.rsplit("#", 1)[0] if "/" in key else gh_by_company.get(company_id or "", "")
        n = len(ts)
        n_done = sum(1 for t in ts if t["status"] == "done")
        n_blocked = sum(1 for t in ts if t["status"] in BLOCKED_STATUSES)
        n_open = n - n_done - n_blocked
        if n_done == n:
            state = "settled"
        elif n_blocked and not n_done:
            state = "blocked"
        elif n_done:
            state = "mixed"
        else:
            state = "open"
        waves = sorted({t["wave"] for t in ts if t["wave"] is not None})
        slug = _slugify(key)
        if slug in used_slugs:  # keep page URLs unique on key collision
            used_slugs[slug] += 1
            slug = f"{slug}-{used_slugs[slug]}"
        else:
            used_slugs[slug] = 1
        missions.append(
            {
                "slug": slug,
                "key": key,
                "ref": g["ref"],
                "url": g["url"],
                "title": g["title"] or ts[0]["plan_hint"] or g["ref"],
                "title_source": "issue" if g["title"] else "trail",
                "issue_state": g["issue_state"],
                "company_id": company_id,
                "repo": repo,
                "trails": ts,
                "waves": waves,
                "n": n,
                "n_done": n_done,
                "n_blocked": n_blocked,
                "n_open": n_open,
                "state": state,
                "simple": n == 1,
            }
        )
    missions.sort(key=lambda m: max((t["ts"] or "") for t in m["trails"]), reverse=True)
    trail_mission = {t["task_id"]: m["slug"] for m in missions for t in m["trails"]}
    return missions, trail_mission


class Renderer:
    def __init__(self, data: Dict[str, Any], out: Path):
        self.d = data
        self.out = out
        self.companies = data["companies"]
        self.trails = data["trails"]
        self.generated = data["generated_at"]
        self.missions, self.trail_mission = derive_missions(self.trails, self.companies)
        self.mission_by_slug = {m["slug"]: m for m in self.missions}
        self.live = self._load_live()

    def _load_live(self) -> Optional[Dict[str, Any]]:
        """Ops Floor projection written by scripts/desk_live.py, when present.

        live.json is a runtime artifact (never in git, never merged into
        index.json). The floor renders a labeled snapshot of it at build time;
        assets/floor.js re-reads it over http so a `make desk-live` session
        updates without a rebuild. Anything unreadable or off-schema degrades
        to the honest empty shell — never to invented live state.
        """
        path = self.out / "data" / "live.json"
        try:
            proj = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if not isinstance(proj, dict) or proj.get("schema") != "live/1":
            return None
        return proj

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
        mode: str = "almanac",
        hier: Optional[str] = None,
        script: Optional[str] = None,
    ) -> str:
        pre = self.pre(depth)
        nav_bits = []
        for key, label, href in NAV:
            current = ' aria-current="page"' if key == section else ""
            nav_bits.append(f'<a href="{pre}{href}"{current}>{esc(label)}</a>')
        nav_html = " ".join(nav_bits)
        almanac_cur = ' aria-current="true"' if mode == "almanac" else ""
        floor_cur = ' aria-current="true"' if mode == "floor" else ""
        mode_html = (
            '<span class="mode" role="group" aria-label="Attention mode">'
            f'<a href="{pre}index.html"{almanac_cur}>Almanac</a>'
            f'<a href="{pre}live/index.html"{floor_cur}>Floor</a></span>'
        )
        if hier is None:
            # Cross-cutting fleet-global pages (roles, skills, …) sit under
            # Global without a company/repo/mission chain.
            view = (section or scope).replace("-", " ").capitalize()
            hier = self.hier(
                [("Global", "Fleet Desk", f"{pre}index.html", False), ("View", view, None, True)],
                hint="fleet-global",
            )
        global_current = ' aria-current="true"' if scope == "global" else ""
        chips = [f'<a class="chip" href="{pre}index.html"{global_current}>Global</a>']
        for c in self.companies:
            current = ' aria-current="true"' if scope == c["id"] else ""
            dim = str(c["status"]).lower() != "active"
            status = esc(c["status"])
            # Placeholder status must not ride on opacity alone (a11y): a dim
            # chip also carries the status as visible text, not just a tooltip.
            # Leading space inside the span keeps a word boundary in the
            # accessible name (screen readers must hear "id status", not the
            # glued "idstatus"); visible spacing still comes from CSS margin.
            mark = f'<span class="chipmark"> {status}</span>' if dim else ""
            chips.append(
                f'<a class="chip{" dim" if dim else ""}" href="{pre}company/{esc(c["id"])}/index.html"'
                f' title="{esc(c["id"])} · {status}"{current}>{esc(c["id"])}{mark}</a>'
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
        <span class="brand"><span class="mark" aria-hidden="true"></span><a href="{pre}index.html">Fleet Desk</a></span>
        <span class="tag">See the fleet move. Keep the record honest.<span class="dot">·</span>read-only<span class="dot">·</span>generated {esc(self.generated)}</span>
        {mode_html}
      </div>
      <nav class="nav" aria-label="Primary">{nav_html}</nav>
      <div class="scope" aria-label="Scope">
        <span class="scope-label">Scope</span>{"".join(chips)}
      </div>
    </header>
    <main id="main">
{hier}
{body}
    </main>
    <footer class="footer">
      <span>Fleet Desk Phase {esc(self.d.get("phase", 0))} · read-only</span>
      <span>rebuild: <span class="mono">make experience</span></span>
      <span>data: <a href="{pre}data/index.json">data/index.json</a> (schema v{esc(self.d["schema_version"])})</span>
      <span>law: <span class="mono">{esc(self.d["law"])}</span></span>
    </footer>
  </div>
{script or ""}
</body>
</html>
"""

    # ── fragments ─────────────────────────────────────────────────────
    @staticmethod
    def status_kind(status: str) -> str:
        if status == "done":
            return "done"
        if status in BLOCKED_STATUSES:
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

    # ── v2 chrome: hierarchy strip, pipeline language, missions ───────
    @staticmethod
    def hier(levels: List[Tuple[str, str, Optional[str], bool]], hint: str = "") -> str:
        """Hierarchy strip: Global › Company › Repo › Mission › Wave/Task.

        Each level is (label, text, href, current). Placeholder levels pass
        text like "…" / "any" and render dimmed — the strip always shows the
        full chain so the reader never loses the mental model.
        """
        bits = []
        for i, (label, text, href, current) in enumerate(levels):
            if i:
                bits.append('<span class="sep" aria-hidden="true">›</span>')
            cls = "lvl on" if current else "lvl"
            if href:
                inner = f"<b>{esc(label)}</b> <a href=\"{esc(href)}\">{esc(text)}</a>"
            elif text in ("…", "any", "—"):
                inner = f"<b>{esc(label)}</b> <em class=\"faint\">{esc(text)}</em>"
            else:
                inner = f"<b>{esc(label)}</b> <em>{esc(text)}</em>"
            bits.append(f'<span class="{cls}">{inner}</span>')
        hint_html = f'<span class="hint">{esc(hint)}</span>' if hint else ""
        return f'<nav class="hier" aria-label="Hierarchy">{"".join(bits)}{hint_html}</nav>'

    @staticmethod
    def _counts(subset: List[Dict[str, Any]]) -> Tuple[int, int, int]:
        n_done = sum(1 for t in subset if t["status"] == "done")
        n_blocked = sum(1 for t in subset if t["status"] in BLOCKED_STATUSES)
        return n_done, n_blocked, len(subset) - n_done - n_blocked

    def pipeline(self, subset: List[Dict[str, Any]], depth: int = 0, scope_note: str = "") -> str:
        """Pipeline strip in the v2 language: Queued · In flight · Blocked · Settled.

        Honesty: the Almanac is a projection of settled handoffs. Queued
        seats live in plans and In flight lives on the Ops Floor — both are
        rendered as "—" with a pointer, never as invented counts.
        """
        n_done, n_blocked, _ = self._counts(subset)
        note = f" · {scope_note}" if scope_note else ""
        return f"""
    <div class="pipeline" role="group" aria-label="Pipeline">
      <div class="pipe todo"><div class="ph">Queued <span class="n">—</span></div><div class="desc">Plan-side seats — not in the Almanac</div></div>
      <div class="pipe wip"><div class="ph">In flight <span class="n">—</span></div><div class="desc">Live motion belongs to the <a href="{self.pre(depth)}live/index.html">Ops Floor</a></div></div>
      <div class="pipe blocked"><div class="ph">Blocked <span class="n">{n_blocked}</span></div><div class="desc">failed / unavailable trails{esc(note)}</div></div>
      <div class="pipe done"><div class="ph">Settled <span class="n">{n_done}</span></div><div class="desc">trails with handoffs{esc(note)}</div></div>
    </div>
"""

    @staticmethod
    def _state_pill(state: str) -> str:
        cls = {"settled": "st-done", "blocked": "st-fail", "mixed": "st-warn"}.get(state, "st-unk")
        return f'<span class="st {cls}">{esc(state)}</span>'

    def mission_href(self, slug: str, depth: int) -> str:
        return f"{self.pre(depth)}mission/{esc(slug)}/index.html"

    def mission_card(self, m: Dict[str, Any], depth: int) -> str:
        path = f"{m['company_id'] or 'unlinked'} / {m['repo'] or 'repo —'} / {m['ref']}"
        if m["simple"]:
            shape = '<span class="pill accent">simple 1:1</span><span class="pill">1 task</span>'
        else:
            n_waves = len(m["waves"])
            shape = (
                f'<span class="pill">{n_waves} wave{"s" if n_waves != 1 else ""}</span>'
                if n_waves
                else '<span class="pill">no wave</span>'
            )
        title_note = "" if m["title_source"] == "issue" else ' <span class="faint">(title from trail)</span>'
        return f"""
      <a class="mission" href="{self.mission_href(m['slug'], depth)}">
        <span class="path">{esc(path)}</span>
        {self._state_pill(m["state"])}
        <span class="t">{esc(m["title"])}{title_note}</span>
        <span class="d">{m["n"]} trail{"s" if m["n"] != 1 else ""} · {m["n_done"]} settled · {m["n_blocked"]} blocked</span>
        <span class="bar">{shape}<meter min="0" max="{m["n"]}" value="{m["n_done"]}">{m["n_done"]}/{m["n"]}</meter><span class="mono">{m["n_done"]}/{m["n"]}</span></span>
      </a>
"""

    def mission_grid(self, missions: List[Dict[str, Any]], depth: int, empty: str) -> str:
        if not missions:
            return f'<p class="empty">{empty}</p>'
        cards = "".join(self.mission_card(m, depth) for m in missions)
        return f'<div class="mission-grid">{cards}</div>'

    @staticmethod
    def _task_table(subset: List[Dict[str, Any]], depth: int) -> str:
        rows = "".join(
            "<tr>"
            f"<td>{Renderer._static_status_pill(t['status'])}</td>"
            f"<td>{esc(t['role'])}</td>"
            f'<td class="mono"><a href="{Renderer.pre(depth)}trail/{esc(t["task_id"])}/index.html">{esc(t["task_id"])}</a></td>'
            f'<td class="mono muted">{esc(t["branch"] or "—")}</td>'
            f'<td class="muted mono">{esc((t["ts"] or "")[:16])}</td>'
            "</tr>"
            for t in subset
        )
        head = (
            "<thead><tr><th>Status</th><th>Seat</th><th>Task</th>"
            "<th>Branch</th><th>When</th></tr></thead>"
        )
        return f'<div class="tablewrap"><table>{head}<tbody>{rows}</tbody></table></div>'

    @staticmethod
    def _static_status_pill(status: str) -> str:
        if status == "done":
            kind = "done"
        elif status in BLOCKED_STATUSES:
            kind = "fail"
        else:
            kind = "unk"
        return f'<span class="st st-{kind}">{esc(status)}</span>'

    def trail_row(self, t: Dict[str, Any], depth: int) -> str:
        pre = self.pre(depth)
        href = f"{pre}trail/{esc(t['task_id'])}/index.html"
        label = t["company_id"] or t["project_label"] or "unlinked"
        wave = f"wave {t['wave']}" if t["wave"] is not None else "wave —"
        mission_slug = self.trail_mission.get(t["task_id"])
        if mission_slug:
            m_ref = self.mission_by_slug[mission_slug]["ref"]
            mission_cell = f'<a href="{self.mission_href(mission_slug, depth)}">{esc(m_ref)}</a>'
        else:
            mission_cell = '<span class="faint">—</span>'
        return (
            "<tr>"
            f"<td>{self.status_pill(t['status'])}</td>"
            f'<td><a href="{pre}role/{esc(t["role"])}/index.html">{esc(t["role"])}</a></td>'
            f'<td class="mono">{esc(label)}</td>'
            f"<td>{esc(wave)}</td>"
            f'<td class="mono"><a href="{href}">{esc(t["task_id"])}</a></td>'
            f"<td>{mission_cell}</td>"
            f'<td class="muted mono">{esc((t["ts"] or "")[:16])}</td>'
            "</tr>"
        )

    def trail_table(self, subset: List[Dict[str, Any]], depth: int, empty: str) -> str:
        head = (
            "<thead><tr><th>Status</th><th>Role</th><th>Scope</th>"
            "<th>Wave</th><th>Task</th><th>Mission</th><th>When</th></tr></thead>"
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
        pre = self.pre(depth)
        if scope == "global":
            hier = self.hier(
                [("Global", "Fleet Desk", f"{pre}index.html", False), ("Mission", "all work", None, True)],
                hint="trail = atom · grouped by wave",
            )
        else:
            hier = self.hier(
                [
                    ("Global", "Fleet Desk", f"{pre}index.html", False),
                    ("Company", scope, f"{pre}company/{esc(scope)}/index.html", False),
                    ("Mission", "all work", None, True),
                ],
                hint="company scope · trails",
            )
        head = f"""
    {hier}
    <div class="pagehead">
      <h1>Work</h1>
      <p class="lede">Scope <strong>{esc(scope)}</strong> · {n} {noun}.
      Trail is the atom; wave clusters atoms; a <a href="{pre}missions/index.html">mission</a> groups trails that share a GitHub issue.
      Status speaks pipeline: <strong>settled</strong> done · <strong>blocked</strong> failed — queued and in-flight live on the <a href="{pre}live/index.html">Ops Floor</a>.</p>
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

    # ── missions (issue-centric portfolio + issue run detail) ─────────
    def missions_index(self) -> None:
        hier = self.hier(
            [
                ("Global", "Fleet Desk", "../index.html", False),
                ("Company", "any", None, False),
                ("Repo", "any", None, False),
                ("Mission", "portfolio", None, True),
            ],
            hint="issue-centric list",
        )
        empty = (
            "No issue-linked missions yet. A mission appears when a handoff cites a GitHub issue "
            "(<code>#123</code> or a full issue URL) — then <code>make experience</code>. "
            "Unlinked trails stay honest under <a href=\"../work/index.html\">Work</a>."
        )
        body = f"""
    {hier}
    <div class="pagehead">
      <h1>Missions</h1>
      <p class="lede">A <strong>mission</strong> is usually a GitHub issue. Every card carries its path
      <span class="mono">company / repo / #issue</span> → waves → tasks. Derived from trail issue links —
      never invented (see <a href="../about/index.html">About</a>).</p>
    </div>
    {self.pipeline(self.trails, 1)}
    {self.mission_grid(self.missions, 1, empty)}
"""
        write(self.out / "missions" / "index.html", self.page("Missions", body, 1, "global", "missions"))

    def mission_pages(self) -> None:
        for m in self.missions:
            pre = "../../"
            company_id = m["company_id"]
            company_lvl: Tuple[str, str, Optional[str], bool] = (
                ("Company", company_id, f"{pre}company/{esc(company_id)}/index.html", False)
                if company_id
                else ("Company", "unlinked", None, False)
            )
            wave_text = f"{len(m['waves'])} wave{'s' if len(m['waves']) != 1 else ''}" if m["waves"] else "no wave"
            hier = self.hier(
                [
                    ("Global", "Fleet Desk", f"{pre}index.html", False),
                    company_lvl,
                    ("Repo", m["repo"] or "—", None, False),
                    ("Mission", m["ref"], None, True),
                    ("Wave / Task", wave_text, None, False),
                ],
                hint="mission detail" + (" · simple 1:1" if m["simple"] else ""),
            )
            if m["url"]:
                gh = f'<a class="gh" href="{esc(m["url"])}">{esc(m["ref"])} ↗</a>'
            else:
                gh = f'<span class="gh">{esc(m["ref"])}</span> <span class="faint">unresolved ref — repo not confirmed</span>'
            issue_state = f'<span class="pill">{esc(m["issue_state"])}</span>' if m["issue_state"] else ""
            shape = "simple 1:1" if m["simple"] else ("complex" if len(m["waves"]) > 1 else "single wave")
            title_note = (
                ""
                if m["title_source"] == "issue"
                else '<p class="faint flush">Title comes from the newest trail’s plan hint — '
                "the issue ref was not resolved by gh enrichment in this build.</p>"
            )
            hero = f"""
    <div class="issue-hero">
      <div class="row1">
        {gh}
        {self._state_pill(m["state"])}
        <span class="pill accent">{esc(shape)}</span>
        {issue_state}
      </div>
      <h1>{esc(m["title"])}</h1>
      <dl class="meta">
        <div><dt>Company</dt><dd>{esc(company_id or "unlinked")}</dd></div>
        <div><dt>Repo</dt><dd class="mono">{esc(m["repo"] or "—")}</dd></div>
        <div><dt>Trails</dt><dd>{m["n"]} · {m["n_done"]} settled · {m["n_blocked"]} blocked</dd></div>
        <div><dt>Waves</dt><dd>{esc(wave_text)}</dd></div>
      </dl>
      {title_note}
    </div>
"""
            if m["simple"]:
                t = m["trails"][0]
                work_html = f"""
    <div class="card">
      <div class="cardhead"><h2>Single task — issue → 1 task → 1 seat</h2>
        <a class="more" href="{pre}live/index.html">Ops Floor →</a></div>
      {self._task_table([t], 2)}
      <p class="muted flush">Smallest mapping: one trail carries the whole mission, so the wave chrome stays hidden.
      Motion (live or REPLAY) lives on the <a href="{pre}live/index.html">Ops Floor</a>.</p>
    </div>
"""
            else:
                by_wave: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
                for t in m["trails"]:
                    by_wave[self.wave_key(t)].append(t)

                def sk(k: str) -> Tuple[int, str]:
                    mo = re.match(r"Wave (\d+)", k)
                    return (0, f"{int(mo.group(1)):05d}") if mo else (1, k)

                cards = []
                for key in sorted(by_wave.keys(), key=sk):
                    ts = by_wave[key]
                    w_done, w_blocked, w_open = self._counts(ts)
                    if w_done == len(ts):
                        w_pill = '<span class="st st-done">settled</span>'
                    elif w_blocked and not w_done:
                        w_pill = '<span class="st st-fail">blocked</span>'
                    elif w_done:
                        w_pill = '<span class="st st-warn">mixed</span>'
                    else:
                        w_pill = '<span class="st st-unk">open</span>'
                    counts = f"{w_done}/{len(ts)} settled"
                    if w_blocked:
                        counts += f" · {w_blocked} blocked"
                    cards.append(
                        f'<details class="wave-card" open><summary><span class="wh">'
                        f"<strong>{esc(key)}</strong> {w_pill} "
                        f'<span class="counts">{esc(counts)}</span></span></summary>'
                        f"{self._task_table(ts, 2)}</details>"
                    )
                work_html = f"""
    <div class="card">
      <div class="cardhead"><h2>Waves under this mission</h2><a class="more" href="{pre}live/index.html">Ops Floor →</a></div>
      <div class="wave-list">{"".join(cards)}</div>
    </div>
"""
            # Around this mission — context from the contract, each line honest
            # about where it came from.
            seen_pairs = sorted(
                {x for t in m["trails"] for x in t["reviewed_by"] if x in {u["task_id"] for u in m["trails"]}}
            )
            pair_line = (
                ", ".join(f'<span class="mono">{esc(x)}</span>' for x in seen_pairs)
                if seen_pairs
                else "no critic review recorded inside this mission"
            )
            issue_line = (
                f'<a href="{esc(m["url"])}">{esc(m["ref"])}</a>'
                + (f' <span class="pill">{esc(m["issue_state"])}</span>' if m["issue_state"] else "")
                if m["url"]
                else f'<span class="mono">{esc(m["ref"])}</span> <span class="faint">unresolved</span>'
            )
            context = f"""
    <div class="card">
      <div class="cardhead"><h2>Around this mission</h2></div>
      <dl class="meta">
        <div><dt>Hierarchy</dt><dd class="mono">{esc(company_id or "unlinked")} → {esc(m["repo"] or "repo —")} → {esc(m["ref"])}</dd></div>
        <div><dt>Issue</dt><dd>{issue_line}</dd></div>
        <div><dt>Critic loop</dt><dd>{pair_line}</dd></div>
        <div><dt>Ops Floor</dt><dd><a href="{pre}live/index.html">Live</a>
          <span class="faint">·</span>
          <a href="{pre}live/index.html#replay">REPLAY</a>
          <span class="muted"> — scrub settled runs when <code>make desk-live</code> is up</span></dd></div>
        <div><dt>Derivation</dt><dd>grouped from trail <span class="mono">issue_links</span> (schema v2) — see <a href="{pre}about/index.html">About</a></dd></div>
      </dl>
    </div>
"""
            body = f"""
    {hier}
    {hero}
    {self.pipeline(m["trails"], 2)}
    {work_html}
    {context}
"""
            write(
                self.out / "mission" / m["slug"] / "index.html",
                self.page(f"Mission {m['ref']}", body, 2, company_id or "global", "missions"),
            )

    # ── Ops Floor (Phase B: live/1 projection when present) ───────────
    # One page skeleton, two honest fill states:
    #   * no data/live.json → the Phase A teach shell (nothing faked)
    #   * live.json present → a labeled snapshot of the projection
    # assets/floor.js re-reads the projection over http and repaints the same
    # regions, so a `make desk-live` session updates without a rebuild.
    @staticmethod
    def _fmt_dur(secs: Any) -> str:
        if not isinstance(secs, (int, float)) or isinstance(secs, bool) or secs < 0:
            return "—"
        s = int(secs)
        if s < 60:
            return f"{s}s"
        m = s // 60
        if m < 60:
            return f"{m}m{s % 60:02d}s"
        return f"{m // 60}h{m % 60:02d}m"

    @staticmethod
    def _fmt_min(secs: Any) -> str:
        """Plain-words duration for sentences: minutes, never ``12m05s``."""
        if not isinstance(secs, (int, float)) or isinstance(secs, bool) or secs < 0:
            return "-"
        s = int(secs)
        if s < 60:
            return "under a minute"
        if s < 3600:
            return f"{round(s / 60)} min"
        h, m = s // 3600, round((s % 3600) / 60)
        return f"{h} h {m} min" if m else f"{h} h"

    @staticmethod
    def _fmt_ago(secs: Any) -> str:
        """Ages floor, never round: at 101 s the top line must still read
        ``1 min ago``, because the LED and the state note flip at "over 2
        min". A rounded "2 min ago" under a live LED is two clocks
        disagreeing."""
        if not isinstance(secs, (int, float)) or isinstance(secs, bool) or secs < 0:
            return "-"
        s = int(secs)
        if s < 60:
            return f"{s} s ago"
        if s < 3600:
            return f"{s // 60} min ago"
        return f"{s // 3600} h ago"

    @staticmethod
    def _secs_between(later_ts: Any, earlier_ts: Any) -> Optional[int]:
        """Seconds between two ISO timestamps, None when either is missing.

        The degraded sentence speaks only in timestamps the projection
        carries, and drops a clause rather than printing a guess.
        """
        if not isinstance(later_ts, str) or not isinstance(earlier_ts, str):
            return None
        try:
            later = datetime.strptime(later_ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            earlier = datetime.strptime(earlier_ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except ValueError:
            return None
        return max(0, int((later - earlier).total_seconds()))

    @staticmethod
    def _live_state(live: Dict[str, Any]) -> Tuple[str, Optional[int]]:
        """live/stale/offline/replay derived at BUILD time.

        Phase B: thresholds desk_live.py publishes (`stale_after_s` /
        `offline_after_s`, default 120/900). Stored staleness.state alone is
        never trusted for a green LIVE LED.

        Phase C: when view=replay (or watermark REPLAY), state is always
        ``replay`` — historical scrub never paints live.
        """
        if live.get("view") == "replay" or (live.get("replay") or {}).get("watermark") == "REPLAY":
            age = (live.get("staleness") or {}).get("seconds")
            if isinstance(age, int):
                return "replay", age
            # Still try to compute age for display.
            ts = live.get("last_event_ts")
            if isinstance(ts, str):
                try:
                    last = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                    age = max(0, int((datetime.now(timezone.utc) - last).total_seconds()))
                    return "replay", age
                except ValueError:
                    pass
            return "replay", None
        staleness = live.get("staleness") or {}
        stale_after = staleness.get("stale_after_s") or 120
        offline_after = staleness.get("offline_after_s") or 900
        ts = live.get("last_event_ts")
        if isinstance(ts, str):
            try:
                last = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            except ValueError:
                last = None
            if last is not None:
                age = max(0, int((datetime.now(timezone.utc) - last).total_seconds()))
                state = "offline" if age >= offline_after else "stale" if age >= stale_after else "live"
                return state, age
        return staleness.get("state") or "none", None

    def _floor_branch_trails(self) -> Dict[str, str]:
        """Branch → trail id map (pure Almanac derivation, no live state)."""
        by_branch: Dict[str, str] = {}
        for t in self.trails:
            b = (t.get("branch") or "").strip()
            if b and b not in by_branch:
                by_branch[b] = t["task_id"]
        return by_branch

    def _floor_almanac_links_json(self) -> str:
        """Branch → trail and plan → mission maps for Floor cross-links.

        Pure Almanac derivation (schema v2) — no live state. Used by floor.js
        so a seat branch can deep-link to its trail when the join exists.
        """
        by_plan: Dict[str, str] = {}
        # Missions do not carry plan filenames; plan_hint on trails is free text.
        # Link by mission slug when only one mission and we know it — otherwise
        # leave by_plan empty (honest). Floor still links Work + Missions.
        payload = {"by_branch": self._floor_branch_trails(), "by_plan": by_plan, "by_mission": {}}
        for m in self.missions:
            payload["by_mission"][m["slug"]] = m["ref"]
        return json.dumps(payload, separators=(",", ":"), sort_keys=True)

    @staticmethod
    def _time_of(ts: Any) -> str:
        """HH:MM:SS of a naive-UTC ISO event timestamp (never raises)."""
        if isinstance(ts, str) and len(ts) >= 19 and ts[10] == "T":
            return ts[11:19] + "Z"
        return str(ts or "—")

    @staticmethod
    def _seat_pill(seat: Dict[str, Any]) -> str:
        """Pipeline pill for a seat — text AND color (mirrored in floor.js)."""
        st = seat.get("status") or "queued"
        if st in ("success", "done"):
            return '<span class="st st-done">settled</span>'
        if st == "running":
            return '<span class="st st-run">in flight</span>'
        if st == "ratecap":
            return '<span class="st st-warn">rate-capped</span>'
        if st in ("failed", "blocked", "unavailable"):
            return '<span class="st st-fail">blocked</span>'
        if st in ("no-delivery", "out-of-credit"):
            return f'<span class="st st-fail">{esc(st)}</span>'
        if st == "queued":
            return '<span class="st st-unk">queued</span>'
        return f'<span class="st st-unk">{esc(st)}</span>'

    def _seat_timer(self, seat: Dict[str, Any]) -> str:
        if seat.get("status") == "running":
            return self._fmt_dur(seat.get("elapsed_s"))
        return self._fmt_dur(seat.get("duration_s"))

    def _seat_lane(self, seat: Dict[str, Any]) -> str:
        chips = ""
        if seat.get("ratecapped"):
            chips += '<span class="vendor warn">rate-cap</span>'
        for f in seat.get("failovers") or []:
            chips += f'<span class="vendor warn">failover {esc(f.get("from"))} → {esc(f.get("to"))}</span>'
        vendor = " · ".join(str(x) for x in (seat.get("provider"), seat.get("model")) if x)
        run = " run" if seat.get("status") == "running" else ""
        return f"""
        <div class="lane{run}">
          <div class="lane-top"><span class="role">{esc(seat.get("agent") or seat.get("task_id"))}</span>{self._seat_pill(seat)}<span class="timer">{self._seat_timer(seat)}</span></div>
          <div class="branch">{esc(seat.get("branch") or "branch not yet reported")}</div>
          <span class="vendor">{esc(vendor or "provider —")}</span>{chips}
        </div>"""

    @staticmethod
    def _ghost_lane() -> str:
        return """
        <div class="lane ghost">
          <div class="lane-top"><span class="role">plan seat</span><span class="st st-unk">queued</span><span class="timer">—</span></div>
          <div class="branch">seat planned by the dispatch, not yet started</div>
          <span class="vendor">provider —</span>
        </div>"""

    def _live_lanes(self, live: Dict[str, Any]) -> str:
        """Wave mode: parallel seat lanes grouped by wave + ghost plan seats."""
        seats = live.get("seats") or []
        ghosts = 0
        planned = live.get("seats_planned")
        if isinstance(planned, int) and planned > len(seats):
            ghosts = planned - len(seats)
        by_wave: Dict[int, List[Dict[str, Any]]] = defaultdict(list)
        for s in seats:
            w = s.get("wave")
            by_wave[w if isinstance(w, int) else 0].append(s)
        out = []
        current = (live.get("wave") or {}).get("current")
        for w in sorted(by_wave):
            cur = " · current" if current == w else ""
            out.append(f'<h3 class="wavehead2">Wave {esc(w)}{cur}</h3>')
            out.append('<div class="lanes">' + "".join(self._seat_lane(s) for s in by_wave[w]) + "</div>")
        if ghosts:
            out.append('<h3 class="wavehead2">Planned, not started</h3>')
            out.append('<div class="lanes">' + "".join(self._ghost_lane() for _ in range(ghosts)) + "</div>")
        if not out:
            out.append('<p class="empty">Dispatch reported no seats yet — the stream is the only source of lanes.</p>')
        return "\n".join(out)

    def _live_spine(self, live: Dict[str, Any]) -> str:
        """Conductor mode: serial spine — settled fills, hot pin on the live seat."""
        seats = live.get("seats") or []
        if not seats:
            return '<p class="empty">Conductor run reported no seats yet.</p>'
        nodes = []
        for i, s in enumerate(seats):
            st = s.get("status") or "queued"
            cls = " hot" if st == "running" else (" done" if st in ("success", "done") else "")
            nodes.append(
                f'<div class="spine-node{cls}"><div class="orb">{i + 1}</div>'
                f'<div class="nm">{esc(s.get("agent") or s.get("task_id"))}</div>'
                f'<div class="meta">{esc(st)} · {self._seat_timer(s)}</div></div>'
            )
        return '<div class="spine">' + '<span class="spine-link"></span>'.join(nodes) + "</div>"

    def _live_events(self, live: Dict[str, Any]) -> str:
        """Event tail — the projection's redaction-safe recent events, newest first."""
        evs = list(reversed((live.get("recent_events") or [])[-12:]))
        if not evs:
            return '<li class="muted">No events in the projection tail.</li>'
        rows = []
        for ev in evs:
            det = ""
            if ev.get("task_id") is not None:
                det += f"task {ev['task_id']}"
            if ev.get("agent"):
                det += f" {ev['agent']}"
            if ev.get("provider"):
                det += f" · {ev['provider']}"
            det_html = f' <span class="edet muted">{esc(det.strip())}</span>' if det.strip() else ""
            rows.append(
                f'<li><span class="ets mono">{esc(self._time_of(ev.get("ts")))}</span> '
                f'<span class="ekind">{esc(ev.get("event"))}</span>{det_html}</li>'
            )
        return "".join(rows)

    @staticmethod
    def _live_activity_line(seat: Dict[str, Any]) -> str:
        """One line of live activity under a seat (mirrored in floor.js).

        Phase word as the in-flight pill, then the tool, the repo-relative path
        and the counts. The projection carries no prompt, argument or command
        line, so there is nothing here to redact. No activity renders nothing.
        """
        act = seat.get("activity") or {}
        if not isinstance(act, dict) or not act:
            return ""
        phases = ("reading", "reviewing", "editing", "testing", "committing")
        phase = act.get("phase") if act.get("phase") in phases else "in flight"
        what = []
        if act.get("tool"):
            what.append(esc(act["tool"]))
        if act.get("path"):
            what.append(f'<span class="mono">{esc(act["path"])}</span>')
        counts = " · ".join([
            f'{act.get("files_edited") or 0} edited',
            f'{act.get("commands_run") or 0} cmd',
            f'{act.get("tests_run") or 0} test',
            f'{act.get("commits_made") or 0} commit',
        ])
        return (f'<div class="nowact"><span class="st st-run">{esc(phase)}</span>'
                f'<span class="faint">{" ".join(what) or "no tool reported yet"}</span>'
                f'<span class="mono faint">{esc(counts)}</span></div>')

    @staticmethod
    def _is_num(v: Any) -> bool:
        return isinstance(v, (int, float)) and not isinstance(v, bool)

    @staticmethod
    def _now_purpose(now: Dict[str, Any]) -> str:
        """The purpose on its own line (mirrored in floor.js).

        A first-time reader must see where the reason ends and the status
        begins: purposes carry colons and commas of their own, so the purpose
        never shares a line with the status clause.
        """
        purpose = str(now.get("purpose") or "").rstrip(". \t")
        return f'<div class="nowpurpose">{esc(purpose)}.</div>' if purpose else ""

    @staticmethod
    def _issue_line(issue: Any) -> str:
        """Issue + milestone line of a seat card (mirrored in floor.js).

        The number always comes from the plan header line; the milestone
        title only from a verified gh lookup. A skipped lookup says so in
        place instead of implying there is no milestone.
        """
        if not isinstance(issue, dict) or not isinstance(issue.get("number"), int):
            return ""
        txt = f'#{issue["number"]}'
        if issue.get("milestone"):
            txt += f' · {esc(issue["milestone"])}'
        if issue.get("lookup") == "skipped":
            txt += ' <span class="faint">(milestone unverified)</span>'
        return f'<div class="nowissue">{txt}</div>'

    @staticmethod
    def _pr_line(pr: Any) -> str:
        """PR number and title of a seat card (mirrored in floor.js).

        Only renders when gh answered with an open (else merged) PR for the
        seat branch; number and title only, never a body.
        """
        if not isinstance(pr, dict) or not isinstance(pr.get("number"), int):
            return ""
        txt = f'PR #{pr["number"]}'
        if pr.get("title"):
            txt += f' · {esc(pr["title"])}'
        return f'<div class="nowpr">{txt}</div>'

    @staticmethod
    def _repo_head_counts(n_seats: int, n_disp: int, state: str) -> str:
        """Repo group header counts (mirrored in floor.js).

        "seats live, dispatches live" per repo (issue 72). Off a live stream
        the word "live" is qualified; a replay drops it entirely because the
        seats shown are history at the scrubber position.
        """
        seat_word = "seat" if n_seats == 1 else "seats"
        disp_word = "dispatch" if n_disp == 1 else "dispatches"
        if state == "replay":
            return f"{n_seats} {seat_word} · {n_disp} {disp_word}"
        qual = " at last event" if state in ("stale", "offline") else ""
        return f"{n_seats} {seat_word} live{qual} · {n_disp} {disp_word} live{qual}"

    def _now_status(self, now: Dict[str, Any], state: str, seat: Dict[str, Any],
                    last_event_ts: Any) -> str:
        """One running seat as one short status clause of nouns (mirrored in floor.js).

        Built only from the seats[].now object the projection folds for this.
        Every field is independently nullable, so a missing fact drops its
        clause instead of printing a guess. Ids never enter the clause. Off a
        live stream the clause degrades with the page: the phase goes past
        tense, and both clocks stop at the last event. The numbers then come
        from the timestamps the projection carries (elapsed = last_event_ts
        minus started_at, heartbeat = last_event_ts minus last_heartbeat_ts),
        never from the projection's own run time: a seat's elapsed at the
        last event cannot depend on when the projection ran. A missing
        timestamp drops its clause.
        """
        degraded = state in ("stale", "offline")
        parts = [f"<strong>{esc(now.get('role') or 'this seat')}</strong>"]
        phase = now.get("phase")
        if phase:
            p = esc(phase)
            if now.get("program"):
                p += f" with {esc(now['program'])}"
            parts.append(f"was {p}" if degraded else p)
        else:
            parts.append("was at work" if degraded else "at work")
        if self._is_num(now.get("wave")):
            w = f"wave {now['wave']}"
            if self._is_num(now.get("wave_total")):
                w += f" of {now['wave_total']}"
            parts.append(w)
        if degraded:
            elapsed_at = self._secs_between(last_event_ts, seat.get("started_at"))
            if elapsed_at is not None:
                parts.append(f"{self._fmt_min(elapsed_at)} in at the last event")
            heartbeat_at = self._secs_between(last_event_ts, seat.get("last_heartbeat_ts"))
            if heartbeat_at is not None:
                ago = self._fmt_ago(heartbeat_at)
                parts.append(f"last heartbeat {ago[:-4] if ago.endswith(' ago') else ago} "
                             "before the last event")
        else:
            if self._is_num(now.get("elapsed_s")):
                parts.append(
                    f'running <span data-elapsed-from="{esc(seat.get("started_at") or "")}" '
                    f'data-elapsed-min="1">{self._fmt_min(now["elapsed_s"])}</span>'
                )
            # The heartbeat age derives from its timestamp at build time and
            # ticks on the same clock the strip's "last event" recomputes
            # from: a frozen projection can never leave a fresh heartbeat
            # under a green LED. The stored heartbeat_age_s is the fallback
            # only when no timestamp arrives.
            hb_ts = seat.get("last_heartbeat_ts")
            now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            hb_age = self._secs_between(now_iso, hb_ts) if hb_ts else None
            if hb_age is not None:
                parts.append(
                    f'heartbeat <span data-elapsed-from="{esc(hb_ts)}" '
                    f'data-elapsed-ago="1">{self._fmt_ago(hb_age)}</span>'
                )
            elif self._is_num(now.get("heartbeat_age_s")):
                parts.append(f"heartbeat {self._fmt_ago(now['heartbeat_age_s'])}")
        return ", ".join(parts) + "."

    @staticmethod
    def _outcome_word(t: Dict[str, Any]) -> str:
        """Outcome word for a finished run (mirrored in floor.js).

        Reads today[].outcome (landed, failed, aborted), which the projection
        derives from the seat exits; status alone cannot tell a failed run
        from an operator stop. Older projections without outcome fall back
        to the status map.
        """
        return t.get("outcome") or {
            "settled": "landed", "failed": "failed", "aborted": "aborted",
        }.get(t.get("status") or "", t.get("status") or "unknown")

    def _floor_strip_html(self, live: Dict[str, Any], state: str, age: Optional[int]) -> str:
        """The v3 status strip (proposal section 4.1, mirrored in floor.js).

        First thing under the title: running, up next, landed, failed, needs
        you, last event. Every figure is a link to its section. Under stale
        or offline the state sentence comes first, in words, before any
        number. A replay carries no summary, so no figure paints: the
        watermark above the strip says what the page is. The age is the
        build-time value of the same clock floor.js recomputes from
        last_event_ts on every poll, so the snapshot and the live page can
        never disagree.
        """
        led_cls = {"live": "led live", "stale": "led stale", "replay": "led replay"}.get(state, "led off")
        staleness = live.get("staleness") or {}
        stale = staleness.get("stale_after_s") or 120
        offline = staleness.get("offline_after_s") or 900
        note = ""
        if state == "stale":
            note = (f"Stale: no new event for over {self._fmt_min(stale)}, so the page "
                    "shows the last known state and the clocks stay frozen.")
        elif state == "offline":
            note = (f"Offline: no new event for over {self._fmt_min(offline)}, so "
                    "everything below is history, not the present.")
        note_html = (f'<span class="state-note" id="floor-state-note">{esc(note)}</span>' if note
                     else '<span class="state-note" id="floor-state-note" hidden></span>')

        degraded = state in ("stale", "offline")
        s = live.get("summary")
        has_summary = isinstance(s, dict) and state != "replay"
        today = live.get("today") or []
        landed = sum(1 for t in today if self._outcome_word(t) == "landed")
        failed = sum(1 for t in today if self._outcome_word(t) == "failed")
        aborted = sum(1 for t in today if self._outcome_word(t) == "aborted")
        skipped_checks = sum(
            1 for c in ((live.get("needs_you_meta") or {}).get("checks") or [])
            if c.get("status") == "skipped")

        def fig(fid: str, href: str, text: str, cls: str = "sfig", on: bool = True) -> str:
            hid = "" if on else " hidden"
            return f'<a class="{cls}" id="{fid}" href="{href}"{hid}>{esc(text)}</a>'

        figs = []
        if has_summary and self._is_num(s.get("running")):
            figs.append(fig("strip-running", "#floor-now-card",
                            f"{s['running']} running" + (" at last event" if degraded else "")))
        else:
            figs.append(fig("strip-running", "#floor-now-card", "", on=False))
        if has_summary and self._is_num(s.get("queued")):
            figs.append(fig("strip-queued", "#floor-queue-card", f"{s['queued']} up next"))
        else:
            figs.append(fig("strip-queued", "#floor-queue-card", "", on=False))
        if has_summary:
            figs.append(fig("strip-landed", "#floor-landed-card", f"{landed} landed"))
            # The figure must equal what it links to: the FAILED list holds
            # failed and aborted rows alike, so both counts ride the figure.
            failed_txt = (f"{failed} failed · {aborted} aborted" if aborted
                          else f"{failed} failed")
            figs.append(fig("strip-failed", "#floor-failed-card", failed_txt,
                            "sfig bad" if failed > 0 else "sfig"))
            needs = s.get("needs_you")
            if not self._is_num(needs):
                needs = len(live.get("needs_you") or [])
            # A zero next to skipped checks is not a verified zero: the
            # figure itself says some checks did not run.
            needs_txt = f"needs you: {needs}"
            if skipped_checks:
                needs_txt += (f" ({skipped_checks} "
                              f"{'check' if skipped_checks == 1 else 'checks'} skipped)")
            figs.append(fig("strip-needs", "#floor-needs-card", needs_txt,
                            "sfig hot" if needs > 0 else "sfig"))
        else:
            figs.append(fig("strip-landed", "#floor-landed-card", "", on=False))
            figs.append(fig("strip-failed", "#floor-failed-card", "", on=False))
            figs.append(fig("strip-needs", "#floor-needs-card", "", on=False))
        if state != "replay" and isinstance(age, int):
            figs.append(fig("strip-event", "#floor-legacy", f"last event {self._fmt_ago(age)}", "sfig dim"))
        else:
            figs.append(fig("strip-event", "#floor-legacy", "", "sfig dim", on=False))

        return f"""
    <div class="strip" id="floor-strip">
      {note_html}
      <span class="{led_cls}" id="floor-led" aria-hidden="true"></span>
      {' '.join(figs)}
      {self._strip_day_toggle()}
    </div>
"""

    def _strip_day_toggle(self) -> str:
        """Today / yesterday on the strip (Floor v3-C, mirrored in floor.js).

        Hidden until the page holds a projection that carries yesterday_meta
        and is not a replay; floor.js then shows it and switches the landed
        and failed figures and lists between the two days. Running, up next
        and needs you stay present tense: the toggle only chooses which
        day's landings are read. Deeper history is the Almanac's.
        """
        return (
            '<span class="daytog" id="strip-day" role="group" aria-label="Which day" hidden>'
            '<button type="button" class="daybtn on" id="strip-day-today" aria-pressed="true">today</button>'
            '<button type="button" class="daybtn" id="strip-day-yesterday" aria-pressed="false">yesterday</button>'
            '</span>')

    def _live_needs_card(self, live: Dict[str, Any]) -> str:
        """NEEDS YOU (proposal section 4.2, mirrored in floor.js).

        One row per item, newest first (the projection orders), each with
        exactly one reachable action: the source url when there is one, else
        the place on this page that answers it (a failed run's action opens
        the replay of its own stream, a PRD sign-off or missing variable
        jumps to the queue row it blocks, a quiet seat jumps to NOW). An
        unverified item says so. Checks that could not run are named in the
        note, and when the list is empty because they did not run, the empty
        row itself carries the qualification instead of reading as a
        verified all-clear. The honesty rule is the projection's: needs_you
        never invents an item.
        """
        check_words = {
            "critic_block": "critic verdicts",
            "ready_to_merge": "merge-ready PRs",
            "quiet_seat": "quiet seats",
            "failed_dispatch": "failed runs",
            "prd_proposed": "PRD sign-offs",
            "missing_variable": "repository variables",
            "merged_branch": "merged branches",
        }
        items = live.get("needs_you") or []
        meta = live.get("needs_you_meta") or {}
        queue = live.get("queue") or []
        skipped = [c for c in (meta.get("checks") or []) if c.get("status") == "skipped"]

        def skipped_names() -> str:
            return ", ".join(check_words.get(c.get("check") or "", c.get("check") or "?")
                             for c in skipped)

        if skipped:
            reason = skipped[0].get("reason")
            note = f"not checked: {esc(skipped_names())}" + (f" ({esc(reason)})" if reason else "")
            note_html = f'<span class="more faint" id="floor-needs-note">{note}</span>'
        else:
            note_html = '<span class="more faint" id="floor-needs-note" hidden></span>'

        def act_href(it: Dict[str, Any]) -> str:
            src = it.get("source") or {}
            if src.get("url"):
                return src["url"]
            if it.get("type") == "failed_dispatch":
                return (f"?replay=1&dispatch_id={quote(str(src['dispatch_id']), safe='')}"
                        if src.get("dispatch_id") else "#floor-failed-card")
            if it.get("type") == "quiet_seat":
                return "#floor-now-card"
            if it.get("type") in ("prd_proposed", "missing_variable"):
                for q in queue:
                    bsrc = (q.get("blocked_by") or {}).get("source") or {}
                    match = (it.get("plan") and q.get("plan_basename") == it.get("plan")) or \
                        (src.get("file") and bsrc.get("file") == src.get("file"))
                    if match and q.get("position") is not None:
                        return f"#floor-queue-row-{q['position']}"
                return "#floor-queue-card"
            return "#floor-needs-card"

        def src_cite(it: Dict[str, Any]) -> str:
            """File sources publish only what the redaction law allows: the
            checkout name, the path relative to it, and the line."""
            src = it.get("source") or {}
            if src.get("kind") == "file" and src.get("file"):
                at = (f"{src['checkout']}:" if src.get("checkout") else "") + str(src["file"])
                if src.get("line"):
                    at += f":{src['line']}"
                return f' <span class="mono faint">{esc(at)}</span>'
            return ""

        if items:
            rows = []
            for it in items:
                action = esc(it.get("action") or "look")
                act = f'<a class="act" href="{esc(act_href(it))}">{action}</a>'
                unv = it.get("verified") is False
                rows.append(
                    f'<li class="nrow{" unv" if unv else ""}"><span class="nbody">'
                    + (f'<span class="rname">{esc(it["repo"])}</span> ' if it.get("repo") else "")
                    + esc(it.get("text") or "item without text")
                    + (' <span class="faint">(not verified)</span>' if unv else "")
                    + src_cite(it)
                    + f"</span>{act}</li>"
                )
            rows_html = "".join(rows)
        elif skipped:
            # A skipped check means "unknown", never "nothing": the empty row
            # itself says which checks did not run and why.
            reasons = []
            for c in skipped:
                r = c.get("reason")
                if r and r not in reasons:
                    reasons.append(r)
            rows_html = ('<li class="muted">Nothing found in the checks that ran; '
                         f"{esc(skipped_names())} not checked"
                         + (f" ({esc('; '.join(reasons))})" if reasons else "")
                         + ".</li>")
        else:
            rows_html = '<li class="muted">Nothing needs you.</li>'

        # Superseded failures (issue 86): dropped from the list because a
        # later round replaced them, never hidden. The fold names what
        # replaced each and keeps its action reachable.
        superseded = meta.get("superseded") or []

        def by_label(it: Dict[str, Any]) -> str:
            by = it.get("superseded_by") or {}
            if by.get("kind") == "merge":
                pr = f"PR {by['pr']}" if isinstance(by.get("pr"), int) else "a merged PR"
                return f"the merge of {by['branch']} ({pr})" if by.get("branch") else pr
            if by.get("kind") == "landed":
                if by.get("branch"):
                    return f"the landed run on {by['branch']}"
                return by.get("plan") or "a later run"
            return by.get("plan") or "a later run"

        if superseded:
            sup_rows = []
            for it in superseded:
                action = esc(it.get("action") or "look")
                act = f'<a class="act" href="{esc(act_href(it))}">{action}</a>'
                sup_rows.append(
                    '<li class="nrow sup"><span class="nbody">'
                    + (f'<span class="rname">{esc(it["repo"])}</span> ' if it.get("repo") else "")
                    + esc(it.get("text") or "item without text")
                    + f' <span class="faint">· superseded by {esc(by_label(it))}</span>'
                    + f"</span>{act}</li>"
                )
            sup_html = (
                f'<details class="supfold" id="floor-superseded"><summary>'
                f'{len(superseded)} superseded {"dispatch" if len(superseded) == 1 else "dispatches"} today'
                f'</summary><ol class="nlist" id="floor-superseded-list">{"".join(sup_rows)}</ol>'
                "</details>"
            )
        else:
            sup_html = ""
        return f"""
    <div class="card mt" id="floor-needs-card">
      <div class="cardhead"><h2>Needs you</h2>{note_html}</div>
      <ol class="nlist" id="floor-needs-list">{rows_html}</ol>
      {sup_html}
    </div>
"""

    def _live_initiatives_card(self, live: Dict[str, Any]) -> str:
        """INITIATIVES (proposal section 4.5, mirrored in floor.js).

        One row per open milestone with recent activity: waves landed of
        planned, open issues, last landed PR, the exit sentence. A fallback
        row (lookup skipped) shows only what the streams and the queue alone
        prove, and says so.
        """
        rows_data = live.get("initiatives") or []
        meta = live.get("initiatives_meta") or {}
        days = meta.get("active_days") if isinstance(meta.get("active_days"), int) else 30
        note = (f"open milestones active in the last {days} days" if rows_data else "")
        note_html = (f'<span class="more faint" id="floor-initiatives-note">{esc(note)}</span>'
                     if note else '<span class="more faint" id="floor-initiatives-note" hidden></span>')
        if rows_data:
            rows = []
            for r in rows_data:
                title = (f'<a href="{esc(r["url"])}">{esc(r.get("title") or "milestone")}</a>'
                         if r.get("url") else f'<strong>{esc(r.get("title") or "milestone")}</strong>')
                bits = []
                w = r.get("waves") or {}
                if isinstance(w.get("planned"), int):
                    bits.append(f"wave {w.get('landed') or 0} of {w['planned']}")
                if isinstance(r.get("open_issues"), int):
                    n = r["open_issues"]
                    bits.append(f"{n} open issue" + ("" if n == 1 else "s"))
                ll = r.get("last_landed")
                if isinstance(ll, dict) and isinstance(ll.get("number"), int):
                    bits.append(f"last landed #{ll['number']}"
                                + (f" {ll['title']}" if ll.get("title") else ""))
                if r.get("exit"):
                    bits.append(f"exit: {r['exit']}")
                tail = ""
                if r.get("lookup") == "skipped":
                    tail = ('<span class="ifall">streams and queue alone'
                            + (f" · milestone not verified ({esc(r['reason'])})" if r.get("reason")
                               else " · milestone not verified")
                            + "</span>")
                elif r.get("exit_lookup") == "skipped":
                    tail = '<span class="ifall">exit sentence not verified</span>'
                facts = esc(" · ".join(bits)) + (" · " if bits and tail else "") + tail
                rows.append(
                    '<li class="irow"><span class="ibody">'
                    f'<span class="ititle"><span class="rname">{esc(r.get("repo") or "repo not reported")}</span> '
                    f'{title}</span>'
                    f'<span class="ifacts">{facts}</span>'
                    "</span></li>"
                )
            rows_html = "".join(rows)
        else:
            rows_html = ('<li class="muted">No open milestone with recent activity is known '
                         "to this projection.</li>")
        return f"""
    <div class="card mt" id="floor-initiatives-card">
      <div class="cardhead"><h2>Initiatives</h2>{note_html}</div>
      <ol class="ilist" id="floor-initiatives-list">{rows_html}</ol>
    </div>
"""

    def _now_row(self, s: Dict[str, Any], state: str, last_event_ts: Any) -> str:
        """One live seat card (mirrored in floor.js).

        Order (issue 72): repo; issue number and milestone (unverified mark
        when the lookup was skipped); purpose; the seat task in one line;
        the status clause from #69; the branch dim; the PR number and title
        when one exists. A seat with now=null (older projection, replay)
        keeps the plan-header layout rather than an invented present tense,
        and the repo, issue, task line and PR still ride the card when the
        projection carries them.
        """
        quiet = s.get("quiet") is True
        quiet_badge = ('<span class="wm-badge" title="no sign of life since the quiet threshold">quiet</span>'
                       if quiet else "")
        now = s.get("now")
        if isinstance(now, dict):
            return (
                f'<li class="nowrow{" quiet" if quiet else ""}">'
                f'<div class="nowhead"><span class="rname">{esc(s.get("repo") or "repo not reported")}</span>'
                f'{self._seat_pill(s)}{quiet_badge}</div>'
                + self._issue_line(s.get("issue"))
                + self._now_purpose(now)
                + (f'<div class="nowtask">{esc(s["task_line"])}</div>' if s.get("task_line") else "")
                + f'<div class="nowsent">{self._now_status(now, state, s, last_event_ts)}</div>'
                f'<div class="nowmeta"><span class="mono faint">'
                f'{esc(s.get("branch") or "branch not reported")}</span>'
                f'<span class="faint">attempt {esc(s.get("attempt") or 1)}</span></div>'
                + self._pr_line(s.get("pr"))
                + '</li>'
            )
        timer = (f'<span class="timer mono" data-elapsed-from="{esc(s.get("started_at") or "")}">'
                 f'{self._fmt_dur(s.get("elapsed_s"))}</span>')
        wave = (f'wave {s["wave"]}' + (f' of {s["wave_total"]}' if s.get("wave_total") else "")
                if isinstance(s.get("wave"), int) else "wave not reported")
        if s.get("last_heartbeat_ts"):
            beat = f'last heartbeat {self._time_of(s.get("last_heartbeat_ts"))}'
            if isinstance(s.get("heartbeat_age_s"), int):
                beat += f' ({self._fmt_dur(s.get("heartbeat_age_s"))} ago)'
        else:
            beat = "no heartbeat yet"
        task = s.get("task_line") or s.get("task")
        return (
            f'<li class="nowrow{" quiet" if quiet else ""}">'
            f'<div class="nowhead"><span class="rname">{esc(s.get("repo") or "repo not reported")}</span>'
            f'<span class="role">{esc(s.get("agent") or s.get("task_id"))}</span>'
            f'{self._seat_pill(s)}{quiet_badge}{timer}</div>'
            + self._issue_line(s.get("issue"))
            + f'<div class="nowpurpose">{esc(s.get("plan_purpose") or "purpose not declared in the plan header")}</div>'
            f'<div class="nowtask">{esc(task or "task line not resolvable from the plan on this machine")}</div>'
            + self._live_activity_line(s)
            + f'<div class="nowmeta"><span class="vendor">{esc(wave)}</span>'
            f'<span class="vendor">attempt {esc(s.get("attempt") or 1)}</span>'
            f'<span class="mono faint">{esc(s.get("branch") or "branch not reported")}</span>'
            f'<span class="faint">{esc(beat)}</span></div>'
            + self._pr_line(s.get("pr"))
            + '</li>'
        )

    def _live_now_card(self, live: Dict[str, Any], state: str) -> str:
        """The now view, grouped by repo (issue 72).

        Each repo group has a header with the repo name and its own counts
        (seats live, dispatches live) from repos[]; a replay carries no
        repos[], so the counts then come from the seats shown at the
        scrubber position. "Live" in the note is a liveness claim, so off a
        live stream it is qualified with "at last event", and a replay drops
        the word entirely, the same branch the repo group header follows.
        """
        seats = [s for s in (live.get("seats") or []) if s.get("status") == "running"]
        runs = {s.get("dispatch_id") for s in seats if s.get("dispatch_id")}
        n_runs = len(runs) or 1
        replay = state == "replay"
        degraded = state in ("stale", "offline")
        live_claim = "" if replay else " live" + (" at last event" if degraded else "")
        note = (f"{len(seats)} {'seat' if len(seats) == 1 else 'seats'}{live_claim} across "
                f"{n_runs} {'dispatch' if n_runs == 1 else 'dispatches'}"
                if seats else "no seat is live")
        if seats:
            groups: Dict[str, List[Dict[str, Any]]] = {}
            for s in seats:
                groups.setdefault(s.get("repo") or "unknown", []).append(s)
            repos_meta = {r.get("repo"): r for r in (live.get("repos") or [])
                          if isinstance(r, dict)}

            def group_seats(repo: str) -> int:
                meta = repos_meta.get(repo) or {}
                n = meta.get("seats_live")
                return n if isinstance(n, int) else len(groups[repo])

            order = sorted(groups, key=lambda r: (-group_seats(r), r))
            rows = []
            for repo in order:
                gseats = groups[repo]
                meta = repos_meta.get(repo) or {}
                n_seats = group_seats(repo)
                n_disp = meta.get("dispatches_live")
                if not isinstance(n_disp, int):
                    n_disp = len({s.get("dispatch_id") for s in gseats
                                  if s.get("dispatch_id")}) or 1
                counts = self._repo_head_counts(n_seats, n_disp, state)
                rows.append(f'<li class="repohead"><span class="rname">{esc(repo)}</span>'
                            f'<span class="faint">{esc(counts)}</span></li>')
                rows.extend(self._now_row(s, state, live.get("last_event_ts")) for s in gseats)
            rows_html = "".join(rows)
        else:
            rows_html = ('<li class="muted">No seat is live. The Floor shows motion only '
                         "while a dispatch is running.</li>")
        return f"""
    <div class="card mt" id="floor-now-card">
      <div class="cardhead"><h2>Now</h2><span class="more faint" id="floor-now-note">{note}</span></div>
      <ol class="nowlist" id="floor-now-list">{rows_html}</ol>
    </div>
"""

    def _live_queue_card(self, live: Dict[str, Any]) -> str:
        """Up next: declared intent from logs/fleet-queue.json, labelled as such.

        Honesty: the block says who declared it and when the newest entry was
        added, and every row reads "queued". A queued plan is never drawn as
        motion, so the page cannot imply a plan is running before a dispatch
        opened a stream for it. A blocked plan shows its reason in place
        (Floor v3-A queue[].blocked) instead of pretending it is ready.
        """
        queue = live.get("queue") or []
        meta = live.get("queue_meta") or {}
        source = meta.get("source") or "logs/fleet-queue.json"
        if meta.get("declared"):
            note = (
                f'Declared by the orchestrator in <span class="mono">{esc(source)}</span>, '
                f'newest entry added {esc(meta.get("declared_at") or "at an unknown time")}. '
                "Order is intent: a queued plan is not running."
            )
        else:
            note = ("No queue declared. Arm one with "
                    "<code>./scripts/queue.sh add &lt;plan&gt; &lt;repo&gt; &lt;purpose&gt;</code>.")
        if queue:
            # Repo is the first word of the row; the issue number follows
            # when the plan header names one (issue 72); a blocked reason
            # renders in place on the dim plan line (Floor v3). The row id
            # lets a NEEDS YOU action jump straight to the plan it blocks.
            rows = "".join(
                f'<li class="qrow{" isblocked" if q.get("blocked") else ""}"'
                + (f' id="floor-queue-row-{esc(q["position"])}"' if q.get("position") is not None else "")
                + '>'
                f'<span class="qpos mono">{esc(q.get("position"))}</span>'
                f'<span class="qbody"><span class="qpurpose"><span class="rname">'
                f'{esc(q.get("repo") or "repo not declared")}</span>'
                + (f' <span class="mono">#{q["issue"]["number"]}</span>'
                   if isinstance(q.get("issue"), dict) and isinstance(q["issue"].get("number"), int)
                   else "")
                + f' {esc(q.get("purpose") or "no purpose declared")}</span>'
                f'<span class="qmeta"><span class="mono faint">'
                f'{esc(q.get("plan_basename") or q.get("plan") or "")}</span>'
                + (f'<span class="qblocked">blocked: {esc(q["blocked"])}</span>'
                   if q.get("blocked") else "")
                + '</span></span>'
                '<span class="st st-unk">queued</span></li>'
                for q in queue
            )
        else:
            rows = ('<li class="muted">Nothing armed. The next dispatch is whatever '
                    "the operator types.</li>")
        return f"""
    <div class="card mt" id="floor-queue-card">
      <div class="cardhead"><h2>Up next</h2><span class="more faint">declared, not observed</span></div>
      <p class="muted" id="floor-queue-note">{note}</p>
      <ol class="qlist" id="floor-queue-list">{rows}</ol>
    </div>
"""

    def _today_row(self, t: Dict[str, Any], by_branch: Dict[str, str]) -> str:
        """One finished-run row (mirrored in floor.js todayRow).

        Failed and aborted wear different pills so a scan of the column
        tells them apart. Repo is the first word; the receipt follows
        (proposal section 4: every number a link to its source). A landed
        run's PR number links to the PR and carries its title; every run
        links the replay of its own stream, and its trail when the Almanac
        join exists.
        """
        word = self._outcome_word(t)
        cls = {"landed": "st st-done", "failed": "st st-fail",
               "aborted": "st st-warn"}.get(word, "st st-unk")
        branches = " ".join(
            f'<span class="mono faint">{esc(b)}</span>' for b in (t.get("branches") or [])
        ) or '<span class="faint">no branch reported</span>'
        pr = t.get("pr")
        pr_html = ""
        if isinstance(pr, dict) and isinstance(pr.get("number"), int):
            label = f"PR #{pr['number']}" + (f" · {pr['title']}" if pr.get("title") else "")
            pr_html = (f' <a class="mono" href="{esc(pr["url"])}">{esc(label)}</a>'
                       if pr.get("url") else f' <span class="mono">{esc(label)}</span>')
        receipt = ""
        branch0 = (t.get("branches") or [""])[0]
        trail_id = by_branch.get(branch0) if branch0 else None
        if trail_id:
            receipt = f'<a href="../trail/{esc(trail_id)}/index.html">trail</a>'
        if t.get("dispatch_id"):
            did = quote(str(t["dispatch_id"]), safe="")
            receipt += (" " if receipt else "") + \
                f'<a href="?replay=1&amp;dispatch_id={esc(did)}">replay</a>'
        return (
            '<li class="trow">'
            f'<span class="tbody"><span class="tpurpose"><span class="rname">'
            f'{esc(t.get("repo") or "repo not reported")}</span>{pr_html} '
            f'{esc(t.get("purpose") or t.get("plan_basename") or t.get("dispatch_id"))}</span>'
            f'<span class="tmeta">{branches}{" " + receipt if receipt else ""}</span></span>'
            f'<span class="{cls} tout">{esc(word)}</span>'
            f'<span class="timer mono">{esc(self._fmt_min(t.get("duration_s")))}</span></li>'
        )

    def _live_today_cards(self, live: Dict[str, Any], state: str = "none") -> str:
        """FAILED and LANDED today (proposal section 4.6, mirrored in floor.js).

        Two lists, failed first when non-empty. Every dispatch whose
        dispatch_end fell on this local calendar day. Aborted runs sit in
        the failed list with their own word: they did not land. The "still
        live" count is a liveness claim, so off a live stream it wears the
        same qualification as the rest of the Floor.
        """
        today = live.get("today") or []
        failed_rows = [t for t in today if self._outcome_word(t) in ("failed", "aborted")]
        landed_rows = [t for t in today if self._outcome_word(t) not in ("failed", "aborted")]
        meta = live.get("today_meta") or {}
        live_n = len(meta.get("live") or [])
        if not live_n:
            live_note = ""
        elif state == "live":
            live_note = f" · {live_n} still live"
        else:
            live_note = f" · {live_n} still live at last event"
        note = (f'dispatch_end on {esc(meta.get("date") or "today")} · '
                f'{esc(meta.get("streams_read") or 0)} stream(s) read'
                + live_note)
        failed_html = ""
        by_branch = self._floor_branch_trails()
        if failed_rows:
            failed_html = f"""
    <div class="card mt" id="floor-failed-card">
      <div class="cardhead"><h2>Failed today</h2><span class="more faint">from the event stream</span></div>
      <ol class="tlist" id="floor-failed-list">{"".join(self._today_row(t, by_branch) for t in failed_rows)}</ol>
    </div>
"""
        else:
            failed_html = """
    <div class="card mt" id="floor-failed-card" hidden>
      <div class="cardhead"><h2>Failed today</h2><span class="more faint">from the event stream</span></div>
      <ol class="tlist" id="floor-failed-list"></ol>
    </div>
"""
        landed_html = f"""
    <div class="card mt" id="floor-landed-card">
      <div class="cardhead"><h2>Landed today</h2><span class="more faint">from the event stream</span></div>
      <p class="muted" id="floor-today-note">{note}</p>
      <ol class="tlist" id="floor-today-list">{"".join(self._today_row(t, by_branch) for t in landed_rows) if landed_rows else '<li class="muted">Nothing has landed today yet.</li>'}</ol>
    </div>
"""
        return failed_html + landed_html

    def live_page(self) -> None:
        live = self.live
        # Almanac link map for trail↔floor (Phase C). Do NOT html-escape the
        # JSON body (that would break JSON.parse); only neutralize </script>.
        links_json = self._floor_almanac_links_json().replace("</", "<\\/")
        script = (
            f'<script type="application/json" id="floor-almanac-links">{links_json}</script>\n'
            '<script src="../assets/floor.js" data-live-json="../data/live.json" '
            'data-runs-url="/api/runs" data-replay-url="/api/replay" defer></script>'
        )
        if live is None:
            body = self._live_shell_body()
        else:
            body = self._live_floor_body(live)
        write(
            self.out / "live" / "index.html",
            self.page("Ops Floor", body, 1, "global", "floor", mode="floor", script=script),
        )

    @staticmethod
    def _floor_watermark_region() -> str:
        """REPLAY watermark: honesty chrome, always outside the legacy fold."""
        return '\n    <div class="floor-watermark" id="floor-watermark" hidden></div>\n'

    @staticmethod
    def _floor_legacy_regions() -> str:
        """Legacy chrome inside the details fold (issue 72): scrubber, cross-links."""
        return """
    <div class="floor-scrubber" id="floor-scrubber" hidden></div>
    <div class="floor-cross card mt" id="floor-cross">
      <div class="cardhead"><h2>Trail · Mission · Floor</h2><span class="more faint">Phase C links</span></div>
      <p class="muted flush" id="floor-cross-links">
        <a href="../work/index.html">Almanac · Work</a>
        <span class="faint">·</span>
        <a href="../missions/index.html">Missions</a>
        <span class="faint">·</span>
        <span class="muted">Seat branches link to trails when the Almanac join exists.</span>
      </p>
    </div>
"""

    @staticmethod
    def _replay_static_watermark(state: str) -> str:
        """Build-time REPLAY chrome when live.json was projected with view=replay."""
        if state != "replay":
            return ""
        return """
    <div class="floor-watermark" id="floor-watermark-static">
      <span class="wm-badge" aria-label="Replay mode">REPLAY</span>
      <span class="wm-copy">Build-time historical snapshot — not a live dispatch.</span>
    </div>
"""

    def _live_shell_body(self) -> str:
        """Phase A teach shell: no live.json in this build, nothing faked.

        Same v3 section order as the live page, every section an honest
        empty state that teaches the next command. No figure paints: there
        is no projection to count from.
        """
        hier = self.hier(
            [
                ("Global", "Fleet Desk", "../index.html", False),
                ("Company", "—", None, False),
                ("Mission", "—", None, False),
                ("Wave", "no live run", None, True),
            ],
            hint="Ops Floor · static shell",
        )
        lanes = "".join(
            f"""
        <div class="lane ghost">
          <div class="lane-top"><span class="role">seat lane</span><span class="st st-unk">empty</span><span class="timer">—</span></div>
          <div class="branch">branch appears with a dispatch</div>
          <span class="vendor">vendor —</span>
        </div>"""
            for _ in range(3)
        )
        spine_nodes = ["issue", "packet", "producer", "critic", "merge"]
        spine = '<span class="spine-link"></span>'.join(
            f'<div class="spine-node todo"><div class="orb">{i + 1}</div><div class="nm">{esc(n)}</div><div class="meta">—</div></div>'
            for i, n in enumerate(spine_nodes)
        )
        body = f"""
    <div class="pagehead">
      <h1>Ops Floor</h1>
    </div>
    {self._floor_watermark_region()}
    <div class="strip" id="floor-strip">
      <span class="state-note" id="floor-state-note">Offline: no live projection in this build, so nothing below can claim the present.</span>
      <span class="led off" id="floor-led" aria-hidden="true"></span>
      <a class="sfig" id="strip-running" href="#floor-now-card" hidden></a>
      <a class="sfig" id="strip-queued" href="#floor-queue-card" hidden></a>
      <a class="sfig" id="strip-landed" href="#floor-landed-card" hidden></a>
      <a class="sfig" id="strip-failed" href="#floor-failed-card" hidden></a>
      <a class="sfig" id="strip-needs" href="#floor-needs-card" hidden></a>
      <a class="sfig dim" id="strip-event" href="#floor-legacy" hidden></a>
      {self._strip_day_toggle()}
    </div>

    <div class="card mt" id="floor-needs-card">
      <div class="cardhead"><h2>Needs you</h2><span class="more faint" id="floor-needs-note" hidden></span></div>
      <ol class="nlist" id="floor-needs-list"><li class="muted">No live projection, so nothing can be claimed to need you.</li></ol>
    </div>

    <div class="card mt" id="floor-now-card">
      <div class="cardhead"><h2>Now</h2><span class="more faint" id="floor-now-note">no projection in this build</span></div>
      <ol class="nowlist" id="floor-now-list"><li class="muted">No live projection, so no seat can be claimed to be working.</li></ol>
    </div>

    <div class="card mt" id="floor-queue-card">
      <div class="cardhead"><h2>Up next</h2><span class="more faint">declared, not observed</span></div>
      <p class="muted" id="floor-queue-note">No projection in this build. The queue lives in
      <span class="mono">logs/fleet-queue.json</span>; arm one with
      <code>make queue-add PLAN=… REPO=… PURPOSE=…</code> and it appears here on the next
      <code>make desk-live-once</code>.</p>
      <ol class="qlist" id="floor-queue-list"><li class="muted">Nothing armed in this build.</li></ol>
    </div>

    <div class="card mt" id="floor-initiatives-card">
      <div class="cardhead"><h2>Initiatives</h2><span class="more faint" id="floor-initiatives-note" hidden></span></div>
      <ol class="ilist" id="floor-initiatives-list"><li class="muted">No live projection, so no milestone can be claimed to be active.</li></ol>
    </div>

    <div class="card mt" id="floor-failed-card" hidden>
      <div class="cardhead"><h2>Failed today</h2><span class="more faint">from the event stream</span></div>
      <ol class="tlist" id="floor-failed-list"></ol>
    </div>

    <div class="card mt" id="floor-landed-card">
      <div class="cardhead"><h2>Landed today</h2><span class="more faint">from the event stream</span></div>
      <p class="muted" id="floor-today-note">No projection in this build. Landed rows come from the
      <code>dispatch_end</code> events of the day, so nothing is claimed until a stream is read.</p>
      <ol class="tlist" id="floor-today-list"><li class="muted">No live projection, so nothing can be claimed about today.</li></ol>
    </div>

    <details class="floor-legacy" id="floor-legacy">
      <summary>Replay, stream facts, schema, lanes and trail links</summary>
      <p class="lede"><strong>This is the empty shell</strong>: no
      <span class="mono">live.json</span> in this build, so no agents are shown or faked.
      Run a dispatch (<span class="mono">logs/fleet-events/</span>) and
      <code>make desk-live</code> to light it up; this page polls
      <span class="mono">data/live.json</span> and repaints itself when a projection appears.
      Settled runs open the Phase C <strong>REPLAY</strong> scrubber (never a green live LED).
      Law: <span class="mono">docs/proposals/fleet-desk-v2-SYNTHESIS.md</span>.</p>
      {hier}
      {self._floor_legacy_regions()}

      <div class="ambient">
        <span class="msg" id="floor-msg"><strong>offline</strong>, no live run in this build</span>
        <span class="meta" id="floor-meta">fleet-events: none · age —</span>
      </div>

      <div class="waiting">
        <div class="label">Waiting on</div>
        <div id="floor-waiting-items"><p class="muted flush">Nothing waiting: there is no live dispatch to wait on.</p></div>
      </div>

      <div class="pipeline" role="group" aria-label="Pipeline">
        <div class="pipe todo"><div class="ph">Queued <span class="n" id="pipe-queued">&mdash;</span></div><div class="desc" id="pipe-queued-desc">no queue declared in this build</div></div>
        <div class="pipe wip"><div class="ph">Running <span class="n" id="pipe-inflight">—</span></div><div class="desc">no seat live</div></div>
        <div class="pipe blocked"><div class="ph">Blocked <span class="n" id="pipe-blocked">—</span></div><div class="desc">—</div></div>
        <div class="pipe done"><div class="ph">Done <span class="n" id="pipe-settled">—</span></div><div class="desc">settled work lives in the <a href="../work/index.html">Almanac</a></div></div>
      </div>

      <div id="floor-mode-body">
      <div class="card">
        <div class="cardhead"><h2>Wave layout, parallel seat lanes</h2><span class="more faint">structure preview</span></div>
        <p class="muted">Ghost lanes show where plan seats will sit. Rate-cap and failover ride the lane as honest chrome.</p>
        <div class="lanes">{lanes}
        </div>
      </div>

      <div class="card mt">
        <div class="cardhead"><h2>Conductor layout, serial spine</h2><span class="more faint">structure preview</span></div>
        <p class="muted">A Conductor run renders as a spine: settled nodes fill, the hot pin marks the live seat, dashed nodes stay ahead of it.</p>
        <div class="spine">{spine}</div>
      </div>

      <div class="card mt teaser">
        <div class="cardhead"><h2>Go live</h2></div>
        <p>Phase B wires <span class="mono">dispatch.sh</span> events to this page
        (<code>make desk-live</code>, SSE and/or <span class="mono">live.json</span> polling).
        Until then the Almanac (<a href="../index.html">Global</a>, <a href="../missions/index.html">Missions</a>,
        <a href="../work/index.html">Work</a>) is the honest record.</p>
      </div>
      </div>

      <div class="card mt">
        <div class="cardhead"><h2>Event tail</h2><span class="more faint">redaction-safe</span></div>
        <ol class="events" id="floor-events"><li class="muted">No live run, no events to show.</li></ol>
      </div>
    </details>
"""
        return body

    def _live_floor_body(self, live: Dict[str, Any]) -> str:
        """Snapshot of the live/1 projection, v3 page order (proposal section 4).

        Only stream facts, labeled as such. Staleness is derived from
        last_event_ts at build time (see _live_state), so a stale snapshot
        never rebuilds as a green LED. Top to bottom: status strip, NEEDS
        YOU, NOW grouped by repo, UP NEXT, INITIATIVES, FAILED and LANDED
        today, then one details control (closed by default) holding replay,
        the scrubber, stream facts, the schema line, the pipeline tiles, the
        lanes or spine, the event tail and the trail links.
        """
        state, age = self._live_state(live)
        repo = live.get("repo")
        plan = live.get("plan")
        wave = live.get("wave") or {}
        wave_txt = "wave"
        if wave.get("current") is not None:
            wave_txt = f"wave {wave['current']}"
            if wave.get("total") is not None:
                wave_txt += f" of {wave['total']}"
        mode = live.get("mode") or "wave"
        hier = self.hier(
            [
                ("Global", "Fleet Desk", "../index.html", False),
                ("Company", "—", None, False),
                ("Repo", repo or "—", None, False),
                ("Mission", plan or "—", None, False),
                ("Wave", f"{wave_txt} · {mode}", None, True),
            ],
            hint=f"Ops Floor · live/1 · {state}",
        )
        status = live.get("status") or "unknown"
        stale_note = "" if state == "live" else f" · stream {esc(state)}"
        age_txt = "—" if age is None else f"{self._fmt_dur(age)} ago"
        waiting = live.get("waiting_on") or []
        if waiting:
            wait_items = "".join(
                f'<p class="witem flush"><span class="pill accent">{esc(w.get("kind") or "wait")}</span> '
                f'{esc(w.get("label") or "waiting")}'
                + (f' <span class="muted">since {esc(self._time_of(w.get("since")))}</span>' if w.get("since") else "")
                + "</p>"
                for w in waiting
            )
        else:
            wait_items = '<p class="muted flush">Nothing waiting: no open gates, no rate-caps.</p>'
        counts = live.get("counts") or {}

        def cn(key: str) -> Any:
            v = counts.get(key)
            return v if isinstance(v, int) else "—"

        # Queued counts PLANS, not seats: the declared queue is the only real
        # queue. With no queue file the cell falls back to the seat count and
        # the caption says so rather than implying an empty pipeline.
        queue_meta_snapshot = live.get("queue_meta") or {}
        if queue_meta_snapshot.get("declared"):
            queued_n: Any = len(live.get("queue") or [])
            queued_desc = ('plans armed in <span class="mono">'
                           f'{esc(queue_meta_snapshot.get("source") or "logs/fleet-queue.json")}</span>')
        else:
            queued_n = cn("queued")
            queued_desc = "no queue declared, showing plan seats not started"

        if mode == "conductor":
            mode_title = "Conductor, serial spine"
            mode_sub = "Settled nodes fill, the hot pin marks the live seat, dashed nodes stay ahead of it."
            mode_body = self._live_spine(live)
        else:
            mode_title = "Wave, parallel seat lanes"
            mode_sub = "Ghost lanes are plan seats not yet started. Rate-cap and failover ride the lane as honest chrome."
            mode_body = self._live_lanes(live)
        msg_extra = ' · <strong class="wm-inline">REPLAY</strong>' if state == "replay" else stale_note
        wm_static = self._replay_static_watermark(state)
        body = f"""
    <div class="pagehead">
      <h1>Ops Floor</h1>
    </div>
    {self._floor_watermark_region()}
    {wm_static}
    {self._floor_strip_html(live, state, age)}
{self._live_needs_card(live)}
{self._live_now_card(live, state)}
{self._live_queue_card(live)}
{self._live_initiatives_card(live)}
{self._live_today_cards(live, state)}

    <details class="floor-legacy" id="floor-legacy">
      <summary>Replay, stream facts, schema, lanes and trail links</summary>
      <p class="lede">Snapshot of <span class="mono">data/live.json</span> (schema <span class="mono">live/1</span>,
      generated {esc(live.get("generated_at") or "—")}). Served via <code>make desk-live</code> this page
      re-reads the projection every few seconds and repaints itself. Only facts from the dispatch event
      stream are shown; live state never enters <span class="mono">index.json</span>.
      Settled runs: enter <strong>REPLAY</strong> to scrub history with an honesty watermark.</p>
      {hier}
      {self._floor_legacy_regions()}

      <div class="ambient">
        <span class="msg" id="floor-msg"><strong>{esc(status)}</strong>, dispatch <span class="mono">{esc(live.get("dispatch_id") or "—")}</span>{msg_extra}</span>
        <span class="meta" id="floor-meta">{esc(live.get("source") or "live.json")} · last event {esc(age_txt)} · snapshot {esc(live.get("generated_at") or "—")}</span>
      </div>

      <div class="waiting">
        <div class="label">Waiting on</div>
        <div id="floor-waiting-items">{wait_items}</div>
      </div>

      <div class="pipeline" role="group" aria-label="Pipeline">
        <div class="pipe todo"><div class="ph">Queued <span class="n" id="pipe-queued">{queued_n}</span></div><div class="desc" id="pipe-queued-desc">{queued_desc}</div></div>
        <div class="pipe wip"><div class="ph">In flight <span class="n" id="pipe-inflight">{cn("in_flight")}</span></div><div class="desc">seats reporting running</div></div>
        <div class="pipe blocked"><div class="ph">Blocked <span class="n" id="pipe-blocked">{cn("blocked")}</span></div><div class="desc">failed · rate-capped · unknown</div></div>
        <div class="pipe done"><div class="ph">Settled <span class="n" id="pipe-settled">{cn("settled")}</span></div><div class="desc">record lands in the <a href="../work/index.html">Almanac</a></div></div>
      </div>

      <div id="floor-mode-body">
      <div class="card">
        <div class="cardhead"><h2>{esc(mode_title)}</h2><span class="more faint">{esc(mode)} mode</span></div>
        <p class="muted">{esc(mode_sub)}</p>
        {mode_body}
      </div>
      </div>

      <div class="card mt">
        <div class="cardhead"><h2>Event tail</h2><span class="more faint">redaction-safe · newest first</span></div>
        <ol class="events" id="floor-events">{self._live_events(live)}</ol>
      </div>
    </details>
"""
        return body


    # ── pages ─────────────────────────────────────────────────────────
    # home() assembles; each section is a small helper so the page stays slim.
    def _home_stats(self) -> str:
        c = self.d["counts"]
        fleet = self.d["fleet"]
        n_trails = c["trails"]
        done_pct = f"{fleet['n_done'] / n_trails:.0%}" if n_trails else "—"
        vendor_mix = " · ".join(f"{v} {n}" for v, n in fleet["vendor_mix"].items()) or "—"
        return f"""
    <div class="stats" role="group" aria-label="Fleet totals">
      <div class="stat"><div class="num">{n_trails}</div><div class="lbl">trails</div></div>
      <div class="stat"><div class="num">{esc(done_pct)} <small>· n={fleet["n_done"]}</small></div><div class="lbl">done</div></div>
      <div class="stat"><div class="num">{fleet["critic_rate"]:.0%} <small>{esc(fleet.get("critic_rate_label", "of trails"))}</small></div><div class="lbl">critic share</div></div>
      <div class="stat"><div class="num">{c["critic_pairs"]} <small>· branches with producer + critic</small></div><div class="lbl">critic pairs</div></div>
      <div class="stat"><div class="num">{c["waves"]}</div><div class="lbl">waves</div></div>
      <div class="stat"><div class="num">{c["companies"]}</div><div class="lbl">companies</div></div>
      <div class="stat"><div class="num fit">{esc(vendor_mix)}</div><div class="lbl">vendor mix</div></div>
    </div>
"""

    def _home_companies_card(self) -> str:
        co_cards = "".join(
            f'<a class="company-card{" dim" if str(co["status"]).lower() != "active" else ""}"'
            f' href="company/{esc(co["id"])}/index.html">'
            f'<strong>{esc(co["id"])}</strong>'
            f'<span class="sub">{esc(co["status"])} · n={co["trail_count"]}</span></a>'
            for co in self.companies
        )
        return f"""
      <div class="card">
        <div class="cardhead"><h2>Companies</h2></div>
        <div class="companies">{co_cards or '<p class="empty">No <code>companies/*.md</code> manifests yet.</p>'}</div>
      </div>
"""

    def _home_watchlist(self) -> str:
        watchlist = self.d["watchlist"]
        return (
            '<ul class="tight">'
            + "".join(
                f'<li>{esc(w["theme"])} <span class="muted">×{w["count"]}</span></li>' for w in watchlist[:6]
            )
            + "</ul>"
            if watchlist
            else '<p class="empty">No recurring do-not-repeat themes (needs ≥2 similar lines across handoffs).</p>'
        )

    def _home_roles_table(self) -> str:
        role_rows = "".join(
            f'<tr><td><a href="role/{esc(r)}/index.html">{esc(r)}</a></td>'
            f'<td class="num">{st["n"]}</td><td class="num">{st["n_done"]}</td>'
            f"<td>{self.pmi_badge(st['pmi']['band'])}</td></tr>"
            for r, st in sorted(self.d["role_stats"].items(), key=lambda kv: -kv[1]["n"])[:6]
        )
        return (
            f'<div class="tablewrap"><table><thead><tr><th>Role</th><th class="num">n</th>'
            f'<th class="num">done</th><th>PMI</th></tr></thead><tbody>{role_rows}</tbody></table></div>'
            if role_rows
            else '<p class="empty">No role usage yet — dispatch a task, then <code>make experience</code>.</p>'
        )

    def _home_skills_card_inner(self) -> str:
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
        return f"""{skill_bits or '<p class="empty">No skill packs found under <code>skills/</code>.</p>'}
        {cand_bit}
        <h2 class="sec">Learnings</h2>
        <p class="muted">documented {n_doc} · promoted {n_pro}</p>
        <p><a href="learnings/index.html">Index →</a></p>"""

    def _home_live_teaser(self) -> str:
        live = self.live
        if live is None:
            return """
      <div class="card teaser">
        <div class="cardhead"><h2>Live · Ops Floor</h2><a class="more" href="live/index.html">Open Floor →</a></div>
        <p class="empty">No live run in this build. The Ops Floor is a static shell until the Phase B
        event stream lands (<code>make desk-live</code>) — agent motion is never faked here.
        Settled work below is the honest record.</p>
      </div>
"""
        # The teaser has no poller (floor.js loads on /live/ only), so the
        # build-time derivation is the whole product here — never the stored
        # staleness.state from projection time.
        state, _age = self._live_state(live)
        state_cls = {"live": "st-run", "stale": "st-warn"}.get(state, "st-unk")
        counts = live.get("counts") or {}

        def cn(key: str) -> Any:
            v = counts.get(key)
            return v if isinstance(v, int) else "—"

        # Queued counts PLANS, not seats: the declared queue is the only real
        # queue. With no queue file the cell falls back to the seat count and
        # the caption says so rather than implying an empty pipeline.
        queue_meta_snapshot = live.get("queue_meta") or {}
        if queue_meta_snapshot.get("declared"):
            queued_n: Any = len(live.get("queue") or [])
            queued_desc = ('plans armed in <span class="mono">'
                           f'{esc(queue_meta_snapshot.get("source") or "logs/fleet-queue.json")}</span>')
        else:
            queued_n = cn("queued")
            queued_desc = "no queue declared, showing plan seats not started"

        return f"""
      <div class="card teaser">
        <div class="cardhead"><h2>Live · Ops Floor</h2><a class="more" href="live/index.html">Open Floor →</a></div>
        <p><span class="st {state_cls}">{esc(state)}</span> dispatch
        <span class="mono">{esc(live.get("dispatch_id") or "—")}</span> —
        in flight {cn("in_flight")} · blocked {cn("blocked")} · settled {cn("settled")}.
        Snapshot of <span class="mono">data/live.json</span> at build time
        ({esc(live.get("generated_at") or "—")}); the Floor refreshes itself under <code>make desk-live</code>.</p>
      </div>
"""

    def home(self) -> None:
        hier = self.hier(
            [
                ("Global", "Fleet Desk", None, True),
                ("Company", "…", None, False),
                ("Repo", "…", None, False),
                ("Mission", "…", None, False),
                ("Wave / Task", "…", None, False),
            ],
            hint="you are here · top",
        )
        missions_empty = (
            'No issue-linked missions yet — a handoff citing a GitHub issue creates one. '
            'See <a href="missions/index.html">Missions</a>.'
        )
        missions_card = f"""
      <div class="card">
        <div class="cardhead"><h2>Missions</h2><a class="more" href="missions/index.html">All missions →</a></div>
        {self.mission_grid(self.missions[:4], 0, missions_empty)}
      </div>
"""
        body = f"""
    {hier}
    <div class="pagehead">
      <h1>Global</h1>
      <p class="lede">Fleet-wide rollup. Drill: <strong>Company</strong> → <strong>Repo</strong> →
      <strong>Mission</strong> (GitHub issue) → <strong>Waves</strong> → <strong>Tasks</strong>.
      Live motion sits on the <a href="live/index.html">Ops Floor</a>.</p>
    </div>
    {self.pipeline(self.trails, 0)}
    {self._home_stats()}
    {self._home_companies_card()}
    {missions_card}
    {self._home_live_teaser()}
    <div class="grid g2 mt">
      <div class="card">
        <div class="cardhead"><h2>Recent work</h2><a class="more" href="work/index.html">View all Work →</a></div>
        {self.trail_table(self.trails[:10], 0, self.empty_teaches("yet"))}
      </div>
      <div class="card">
        <div class="cardhead"><h2>Do-not-repeat watchlist</h2></div>
        {self._home_watchlist()}
      </div>
    </div>
    <div class="grid g2r">
      <div class="card">
        <div class="cardhead"><h2>Roles (top)</h2><a class="more" href="roles/index.html">All roles →</a></div>
        {self._home_roles_table()}
      </div>
      <div class="card">
        <div class="cardhead"><h2>Skills</h2><a class="more" href="skills/index.html">Library →</a></div>
        {self._home_skills_card_inner()}
      </div>
    </div>
"""
        write(self.out / "index.html", self.page("Home", body, 0, "global", "home"))

    def trail_pages(self) -> None:
        for t in self.trails:
            sec = t["handoff_sections"]
            resolved = t["issue_links_resolved"]
            covered = {x["ref"] for x in resolved}
            # Union, never replace: refs gh could not resolve (foreign repos,
            # trails dispatched elsewhere) are still cited and must render.
            unresolved = [u for u in t["issue_links"] if u not in covered]
            if resolved or unresolved:
                parts = [
                    f'<a href="{esc(x["url"])}">{esc(x["ref"])}</a>'
                    f' <span class="muted">({esc(str(x["state"]).lower())} · {esc(x["title"])})</span>'
                    for x in resolved
                ]
                parts += [
                    f'<a href="{esc(u)}">{esc(u)}</a>' if u.startswith("http") else f'<span class="mono">{esc(u)}</span>'
                    for u in unresolved
                ]
                links = " · ".join(parts)
            else:
                links = '<span class="muted">none parsed</span>'
            pr_row = ""
            if t["pr_url"]:
                pr_row = (
                    f'<div><dt>PR</dt><dd><a href="{esc(t["pr_url"])}">#{esc(t["pr_number"])}</a>'
                    f' <span class="pill">{esc(str(t["pr_state"]).lower())}</span></dd></div>'
                )

            def pair_link(task_id: str) -> str:
                return f'<a href="../../trail/{esc(task_id)}/index.html" class="mono">{esc(task_id)}</a>'

            pair_rows = ""
            if t["reviewed_by"]:
                pair_rows += (
                    f'<div><dt>Reviewed by</dt><dd>{" · ".join(pair_link(x) for x in t["reviewed_by"])}'
                    f' <span class="muted">(critic on the same branch)</span></dd></div>'
                )
            if t["reviews"]:
                pair_rows += (
                    f'<div><dt>Reviews</dt><dd>{" · ".join(pair_link(x) for x in t["reviews"])}'
                    f' <span class="muted">(producer trails this critic reviewed)</span></dd></div>'
                )
            scope_label = t["company_id"] or t["project_label"] or "unlinked"
            if t["company_id"]:
                work_href = f"../../company/{esc(t['company_id'])}/work/index.html"
            else:
                work_href = "../../work/index.html"
            wave_label = f"wave {t['wave']}" if t["wave"] is not None else "no wave"
            crumb = self.crumb([("← Work", work_href), (scope_label, None), (wave_label, None)])
            mission_slug = self.trail_mission.get(t["task_id"])
            if mission_slug:
                m = self.mission_by_slug[mission_slug]
                mission_row = (
                    f'<div><dt>Mission</dt><dd><a href="{self.mission_href(mission_slug, 2)}">{esc(m["ref"])}</a>'
                    f' <span class="muted">· {esc(m["title"])}</span></dd></div>'
                )
                mission_lvl: Tuple[str, str, Optional[str], bool] = (
                    "Mission",
                    m["ref"],
                    self.mission_href(mission_slug, 2),
                    False,
                )
            else:
                mission_row = ""
                mission_lvl = ("Mission", "—", None, False)
            company_lvl: Tuple[str, str, Optional[str], bool] = (
                ("Company", t["company_id"], f"../../company/{esc(t['company_id'])}/index.html", False)
                if t["company_id"]
                else ("Company", "unlinked", None, False)
            )
            hier = self.hier(
                [
                    ("Global", "Fleet Desk", "../../index.html", False),
                    company_lvl,
                    mission_lvl,
                    ("Wave / Task", wave_label, None, True),
                ],
                hint="trail detail",
            )
            prov = t["provenance"]
            join_note = f' <span class="muted">({esc(t["join_evidence"])})</span>' if t["join_evidence"] else ""
            conductor = ' <span class="pill accent">conductor</span>' if t["conductor"] else ""

            def section_block(title: str, key: str) -> str:
                text = sec[key]["text"].strip()
                if not text:
                    return ""
                return f'<h2 class="sec">{esc(title)}</h2><div class="body">{esc(text)}</div>'

            body = f"""
    {hier}
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
        {pr_row}
        {mission_row}
        <div><dt>Ops Floor</dt><dd><a href="../../live/index.html">Live Floor</a>
        <span class="faint">·</span>
        <a href="../../live/index.html#replay">REPLAY scrubber</a>
        <span class="muted"> (needs <code>make desk-live</code> + a stream)</span></dd></div>
        <div><dt>Base → head</dt><dd class="mono">{esc(t["base_sha"])}→{esc(t["head_sha"])}</dd></div>
        <div><dt>Exit</dt><dd class="mono">{esc(t["agent_exit"])}</dd></div>
        <div><dt>When</dt><dd class="mono">{esc(t["ts"])}</dd></div>
        <div><dt>Join</dt><dd><span class="mono">{esc(t["join_method"])}</span>{join_note}</dd></div>
        <div><dt>Links</dt><dd>{links}</dd></div>
        {pair_rows}
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
            co_missions = [m for m in self.missions if m["company_id"] == cid]
            empty = (
                f"No handoffs joined to {esc(cid)} yet — join gaps are OK in Phase 0. "
                f"See join rules on <a href=\"../../about/index.html\">About</a>, then "
                f"<code>make experience</code> after the next dispatch."
            )
            gh = c["github_repo"]
            gh_html = (
                f'<a class="mono" href="https://github.com/{esc(gh)}">{esc(gh)}</a>' if gh else '<span class="mono">—</span>'
            )
            # Repos: 1..N per company. The manifest carries a local path and a
            # GitHub slug; each becomes a chip, never invented beyond the fields.
            repo_chips = []
            if gh:
                repo_chips.append(
                    f'<a class="repo-chip" href="https://github.com/{esc(gh)}">'
                    f'<span class="name">{esc(gh)}</span>'
                    f'<span class="meta">primary · GitHub ↗</span></a>'
                )
            if c["repo"]:
                repo_chips.append(
                    f'<span class="repo-chip"><span class="name">{esc(c["repo"])}</span>'
                    f'<span class="meta">local path (manifest)</span></span>'
                )
            repos_row = (
                f'<div class="repo-row">{"".join(repo_chips)}</div>'
                if repo_chips
                else '<p class="empty">No repo recorded in the manifest yet.</p>'
            )
            status_kind = "ok" if str(c["status"]).lower() == "active" else ""
            co_learnings = [L for L in learnings if L.get("company_id") == cid]
            learn_bits = "".join(
                f'<div><a href="../../learning/{esc(L["slug"])}/index.html">{esc(L["title"])}</a> '
                f'<span class="pill">{esc(L["status"])}</span></div>'
                for L in co_learnings
            )
            hier = self.hier(
                [
                    ("Global", "Fleet Desk", "../../index.html", False),
                    ("Company", cid, None, True),
                    ("Repo", "pick below", None, False),
                    ("Mission", "…", None, False),
                ],
                hint="company scope",
            )
            missions_empty = (
                f"No missions for {esc(cid)} yet — a mission appears when a joined handoff "
                "cites a GitHub issue. Unlinked trails stay under Work."
            )
            body = f"""
    {hier}
    {self.crumb([("← Home", "../../index.html"), ("companies", None), (cid, None)])}
    <div class="pagehead">
      <h1>{esc(cid)} <span class="pill {status_kind}">{esc(c["status"])}</span></h1>
      <p class="lede">{esc(c["phase_note"] or "No phase note recorded.")}</p>
    </div>
    <div class="card">
      <div class="cardhead"><h2>Repos</h2></div>
      {repos_row}
      <dl class="meta">
        <div><dt>GitHub</dt><dd>{gh_html}</dd></div>
        <div><dt>Joined trails</dt><dd>n={c["trail_count"]}</dd></div>
        <div><dt>Missions</dt><dd>n={len(co_missions)}</dd></div>
        <div><dt>Manifest</dt><dd class="mono muted">{esc(c["source"])}</dd></div>
      </dl>
      <p class="flush"><a href="work/index.html">Open Work for {esc(cid)} →</a></p>
    </div>
    {self.pipeline(subset, 2, "in this company")}
    <div class="card mt">
      <div class="cardhead"><h2>Missions</h2><a class="more" href="../../missions/index.html">All missions →</a></div>
      {self.mission_grid(co_missions, 2, missions_empty)}
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
      Display caps at {esc(policy["display_cap"])}: {esc(policy["cap_reason"])}.
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
            evidence = inputs.get("proven_loop_evidence") or []
            if evidence and pmi["band"] == "P3":
                loop_html = (
                    '<p class="muted">Proven loop evidence (P3 gate):</p><ul class="tight">'
                    + "".join(f"<li>{esc(e)}</li>" for e in evidence)
                    + "</ul>"
                )
            elif evidence:
                # Evidence exists but the band is below P3, so the P2 outcome
                # gate failed. Say so — presenting the evidence alone would
                # read as the P3 gate being satisfied.
                loop_html = (
                    '<p class="muted">Proven loop evidence (P3 gate): recorded, but the '
                    "P3 gate is not met — the role is still short of the P2 outcome bar "
                    f"(band {esc(pmi['band'])}), so this evidence cannot promote it yet.</p>"
                    '<ul class="tight">'
                    + "".join(f"<li>{esc(e)}</li>" for e in evidence)
                    + "</ul>"
                )
            else:
                loop_html = (
                    '<p class="muted">Proven loop evidence: none recorded — the P3 gate '
                    "(a specialized pack with version ≥ 2 and ≥ 2 recorded revisions, or one "
                    "citing a promoted learning) is not met.</p>"
                )
            body = f"""
    {self.crumb([("← Roles", "../../roles/index.html"), (role, None)])}
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
      {loop_html}
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

        hist = self.d["skill_history"]
        hist_available = hist["available"]
        hist_note = (
            ""
            if hist_available
            else f'<p class="muted">git history unavailable in this projection ({esc(hist["reason"])}) — versions come from pack frontmatter.</p>'
        )

        def ver_cell(s: Dict[str, Any]) -> str:
            rev = f' <span class="muted">· {s["revisions"]} rev</span>' if hist_available else ""
            return f'<td class="mono">v{esc(s["version"])}{rev}</td>'

        rows = "".join(
            f'<tr><td><a href="../skill/{esc(s["id"])}/index.html" class="mono">{esc(s["id"])}</a></td>'
            f'{ver_cell(s)}<td>{pill(s["status"])}</td>'
            f'<td class="muted">{esc(s["summary"])}</td>'
            f'<td class="mono muted">{esc(", ".join(s["roles"]) or "—")}</td></tr>'
            for s in self.d["skills"]
        )
        body = f"""
    <div class="pagehead">
      <h1>Skills</h1>
      <p class="lede">Pack library with promotion status. Promotion stays PR-only — this page never writes skills.</p>
      {hist_note}
    </div>
    <div class="card">
      {('<div class="tablewrap"><table><thead><tr><th>Pack</th><th>Ver</th><th>Status</th><th>Summary</th><th>Injected by</th></tr></thead><tbody>' + rows + "</tbody></table></div>") if rows else '<p class="empty">No skill packs found under <code>skills/</code>.</p>'}
    </div>
"""
        write(self.out / "skills" / "index.html", self.page("Skills", body, 1, "global", "skills"))
        for s in self.d["skills"]:
            if not hist_available:
                hist_rows = (
                    '<div><dt>Revisions</dt><dd class="muted">git history unavailable in this '
                    "projection — version comes from pack frontmatter</dd></div>"
                )
            elif s["revisions"]:
                trunc = (
                    f' <span class="muted">(newest {s["history_depth"]} shown)</span>' if s["history_truncated"] else ""
                )
                hist_rows = (
                    f'<div><dt>Revisions</dt><dd class="mono">{s["revisions"]}{trunc}</dd></div>'
                    f'<div><dt>First → last commit</dt><dd class="mono">{esc(s["first_commit"])} → {esc(s["last_commit"])}</dd></div>'
                )
            else:
                # Available but empty: the file has no commits yet — never
                # conflated with "git could not be read" (docs/experience-data.md).
                hist_rows = '<div><dt>Revisions</dt><dd class="muted">no commits recorded yet</dd></div>'
            hist_block = ""
            if s["git_history"]:
                items = "".join(
                    f'<li><span class="mono">{esc(c["sha"])}</span> <span class="muted mono">{esc(c["date"])}</span> {esc(c["subject"])}</li>'
                    for c in s["git_history"]
                )
                cap_note = (
                    f'<p class="muted flush">Capped at {s["history_depth"]} commits — see <span class="mono">git log -- {esc(s["path"])}</span> for more.</p>'
                    if s["history_truncated"]
                    else ""
                )
                hist_block = f"""
    <div class="card mt">
      <div class="cardhead"><h2>Git history</h2></div>
      <ul class="tight">{items}</ul>
      {cap_note}
    </div>
"""
            body = f"""
    {self.crumb([("← Skills", "../../skills/index.html"), (s["id"], None)])}
    <div class="pagehead">
      <h1 class="mono">{esc(s["id"])} {pill(s["status"])}</h1>
      <p class="lede">{esc(s["summary"])}</p>
    </div>
    <div class="card">
      <dl class="meta">
        <div><dt>Version</dt><dd class="mono">v{esc(s["version"])}</dd></div>
        {hist_rows}
        <div><dt>Scope</dt><dd class="mono">{esc(s["scope"])}</dd></div>
        <div><dt>Injected by</dt><dd class="mono">{esc(", ".join(s["roles"]) or "—")}</dd></div>
        <div><dt>Path</dt><dd class="mono muted">{esc(s["path"])}</dd></div>
      </dl>
      <p class="muted flush">To promote a candidate or change a pack: open a PR — never from this UI.</p>
    </div>
    {hist_block}
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
    {self.crumb([("← Learn", "../../learnings/index.html"), (L["slug"], None)])}
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
        fleet = self.d["fleet"]
        basis = fleet["critic_rate_basis"]
        basis_bits = " · ".join(f"{k} {v}" for k, v in basis.items())
        gh = self.d["gh_enrichment"]
        if gh["status"] == "ok":
            gh_line = (
                f'<span class="mono">ok</span> — {gh["prs_indexed"]} PRs and {gh["issues_indexed"]} issues '
                f'indexed from <span class="mono">{esc(gh["repo"])}</span>; {gh["trails_with_pr"]} trails matched a PR'
            )
        else:
            gh_line = f'<span class="mono">{esc(gh["status"])}</span> — {esc(gh["reason"])}'
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
      <p class="muted">gh enrichment: {gh_line}. Skill git history:
      {"available" if self.d["skill_history"]["available"] else "unavailable"}.</p>
      <p class="muted">Unlinked trails are join-boundary behavior, not a broken page: a trail joins a
      company only through the rules below, so a company with no matching trails shows n=0 by design.
      Teach the join — <span class="mono">config/experience-joins.yaml</span> or a
      <span class="mono">github_repo</span> match — then <code>make experience</code>.</p>
      <h2 class="sec">Data contract</h2>
      <p>Every page is rendered from <a href="../data/index.json" class="mono">data/index.json</a>
      (schema v{esc(self.d["schema_version"])}, documented in <span class="mono">docs/experience-data.md</span>).
      The HTML never reads the repo directly.</p>
      <h2 class="sec">Derived views (v2)</h2>
      <p><strong>Missions</strong> are a pure projection: trails are grouped by their primary
      <span class="mono">issue_links</span> anchor (a gh-resolved issue wins over a raw ref; a bare
      <span class="mono">#123</span> groups per company, since the repo is ambiguous). No schema change,
      no new atoms — a trail without an issue link simply has no mission and stays under Work.</p>
      <p><strong>Pipeline language</strong> — Queued · In flight · Blocked · Settled — maps honestly:
      <span class="mono">done</span> → settled, <span class="mono">failed/unavailable</span> → blocked.
      Queued and In flight are not derivable from settled handoffs, so the Almanac renders them as
      <strong>—</strong> and points at the <a href="../live/index.html">Ops Floor</a> (which reads the
      <span class="mono">live/1</span> projection from the dispatch event stream when one is running;
      live state is never stored in <span class="mono">index.json</span>).</p>
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
      P3 P2 plus proven-loop evidence (display capped at {esc(policy["display_cap"])}: {esc(policy["cap_reason"])}).</p>
      <h2 class="sec">Critic pairing</h2>
      <p>critic_rate {fleet["critic_rate"]:.0%} · method <span class="mono">{esc(fleet["critic_rate_method"])}</span>
      ({esc(fleet.get("critic_rate_label", ""))}) · {c["critic_pairs"]} paired branch{"es" if c["critic_pairs"] != 1 else ""}.</p>
      <p class="muted">Basis: {esc(basis_bits)}.</p>
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
        self.missions_index()
        self.mission_pages()
        self.live_page()
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
