#!/usr/bin/env python3
"""
Fleet Desk — data layer (Phase 1 data contract).

Reads git artifacts (companies, handoffs, skills, learnings, role packs) and
emits ONE stable machine-readable projection:

    site/experience/data/index.json

Schema: docs/experience-data.md   (bump `schema_version` on breaking changes)
Law:    docs/proposals/experience-console-SYNTHESIS.md

Phase 1 adds, without ever making the build depend on them:
  · skill git history (`git log` per SKILL.md) → PMI P3 becomes reachable
  · critic pairing by branch → `critic_pairs`, honest fallback when unpaired
  · optional `gh` PR/issue enrichment → never fails the build
  · optional redacted snapshot under docs/experience/snapshot/

This module never renders HTML. scripts/experience_build.py renders HTML by
reading the JSON this module writes — JSON first, HTML second.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SCHEMA_VERSION = 2
PHASE = 1
LAW = "docs/proposals/experience-console-SYNTHESIS.md"
DEFAULT_PACKS = {"evidence-first", "untrusted-prior", "git-ship"}

# PMI gates — SYNTHESIS §5.2. P0–P2 are frozen; P3 is the Phase 1 addition and
# is evidence-gated, never granted by a pack or by seniority-by-vibes.
PMI_GATES = {
    "p1_min_n": 3,
    "p2_min_done": 5,
    "p2_min_success": 0.70,
    # P3 = "proven loop": P2 outcomes PLUS a specialized pack that either was
    # actually revised (version ≥ 2 and ≥ 2 commits touching its SKILL.md) or
    # carries a learning→skill promotion ([ev:] cite of a learnings file).
    "p3_min_pack_version": 2,
    "p3_min_pack_revisions": 2,
    "display_cap": "P3",
    "cap_reason": (
        "P3 needs proven-loop evidence: a specialized pack with version ≥ 2 and ≥ 2 recorded "
        "revisions, or a specialized pack citing a promoted learning"
    ),
}

JOIN_METHODS = ("config_map", "github_repo", "repo_path", "name_token", "unlinked")

# Skill version history: how far back `git log` is read per SKILL.md.
GIT_LOG_DEPTH = 20
GIT_TIMEOUT = 20

# `gh` enrichment budgets. Every call is optional and failure-tolerant.
GH_AUTH_TIMEOUT = 6
GH_LIST_TIMEOUT = 15
GH_LIST_LIMIT = 200
GH_TITLE_CAP = 120

# Section caps keep the JSON reviewable and keep transcripts out of the site.
SECTION_CAP = 4000
MARKDOWN_CAP = 12000
BODY_CAP = 20000

# Redaction: shaped credentials + `key: value` assignments. Prose words such as
# "token" or "secret" are intentionally NOT redacted on their own.
REDACTIONS: List[Tuple[re.Pattern, str]] = [
    (re.compile(r"(?i)\b(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,})"), "[redacted-token]"),
    (re.compile(r"\bsk-[A-Za-z0-9\-_]{16,}"), "[redacted-token]"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9\-]{10,}"), "[redacted-token]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[redacted-token]"),
    (re.compile(r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"), "[redacted-token]"),
    (re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._\-]{16,}"), "Bearer [redacted-token]"),
    (
        re.compile(
            r"(?i)\b(api[_-]?key|secret[_-]?key|client[_-]?secret|access[_-]?key|auth[_-]?token|"
            r"api[_-]?token|password|passwd|secret|token)\b(\s*[:=]\s*)[\"']?[A-Za-z0-9._\-/+]{12,}[\"']?"
        ),
        r"\1\2[redacted]",
    ),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"), "[redacted-private-key]"),
]


def redact(text: str) -> str:
    if not text:
        return text or ""
    for pattern, repl in REDACTIONS:
        text = pattern.sub(repl, text)
    return text


def friendly_path(p: Path, repo: Path) -> str:
    """Repo-relative when possible, else ~/-relative. Never leak absolute homes."""
    try:
        return str(p.resolve().relative_to(repo.resolve()))
    except (ValueError, OSError):
        pass
    try:
        return "~/" + str(p.resolve().relative_to(Path.home()))
    except (ValueError, OSError):
        return p.name


def cap(text: str, limit: int) -> Tuple[str, bool]:
    text = text or ""
    if len(text) <= limit:
        return text, False
    return text[:limit], True


# ── subprocess helpers (git / gh) ─────────────────────────────────────
# Rule for this whole section: an external tool may only ADD fields. Missing,
# unauthenticated, slow or broken tools degrade to empty data + a warning.

def run_cmd(args: List[str], cwd: Optional[Path], timeout: int) -> Tuple[int, str, str]:
    """Run a command, never raise. Returns (rc, stdout, stderr); rc 127 = missing,
    rc 124 = timed out (the shell conventions, so callers can log a reason)."""
    try:
        p = subprocess.run(
            args,
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            timeout=timeout,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
        )
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", "command not found"
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"
    except OSError as exc:  # pragma: no cover - defensive
        return 1, "", str(exc)


def git_toplevel(repo: Path) -> Optional[Path]:
    """Work-tree root of the projected repo, or None when git is unusable."""
    if shutil.which("git") is None or not repo.is_dir():
        return None
    rc, out, _ = run_cmd(["git", "-C", str(repo), "rev-parse", "--show-toplevel"], None, GIT_TIMEOUT)
    if rc != 0 or not out.strip():
        return None
    return Path(out.strip())


def git_file_history(repo: Path, rel_path: str, depth: int = GIT_LOG_DEPTH) -> List[Dict[str, str]]:
    """`git log` for one file, newest first, capped at `depth`.

    Empty list means "no recorded commits" (new/untracked file) — the caller
    distinguishes that from "git unavailable" via the projection-level flag.
    """
    rc, out, _ = run_cmd(
        [
            "git",
            "-C",
            str(repo),
            "log",
            f"-n{int(depth)}",
            "--follow",
            "--date=short",
            "--format=%h%x1f%ad%x1f%aI%x1f%s",
            "--",
            rel_path,
        ],
        None,
        GIT_TIMEOUT,
    )
    if rc != 0:
        return []
    history: List[Dict[str, str]] = []
    for line in out.splitlines():
        parts = line.split("\x1f")
        if len(parts) < 4:
            continue
        subject, _ = cap(redact(parts[3].strip()), 160)
        history.append({"sha": parts[0][:12], "date": parts[1], "ts": parts[2], "subject": subject})
    return history


# ── parsing helpers ───────────────────────────────────────────────────

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
        v = re.split(r"\s+#", v, maxsplit=1)[0]  # strip trailing ` # comment`
        meta[k.strip()] = v.strip().strip("\"'")
    return meta, parts[2].lstrip("\n")


def parse_role_skills(path: Path) -> Tuple[List[str], Dict[str, List[str]]]:
    """config/role-skills.yaml — `roles:` maps role → packs; `default:` is shared."""
    roles: Dict[str, List[str]] = {}
    section = None
    if not path.is_file():
        return sorted(DEFAULT_PACKS), roles
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
    defaults = roles.get("default") or sorted(DEFAULT_PACKS)
    return defaults, roles


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


SECTION_ALIASES = {
    "built": ["built", "what changed", "what i built"],
    "decisions": ["decisions", "decisions (+why)", "decisions and why"],
    "do_not_repeat": ["do not repeat", "do_not_repeat", "dead ends"],
    "evidence": ["evidence"],
    "open_questions": ["open questions", "open_questions"],
    "next_hint": ["next hint", "next_hint"],
}


def handoff_sections(md: str) -> Dict[str, Dict[str, Any]]:
    raw = extract_sections(md)
    out: Dict[str, Dict[str, Any]] = {}
    for key, aliases in SECTION_ALIASES.items():
        text = ""
        for alias in aliases:
            if raw.get(alias):
                text = raw[alias]
                break
        text = redact(text)
        body, truncated = cap(text, SECTION_CAP)
        out[key] = {
            "text": body,
            "lines": len([ln for ln in body.splitlines() if ln.strip()]),
            "truncated": truncated,
        }
    return out


def parse_issue_links(text: str) -> List[str]:
    links: List[str] = []
    for m in re.finditer(r"https://github\.com/[^\s\)\]]+", text):
        links.append(m.group(0).rstrip(".,)"))
    for m in re.finditer(r"\b([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d+)\b", text):
        links.append(f"https://github.com/{m.group(1)}/issues/{m.group(2)}")
    for m in re.finditer(r"(?<![/\w])#(\d+)\b", text):
        links.append(f"#{m.group(1)}")
    seen, out = set(), []
    for x in links:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out[:8]


# ── entities ──────────────────────────────────────────────────────────

def load_companies(repo: Path) -> List[Dict[str, Any]]:
    companies: List[Dict[str, Any]] = []
    for p in sorted((repo / "companies").glob("*.md")):
        if p.name.startswith("_"):
            continue
        meta, body = parse_frontmatter(p.read_text(encoding="utf-8", errors="replace"))
        cid = meta.get("name") or p.stem
        phase = ""
        for line in body.splitlines():
            s = line.strip()
            if s.startswith("#"):  # a heading marks the section; it is not the note
                continue
            if "active phase" in s.lower() or s.startswith("| Wave plan"):
                phase = s[:120]
                break
        repo_path = meta.get("repo", "")
        if repo_path.upper().startswith("TBD"):
            repo_path = ""
        companies.append(
            {
                "id": cid,
                "name": cid,
                "status": meta.get("status", "unknown"),
                "repo": repo_path,
                "github_repo": "" if meta.get("github_repo", "").upper().startswith("TBD") else meta.get("github_repo", ""),
                "phase_note": phase,
                "source": friendly_path(p, repo),
                "trail_count": 0,
            }
        )
    return companies


def load_joins(repo: Path, company_ids: List[str]) -> Tuple[Dict[str, str], List[str]]:
    """config/experience-joins.yaml → {pattern: company_id}. Unknown company ids
    are dropped: the join map may not invent companies."""
    path = repo / "config" / "experience-joins.yaml"
    out: Dict[str, str] = {}
    warnings: List[str] = []
    if not path.is_file():
        return out, warnings
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or ":" not in line or line.endswith(":"):
            continue
        k, v = line.split(":", 1)
        pat = k.strip().strip("\"'").lstrip("- ")
        cid = v.strip().strip("\"'")
        if not pat or not cid:
            continue
        if cid not in company_ids:
            warnings.append(f"experience-joins.yaml: unknown company '{cid}' for pattern '{pat}' (ignored)")
            continue
        out[pat] = cid
    return out, warnings


def project_label_tokens(repo: Path) -> List[str]:
    """Ad-hoc project labels derived from plan filenames — labels, not companies."""
    tokens = set()
    for p in (repo / "wave-plans").glob("*"):
        if p.suffix not in (".plan", ".md") or p.name.startswith("_"):
            continue
        stem = re.sub(r"[-_]?\d{4}-?\d{2}-?\d{2}$", "", p.stem)
        stem = re.sub(r"[-_]?\d{8}$", "", stem)
        stem = stem.strip("-_")
        if len(stem) >= 4:
            tokens.add(stem.lower())
    if repo.name:
        tokens.add(repo.name.lower())
    tokens.discard("")
    # longest first so `black-aces-seo` beats `black-aces`
    return sorted(tokens, key=len, reverse=True)


def token_in(token: str, blob: str) -> bool:
    if not token:
        return False
    return re.search(r"(?<![a-z0-9])" + re.escape(token.lower()) + r"(?![a-z0-9])", blob) is not None


def join_company(
    trail: Dict[str, Any],
    companies: List[Dict[str, Any]],
    joins: Dict[str, str],
    labels: List[str],
) -> None:
    """Ordered join rules (SYNTHESIS §3.5). Records join_method + evidence.
    Never creates a company that does not exist in companies/."""
    blob = " ".join(
        [
            trail["task_id"],
            trail.get("branch") or "",
            trail.get("plan_hint") or "",
            trail.get("handoff_markdown") or "",
            trail["source"]["jsonl"],
            trail["source"].get("log_name") or "",  # filename only, never contents
        ]
    ).lower()

    # 1. explicit map
    for pat, cid in joins.items():
        if pat.lower() in blob:
            trail.update({"company_id": cid, "join_method": "config_map", "join_evidence": pat})
            return
    # 2. github_repo / repo slug
    for c in companies:
        gh = (c["github_repo"] or "").lower()
        if gh and (gh in blob or token_in(gh.split("/")[-1], blob)):
            trail.update({"company_id": c["id"], "join_method": "github_repo", "join_evidence": c["github_repo"]})
            return
    for c in companies:
        base = Path(c["repo"]).name.lower() if c["repo"] else ""
        if base and token_in(base, blob):
            trail.update({"company_id": c["id"], "join_method": "repo_path", "join_evidence": base})
            return
    # 3. company name token
    for c in companies:
        if token_in(c["id"].lower(), blob):
            trail.update({"company_id": c["id"], "join_method": "name_token", "join_evidence": c["id"]})
            return
    # 4. unlinked — label only, never a fake company
    for token in labels:
        if token_in(token, blob):
            trail["project_label"] = token
            break
    if trail["conductor"] and not trail["project_label"]:
        trail["project_label"] = "conductor"
    trail["company_id"] = None
    trail["join_method"] = "unlinked"
    trail["join_evidence"] = ""


def wave_of(d: Dict[str, Any], rel: str, task_id: str) -> Tuple[Optional[int], str]:
    wave = d.get("wave")
    if isinstance(wave, bool):
        wave = None
    if isinstance(wave, int):
        return wave, "handoff_field"
    if isinstance(wave, str) and wave.strip().isdigit():
        return int(wave.strip()), "handoff_field"
    m = re.match(r"wave-plans/(\d+)/", rel)
    if m:
        return int(m.group(1)), "plan_directory"
    m = re.match(r"^(\d+)-", task_id)
    if m:
        return int(m.group(1)), "task_id_prefix"
    return None, "none"


def load_trails(repo: Path, companies: List[Dict[str, Any]], joins: Dict[str, str]) -> List[Dict[str, Any]]:
    labels = project_label_tokens(repo)
    trails: List[Dict[str, Any]] = []
    for jsonl in sorted((repo / "wave-plans").rglob("*.jsonl")):
        rel = str(jsonl.relative_to(repo)).replace("\\", "/")
        if "/handoffs/" not in rel:
            continue
        lines = [ln for ln in jsonl.read_text(encoding="utf-8", errors="replace").splitlines() if ln.strip()]
        if not lines:
            continue
        try:
            d = json.loads(lines[-1])  # append-only: last record wins
        except json.JSONDecodeError:
            continue
        task_id = str(d.get("task_id") or jsonl.stem)
        md_path = jsonl.with_suffix(".md")
        md = md_path.read_text(encoding="utf-8", errors="replace") if md_path.is_file() else ""
        prov = d.get("provenance") or {}
        orch = d.get("orchestrator_fields") or {}
        wave, wave_source = wave_of(d, rel, task_id)
        plan_hint = md.splitlines()[0].lstrip("# ").strip() if md.startswith("#") else ""
        md_red = redact(md)
        markdown, md_truncated = cap(md_red, MARKDOWN_CAP)
        sections = handoff_sections(md_red)
        agent_exit = orch.get("agent_exit") if isinstance(orch.get("agent_exit"), int) else None
        summary_line = next(
            (ln.strip().lstrip("-* ").strip() for ln in sections["built"]["text"].splitlines() if ln.strip()),
            "",
        )
        trail: Dict[str, Any] = {
            "task_id": task_id,
            "wave": wave,
            "wave_source": wave_source,
            "agent": str(d.get("agent") or "unknown"),
            "role": str(d.get("agent") or "unknown"),
            "status": str(d.get("status") or "unknown"),
            "branch": str(d.get("branch") or ""),
            "provenance": {
                "vendor": str(prov.get("vendor") or ""),
                "model": str(prov.get("model") or prov.get("effective_model") or ""),
                "host": str(prov.get("host") or ""),
            },
            "base_sha": str(d.get("base_sha") or "")[:12],
            "head_sha": str(d.get("head_sha") or "")[:12],
            "ts": str(d.get("ts") or ""),
            "agent_exit": agent_exit,
            "files_touched": list(orch.get("files_touched") or []) if isinstance(orch.get("files_touched"), list) else [],
            "diff_stat": str(orch.get("diff_stat") or "").strip(),
            "plan_hint": plan_hint,
            "conductor": "/conductor/" in rel,
            "company_id": None,
            "join_method": "unlinked",
            "join_evidence": "",
            "project_label": "",
            "issue_links": parse_issue_links(md + " " + plan_hint),
            "handoff_summary": summary_line[:200],
            "handoff_sections": sections,
            "handoff_markdown": markdown,
            "handoff_truncated": md_truncated,
            "source": {
                "jsonl": rel,
                "md": friendly_path(md_path, repo) if md_path.is_file() else "",
                # log FILENAME only — Fleet Desk never ingests agent transcripts
                "log_name": Path(str(orch.get("log") or "")).name,
            },
        }
        join_company(trail, companies, joins, labels)
        trails.append(trail)
    trails.sort(key=lambda t: (t.get("ts") or "", t["task_id"]), reverse=True)
    return trails


def load_skills(repo: Path, history: bool = True) -> List[Dict[str, Any]]:
    """Skill packs + (Phase 1) their git version history.

    `history=False` (git unavailable) still emits the fields, empty — a reader
    can always tell "no commits" from "history not collected" via
    `history_available` on each skill and `skill_history.available` at the top.
    """
    skills: List[Dict[str, Any]] = []
    root = repo / "skills"

    def read(skill_md: Path, status: str) -> Dict[str, Any]:
        meta, body = parse_frontmatter(skill_md.read_text(encoding="utf-8", errors="replace"))
        raw_ver = str(meta.get("version", "1" if status == "active" else "0"))
        version = int(raw_ver) if raw_ver.isdigit() else 0
        body_text, truncated = cap(redact(body), BODY_CAP)
        rel = friendly_path(skill_md, repo)
        git_history = git_file_history(repo, rel) if history else []
        return {
            "id": meta.get("id") or skill_md.parent.name,
            "version": version,
            "scope": meta.get("scope", "global"),
            "summary": meta.get("summary", ""),
            "status": status,
            "path": rel,
            "body": body_text,
            "body_truncated": truncated,
            "roles": [],
            # Phase 1 — version history (SYNTHESIS §7 "git log skill versions")
            "history_available": bool(history),
            "git_history": git_history,
            "revisions": len(git_history),
            "history_depth": GIT_LOG_DEPTH,
            "history_truncated": len(git_history) >= GIT_LOG_DEPTH,
            "first_commit": git_history[-1]["date"] if git_history else "",
            "last_commit": git_history[0]["date"] if git_history else "",
            # filled by link_promotions() once learnings are loaded
            "promotes": [],
        }

    for skill_md in sorted(root.glob("*/SKILL.md")):
        if skill_md.parent.name.startswith("_"):
            continue
        skills.append(read(skill_md, "active"))
    cand = root / "_candidates"
    if cand.is_dir():
        for skill_md in sorted(cand.glob("*/SKILL.md")):
            skills.append(read(skill_md, "candidate"))
    return skills


def load_learnings(repo: Path, skills: List[Dict[str, Any]], companies: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    learnings: List[Dict[str, Any]] = []
    cited = " ".join(s["body"] for s in skills)

    def title_of(text: str, fallback: str) -> str:
        for line in text.splitlines():
            if line.startswith("# "):
                return line[2:].strip()
        return fallback

    for p in sorted((repo / "learnings").glob("*.md")):
        text = p.read_text(encoding="utf-8", errors="replace")
        body, truncated = cap(redact(text), BODY_CAP)
        learnings.append(
            {
                "slug": p.stem,
                "title": title_of(text, p.stem),
                "status": "promoted" if p.name in cited else "documented",
                "path": friendly_path(p, repo),
                "company_id": None,
                "body": body,
                "body_truncated": truncated,
            }
        )
    # product learnings when the company repo is on the operator's disk
    for c in companies:
        if not c["repo"]:
            continue
        candidates = [
            (repo / c["repo"]),
            (repo / "companies" / c["repo"]),
            (repo.parent / Path(c["repo"]).name),
        ]
        prod = next((q for q in candidates if q.exists()), None)
        if prod is None:
            continue
        if prod.resolve() == repo.resolve():
            # the company IS the projected repo (e.g. dev-agents, repo: ".") —
            # its learnings were already loaded by the main loop above
            continue
        for pattern in ("docs/qa/learning-*.md", "learnings/*.md"):
            for p in sorted(prod.glob(pattern)):
                if not p.is_file():
                    continue
                text = p.read_text(encoding="utf-8", errors="replace")
                body, truncated = cap(redact(text), BODY_CAP)
                learnings.append(
                    {
                        "slug": f"{c['id']}-{p.stem}",
                        "title": f"[{c['id']}] {title_of(text, p.stem)}",
                        "status": "promoted" if p.name in cited else "documented",
                        "path": friendly_path(p, repo),
                        "company_id": c["id"],
                        "body": body,
                        "body_truncated": truncated,
                    }
                )
    return learnings


def link_promotions(skills: List[Dict[str, Any]], learnings: List[Dict[str, Any]]) -> None:
    """learning → skill promotion links, both directions.

    Same rule the learning `status` already uses: a skill body citing the
    learning's filename (`[ev: learnings/foo.md]`). Reported, never written —
    promotion stays PR-only (SYNTHESIS §3.6).
    """
    for lrn in learnings:
        lrn["promoted_by"] = []
    for s in skills:
        promotes: List[str] = []
        for lrn in learnings:
            fname = Path(lrn["path"]).name
            if fname and fname in s["body"]:
                promotes.append(lrn["slug"])
                lrn["promoted_by"].append(s["id"])
        s["promotes"] = sorted(set(promotes))
    for lrn in learnings:
        lrn["promoted_by"] = sorted(set(lrn["promoted_by"]))


# ── critic pairing (SYNTHESIS §5.1 — Phase 1: "pair by branch") ───────

def is_critic_role(role: str) -> bool:
    return "critic" in (role or "").lower()


def pair_critics(trails: List[Dict[str, Any]]) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    """Producer ↔ critic pairing on the same branch.

    A pair exists when one branch carries at least one non-critic trail AND at
    least one critic trail. Every trail gets `reviewed_by` / `reviews` (empty
    lists when unpaired) so the absence of review is visible, not implied.

    Fallback (documented, honest): when no branch pairs at all — no critic seat
    ran, or critics ran on their own branches — `critic_rate` falls back to the
    Phase 0 definition (share of trails whose role name contains "critic") and
    says so in `critic_rate_method`.
    """
    for t in trails:
        t["is_critic"] = is_critic_role(t["role"])
        t["reviewed_by"] = []
        t["reviews"] = []

    by_branch: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for t in trails:
        branch = (t.get("branch") or "").strip()
        if branch:
            by_branch[branch].append(t)

    pairs: List[Dict[str, Any]] = []
    for branch, group in sorted(by_branch.items()):
        producers = [t for t in group if not t["is_critic"]]
        critics = [t for t in group if t["is_critic"]]
        if not producers or not critics:
            continue
        for p in producers:
            p["reviewed_by"] = [c["task_id"] for c in critics]
        for c in critics:
            c["reviews"] = [p["task_id"] for p in producers]
        waves = [t["wave"] for t in group if t["wave"] is not None]
        pairs.append(
            {
                "branch": branch,
                "wave": min(waves) if waves else None,
                "company_id": next((t["company_id"] for t in group if t["company_id"]), None),
                "producers": [p["task_id"] for p in producers],
                "critics": [c["task_id"] for c in critics],
                "producer_roles": sorted({p["role"] for p in producers}),
                "critic_roles": sorted({c["role"] for c in critics}),
                "critic_verdicts": sorted({c["status"] for c in critics}),
            }
        )

    n_trails = len(trails)
    producers = [t for t in trails if not t["is_critic"]]
    critic_trails = [t for t in trails if t["is_critic"]]
    paired_producers = [t for t in producers if t["reviewed_by"]]
    paired_critics = [t for t in critic_trails if t["reviews"]]
    basis = {
        "pairs": len(pairs),
        "producer_trails": len(producers),
        "paired_producer_trails": len(paired_producers),
        "critic_trails": len(critic_trails),
        "paired_critic_trails": len(paired_critics),
        "unpaired_critic_trails": len(critic_trails) - len(paired_critics),
        "trails_without_branch": sum(1 for t in trails if not (t.get("branch") or "").strip()),
    }
    if pairs:
        rate = round(len(paired_producers) / len(producers), 4) if producers else 0.0
        summary = {
            "critic_rate": rate,
            "critic_rate_method": "branch_pairing",
            "critic_rate_label": "of producer trails reviewed on the same branch",
            "critic_rate_basis": basis,
        }
    else:
        rate = round(len(critic_trails) / n_trails, 4) if n_trails else 0.0
        summary = {
            "critic_rate": rate,
            "critic_rate_method": "role_name_fallback",
            "critic_rate_label": "of trails are critic seats (no branch pair found)",
            "critic_rate_basis": basis,
        }
    return pairs, summary


# ── gh enrichment (optional, never fatal) ─────────────────────────────

def gh_index(repo: Path, toplevel: Optional[Path], enabled: bool) -> Dict[str, Any]:
    """Index open/merged PRs + issues for the projected repo when `gh` is authed.

    Contract: this function NEVER raises and NEVER fails a build. Any missing
    tool, missing auth, timeout or parse error degrades to an empty index with
    a machine-readable `status` + `reason`. An exit-0 response that is not the
    expected shape (non-slug repo name, non-JSON list) is `bad_payload` — exit
    0 is never reported as `ok` with garbage. Titles only — no issue/PR bodies,
    no comments, no tokens.
    """
    empty = {
        "status": "skipped",
        "reason": "",
        "repo": "",
        "prs_indexed": 0,
        "issues_indexed": 0,
        "fetched_at": "",
        "pr_by_branch": {},
        "issue_by_number": {},
    }
    if not enabled:
        empty["status"] = "disabled"
        empty["reason"] = "disabled (--no-gh or FLEET_DESK_NO_GH=1)"
        return empty
    if toplevel is None or toplevel.resolve() != repo.resolve():
        empty["reason"] = "projected repo is not a git work-tree root (fixture or sub-tree projection)"
        return empty
    if shutil.which("gh") is None:
        empty["status"] = "unavailable"
        empty["reason"] = "gh not on PATH"
        return empty
    rc, _, err = run_cmd(["gh", "auth", "status"], repo, GH_AUTH_TIMEOUT)
    if rc != 0:
        empty["status"] = "unauthenticated"
        empty["reason"] = "gh auth status failed" + (" (timed out)" if rc == 124 else "")
        return empty
    rc, out, _ = run_cmd(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], repo, GH_LIST_TIMEOUT
    )
    slug = out.strip() if rc == 0 else ""
    if not slug:
        empty["status"] = "error"
        empty["reason"] = "gh repo view failed (no default repo resolved)"
        return empty
    if not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", slug):
        # exit 0 is not proof of a sane payload — never report ok with garbage
        empty["status"] = "bad_payload"
        empty["reason"] = f"gh repo view exited 0 but returned a non-slug payload: {slug[:80]!r}"
        return empty

    pr_by_branch: Dict[str, Dict[str, Any]] = {}
    issue_by_number: Dict[str, Dict[str, Any]] = {}
    rank = {"MERGED": 3, "OPEN": 2, "CLOSED": 1}

    rc, out, _ = run_cmd(
        [
            "gh", "pr", "list", "--state", "all", "--limit", str(GH_LIST_LIMIT),
            "--json", "number,url,state,headRefName,title,updatedAt",
        ],
        repo,
        GH_LIST_TIMEOUT,
    )
    if rc != 0:
        empty["status"] = "error"
        empty["reason"] = "gh pr list failed" + (" (timed out)" if rc == 124 else "")
        empty["repo"] = slug
        return empty
    try:
        prs = json.loads(out or "")
        if not isinstance(prs, list):
            raise ValueError("not a JSON array")
    except (json.JSONDecodeError, ValueError):
        empty["status"] = "bad_payload"
        empty["reason"] = "gh pr list exited 0 but did not return a JSON array"
        empty["repo"] = slug
        return empty
    for pr in prs:
        branch = str(pr.get("headRefName") or "")
        if not branch:
            continue
        title, _ = cap(redact(str(pr.get("title") or "")), GH_TITLE_CAP)
        record = {
            "number": pr.get("number"),
            "url": str(pr.get("url") or ""),
            "state": str(pr.get("state") or ""),
            "title": title,
            "updated_at": str(pr.get("updatedAt") or ""),
        }
        prev = pr_by_branch.get(branch)
        if prev is None or (rank.get(record["state"], 0), record["updated_at"]) > (
            rank.get(prev["state"], 0),
            prev["updated_at"],
        ):
            pr_by_branch[branch] = record
        issue_by_number[str(record["number"])] = {**record, "kind": "pr"}

    rc, out, _ = run_cmd(
        ["gh", "issue", "list", "--state", "all", "--limit", str(GH_LIST_LIMIT), "--json", "number,url,state,title"],
        repo,
        GH_LIST_TIMEOUT,
    )
    if rc == 0:
        try:
            issues = json.loads(out or "")
            if not isinstance(issues, list):
                raise ValueError("not a JSON array")
        except (json.JSONDecodeError, ValueError):
            empty["status"] = "bad_payload"
            empty["reason"] = "gh issue list exited 0 but did not return a JSON array"
            empty["repo"] = slug
            return empty
        for issue in issues:
            title, _ = cap(redact(str(issue.get("title") or "")), GH_TITLE_CAP)
            issue_by_number[str(issue.get("number"))] = {
                "number": issue.get("number"),
                "url": str(issue.get("url") or ""),
                "state": str(issue.get("state") or ""),
                "title": title,
                "kind": "issue",
            }

    return {
        "status": "ok",
        "reason": "",
        "repo": slug,
        "prs_indexed": len(pr_by_branch),
        "issues_indexed": len(issue_by_number),
        "fetched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pr_by_branch": pr_by_branch,
        "issue_by_number": issue_by_number,
    }


def apply_gh(trails: List[Dict[str, Any]], index: Dict[str, Any]) -> None:
    """Attach PR + resolved issue fields. Fields always exist (empty when the
    enrichment did not run), so a page never has to guess why they are absent."""
    pr_by_branch = index.get("pr_by_branch") or {}
    issue_by_number = index.get("issue_by_number") or {}
    slug = (index.get("repo") or "").lower()
    for t in trails:
        t["pr_url"] = ""
        t["pr_state"] = ""
        t["pr_number"] = None
        t["issue_links_resolved"] = []
        pr = pr_by_branch.get((t.get("branch") or "").strip())
        if pr:
            t["pr_url"] = pr["url"]
            t["pr_state"] = pr["state"]
            t["pr_number"] = pr["number"]
        if not issue_by_number:
            continue
        resolved = []
        for ref in t.get("issue_links") or []:
            num = ""
            if ref.startswith("#"):
                # A bare `#123` is only this repo's issue when the trail itself
                # belongs to this repo (its branch matched a PR here). Trails
                # dispatched into a product repo keep the raw ref unresolved
                # rather than pointing at an unrelated dev-agents issue.
                num = ref[1:] if pr else ""
            else:
                m = re.match(r"https://github\.com/([^/]+/[^/]+)/(?:issues|pull)/(\d+)", ref)
                if m and m.group(1).lower() == slug:
                    num = m.group(2)
            hit = issue_by_number.get(num) if num else None
            if hit:
                resolved.append({"ref": ref, **hit})
        t["issue_links_resolved"] = resolved[:8]


def watchlist(trails: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    counter: Counter = Counter()
    for t in trails:
        for line in t["handoff_sections"]["do_not_repeat"]["text"].splitlines():
            line = line.strip().lstrip("-* ").strip()
            if len(line) < 12:
                continue
            counter[line[:100]] += 1
    return [{"theme": k, "count": n} for k, n in counter.most_common(12) if n >= 2]


# ── metrics ───────────────────────────────────────────────────────────

def pmi_policy(history_available: bool) -> Dict[str, Any]:
    """Published gates. The cap reason stays honest about what could be checked."""
    policy = dict(PMI_GATES)
    if not history_available:
        policy["cap_reason"] += (
            " — git history unavailable in this projection, so only the promotion path was evaluable"
        )
    policy["history_available"] = history_available
    return policy


def proven_loop_evidence(specialized: List[str], skill_index: Dict[str, Dict[str, Any]]) -> List[str]:
    """P3 evidence (SYNTHESIS §5.2 "Proven loop", Phase 1).

    Two accepted proofs, both read off artifacts already in this projection:

      1. version history — a specialized pack with `version ≥ p3_min_pack_version`
         AND `≥ p3_min_pack_revisions` commits touching its SKILL.md (the pack
         was actually revised, not merely born at v2).
      2. promotion — a specialized pack whose body cites a learning file
         (learning → candidate → active loop closed at least once).

    Shared default packs are excluded on purpose: everyone gets those, so they
    prove nothing about this role.
    """
    evidence: List[str] = []
    for pack in specialized:
        s = skill_index.get(pack)
        if not s:
            continue
        if s["version"] >= PMI_GATES["p3_min_pack_version"] and s["revisions"] >= PMI_GATES["p3_min_pack_revisions"]:
            evidence.append(
                f"{pack} v{s['version']} with {s['revisions']} recorded revisions ({s['path']})"
            )
        if s.get("promotes"):
            evidence.append(f"{pack} promotes {', '.join(s['promotes'])}")
    return evidence


def compute_pmi(inputs: Dict[str, Any], policy: Dict[str, Any]) -> Dict[str, Any]:
    """SYNTHESIS §5.2. P2 requires outcomes; P3 additionally requires proven-loop
    evidence (skill version history or learning→skill promotion)."""
    n = inputs["n"]
    n_done = inputs["n_done"]
    success = inputs["success_rate"]
    specialized = inputs["specialized_packs"]
    evidence = inputs.get("proven_loop_evidence") or []
    p2_ok = n_done >= PMI_GATES["p2_min_done"] and success >= PMI_GATES["p2_min_success"]
    if p2_ok and evidence:
        band = "P3"
        reason = (
            f"Proven loop — n_done={n_done}, success={success:.0%}; "
            f"playbook evidence: {'; '.join(evidence)}"
        )
    elif p2_ok:
        band = "P2"
        reason = (
            f"Playbooked — n_done={n_done} (≥{PMI_GATES['p2_min_done']}), "
            f"success={success:.0%} (≥{PMI_GATES['p2_min_success']:.0%}), n_known={inputs['n_known']}"
        )
        if specialized:
            reason += f"; specialized pack: {', '.join(specialized)}"
        reason += (
            "; no P3 yet — needs a specialized pack with "
            f"version≥{PMI_GATES['p3_min_pack_version']} and ≥{PMI_GATES['p3_min_pack_revisions']} revisions, "
            "or one citing a promoted learning"
        )
    elif n >= PMI_GATES["p1_min_n"]:
        band = "P1"
        reason = f"Instrumented — n={n} (≥{PMI_GATES['p1_min_n']})"
        reason += (
            f"; specialized pack: {', '.join(specialized)} (pack alone does not grant P2)"
            if specialized
            else "; defaults only — pack alone does not grant P2"
        )
        if n_done < PMI_GATES["p2_min_done"]:
            reason += f"; needs n_done≥{PMI_GATES['p2_min_done']} for P2 (have {n_done})"
        elif success < PMI_GATES["p2_min_success"]:
            reason += f"; needs success≥{PMI_GATES['p2_min_success']:.0%} for P2 (have {success:.0%})"
    else:
        band = "P0"
        reason = f"Ad hoc — n={n} < {PMI_GATES['p1_min_n']}"
    return {
        "band": band,
        "reason": reason,
        "cap": policy["display_cap"],
        "cap_reason": policy["cap_reason"],
        "gates": dict(policy),
        "inputs": inputs,
    }


def role_stats(
    trails: List[Dict[str, Any]],
    role_packs: Dict[str, List[str]],
    defaults: List[str],
    repo: Path,
    skill_index: Optional[Dict[str, Dict[str, Any]]] = None,
    policy: Optional[Dict[str, Any]] = None,
) -> Dict[str, Dict[str, Any]]:
    skill_index = skill_index or {}
    policy = policy or pmi_policy(False)
    by: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for t in trails:
        by[t["agent"]].append(t)
    default_set = set(defaults) | DEFAULT_PACKS
    out: Dict[str, Dict[str, Any]] = {}
    for role, items in sorted(by.items()):
        n = len(items)
        n_done = sum(1 for t in items if t["status"] == "done")
        n_fail = sum(
            1
            for t in items
            if t["status"] in ("failed", "fail", "unavailable", "error")
            or (t["status"] != "done" and isinstance(t["agent_exit"], int) and t["agent_exit"] != 0)
        )
        n_unknown = max(0, n - n_done - n_fail)
        n_known = n_done + n_fail
        success = (n_done / n_known) if n_known else 0.0
        packs = list(role_packs.get(role) or defaults)
        specialized = [p for p in packs if p not in default_set]
        evidence = proven_loop_evidence(specialized, skill_index)
        # critic pairing (Phase 1) — reviews received vs. reviews given
        n_reviewed = sum(1 for t in items if t.get("reviewed_by"))
        n_reviews_given = sum(len(t.get("reviews") or []) for t in items)
        inputs = {
            "n": n,
            "n_done": n_done,
            "n_fail": n_fail,
            "n_unknown": n_unknown,
            "n_known": n_known,
            "success_rate": round(success, 4),
            "packs": packs,
            "specialized_packs": specialized,
            "proven_loop": bool(evidence),
            "proven_loop_evidence": evidence,
            "history_available": bool(policy.get("history_available")),
            "sources": [
                "wave-plans/**/handoffs/*.jsonl",
                "config/role-skills.yaml",
                "git log -- skills/*/SKILL.md",
            ],
        }
        out[role] = {
            "role": role,
            "n": n,
            "n_done": n_done,
            "n_fail": n_fail,
            "n_unknown": n_unknown,
            "n_known": n_known,
            "success_rate": round(success, 4),
            "vendor_mix": dict(Counter(t["provenance"]["vendor"] for t in items if t["provenance"]["vendor"])),
            "packs": packs,
            "specialized_packs": specialized,
            "skill_coverage": len(specialized),
            "is_critic": is_critic_role(role),
            "n_reviewed": n_reviewed,
            "review_rate": round(n_reviewed / n, 4) if n else 0.0,
            "n_reviews_given": n_reviews_given,
            "paired_branches": sorted({t["branch"] for t in items if t.get("reviewed_by") or t.get("reviews")})[:20],
            "task_ids": [t["task_id"] for t in items],
            "pmi": compute_pmi(inputs, policy),
        }
    return out


# ── dataset ───────────────────────────────────────────────────────────

def build_dataset(repo: Path, use_gh: bool = True) -> Dict[str, Any]:
    companies = load_companies(repo)
    company_ids = [c["id"] for c in companies]
    joins, warnings = load_joins(repo, company_ids)
    trails = load_trails(repo, companies, joins)

    toplevel = git_toplevel(repo)
    history_available = toplevel is not None
    if not history_available:
        warnings.append("git unavailable for this repo — skill version history omitted (PMI P3 not evaluable from git)")
    skills = load_skills(repo, history=history_available)
    learnings = load_learnings(repo, skills, companies)
    link_promotions(skills, learnings)
    skill_index = {s["id"]: s for s in skills}

    critic_pairs, critic_summary = pair_critics(trails)

    gh = gh_index(repo, toplevel, use_gh)
    apply_gh(trails, gh)
    if gh["status"] not in ("ok", "skipped", "disabled"):
        warnings.append(f"gh enrichment {gh['status']}: {gh['reason']} (build continued without PR/issue data)")
    gh_meta = {k: v for k, v in gh.items() if k not in ("pr_by_branch", "issue_by_number")}
    gh_meta["trails_with_pr"] = sum(1 for t in trails if t["pr_url"])
    gh_meta["fields"] = ["pr_url", "pr_state", "pr_number", "issue_links_resolved"]

    defaults, role_packs = parse_role_skills(repo / "config" / "role-skills.yaml")
    if not defaults:
        defaults = sorted(DEFAULT_PACKS)
    policy = pmi_policy(history_available)
    roles = role_stats(trails, role_packs, defaults, repo, skill_index, policy)

    pack_roles: Dict[str, List[str]] = defaultdict(list)
    for role, packs in role_packs.items():
        for p in packs:
            pack_roles[p].append(role)
    for s in skills:
        s["roles"] = sorted(pack_roles.get(s["id"], [])) or (["(defaults)"] if s["id"] in defaults else [])

    for c in companies:
        c["trail_count"] = sum(1 for t in trails if t["company_id"] == c["id"])

    waves: Dict[str, Dict[str, Any]] = {}
    for t in trails:
        key = str(t["wave"]) if t["wave"] is not None else "none"
        w = waves.setdefault(key, {"wave": t["wave"], "n": 0, "task_ids": []})
        w["n"] += 1
        w["task_ids"].append(t["task_id"])
    wave_list = sorted(
        waves.values(), key=lambda w: (w["wave"] is None, -(w["wave"] or 0))
    )

    n_trails = len(trails)
    return {
        "schema_version": SCHEMA_VERSION,
        "generator": "scripts/experience_data.py",
        "law": LAW,
        "phase": PHASE,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repo": repo.name,
        "counts": {
            "companies": len(companies),
            "trails": n_trails,
            "waves": len([w for w in wave_list if w["wave"] is not None]),
            "skills": len(skills),
            "learnings": len(learnings),
            "roles": len(roles),
            "unlinked_trails": sum(1 for t in trails if t["join_method"] == "unlinked"),
            "critic_pairs": len(critic_pairs),
        },
        "fleet": {
            "n_done": sum(1 for t in trails if t["status"] == "done"),
            **critic_summary,
            "vendor_mix": dict(Counter(t["provenance"]["vendor"] for t in trails if t["provenance"]["vendor"])),
        },
        "join_rules": [
            {"order": 1, "method": "config_map", "source": "config/experience-joins.yaml"},
            {"order": 2, "method": "github_repo", "source": "companies/*.md github_repo"},
            {"order": 3, "method": "repo_path", "source": "companies/*.md repo slug"},
            {"order": 4, "method": "name_token", "source": "companies/*.md name token"},
            {"order": 5, "method": "unlinked", "source": "project label only — never invents a company"},
        ],
        "pmi_policy": policy,
        "skill_history": {
            "available": history_available,
            "depth": GIT_LOG_DEPTH,
            "source": "git log --follow -- <skill path>",
            "reason": "" if history_available else "git not available for this repo",
            "skills_with_history": sum(1 for s in skills if s["revisions"]),
        },
        "gh_enrichment": gh_meta,
        "warnings": warnings,
        "companies": companies,
        "trails": trails,
        "waves": wave_list,
        "critic_pairs": critic_pairs,
        "skills": skills,
        "learnings": learnings,
        "role_stats": roles,
        "watchlist": watchlist(trails),
    }


def write_dataset(repo: Path, out_dir: Path, clean: bool = True, use_gh: bool = True) -> Path:
    """Emit the data contract at <out_dir>/data/index.json.

    Cleans ONLY the `data/` tree it owns. Rendered HTML and any other sibling
    under out_dir survives, so `make experience-data` refreshes the JSON without
    wiping the site. HTML hygiene belongs to scripts/experience_build.py.
    """
    data_dir = out_dir / "data"
    if clean and data_dir.exists():
        shutil.rmtree(data_dir)
    data_path = data_dir / "index.json"
    data_path.parent.mkdir(parents=True, exist_ok=True)
    data_path.write_text(
        json.dumps(build_dataset(repo, use_gh=use_gh), indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )
    return data_path


# ── optional shareable snapshot (SYNTHESIS §7 Phase 1, §10) ───────────

SNAPSHOT_DIR = Path("docs/experience/snapshot")


def snapshot_payload(data: Dict[str, Any]) -> Dict[str, Any]:
    """A small, redacted rollup safe to check in.

    Deliberately DROPS every free-text body: handoff markdown/sections, skill
    bodies, learning bodies. What remains is counts, outcomes and one-line
    summaries that already passed the redactor.
    """
    return {
        "snapshot_of": "site/experience/data/index.json",
        "schema_version": data["schema_version"],
        "phase": data["phase"],
        "law": data["law"],
        "generated_at": data["generated_at"],
        "repo": data["repo"],
        "counts": data["counts"],
        "fleet": data["fleet"],
        "pmi_policy": data["pmi_policy"],
        "skill_history": data["skill_history"],
        "gh_enrichment": {k: v for k, v in data["gh_enrichment"].items() if k != "fields"},
        "companies": [
            {k: c[k] for k in ("id", "status", "github_repo", "trail_count")} for c in data["companies"]
        ],
        "waves": data["waves"],
        "critic_pairs": data["critic_pairs"],
        "roles": {
            r: dict(
                {
                    k: st[k]
                    for k in (
                        "n", "n_done", "n_fail", "n_unknown", "success_rate", "vendor_mix",
                        "specialized_packs", "is_critic", "n_reviewed", "review_rate",
                    )
                },
                pmi_band=st["pmi"]["band"],
                pmi_reason=st["pmi"]["reason"],
            )
            for r, st in data["role_stats"].items()
        },
        "skills": [
            {k: s[k] for k in ("id", "version", "status", "scope", "path", "revisions", "last_commit", "promotes")}
            for s in data["skills"]
        ],
        "learnings": [{k: lrn[k] for k in ("slug", "title", "status", "path", "promoted_by")} for lrn in data["learnings"]],
        "trails": [
            {
                k: t[k]
                for k in (
                    "task_id", "wave", "role", "status", "branch", "company_id", "join_method",
                    "ts", "base_sha", "head_sha", "agent_exit", "is_critic", "reviewed_by",
                    "reviews", "pr_url", "pr_state", "handoff_summary",
                )
            }
            for t in data["trails"]
        ],
        "watchlist": data["watchlist"],
    }


SNAPSHOT_README = """# Fleet Desk snapshot (redacted summary)

Generated by `make experience-snapshot` (`scripts/experience_data.py --snapshot`).

- `summary.json` is a **rollup** of `site/experience/data/index.json`: counts,
  outcomes, PMI bands, critic pairs, skill versions, one-line trail summaries.
- Free-text bodies are dropped on purpose — no handoff markdown, no skill or
  learning bodies, no agent transcripts. Everything that remains already passed
  the redactor in `scripts/experience_data.py`.
- The live site (`site/experience/`) stays gitignored; this directory is the only
  Fleet Desk output that may be committed, and committing it is an owner call
  (SYNTHESIS §10 "checked-in static snapshot for sharing").

Refresh:

```bash
make experience-snapshot
```
"""


def write_snapshot(data: Dict[str, Any], dest: Path) -> Tuple[Path, int]:
    dest.mkdir(parents=True, exist_ok=True)
    path = dest / "summary.json"
    path.write_text(json.dumps(snapshot_payload(data), indent=2, sort_keys=False) + "\n", encoding="utf-8")
    (dest / "README.md").write_text(SNAPSHOT_README, encoding="utf-8")
    return path, path.stat().st_size


def main() -> None:
    default_repo = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description="Fleet Desk data contract — emit site/experience/data/index.json")
    ap.add_argument("--repo", default=str(default_repo), help="repo root to project (default: this repo)")
    ap.add_argument("--out", default="", help="output site dir (default: <repo>/site/experience)")
    ap.add_argument("--no-clean", action="store_true", help="do not wipe the data/ dir first (never touches rendered HTML)")
    ap.add_argument(
        "--no-gh",
        action="store_true",
        help="skip optional gh PR/issue enrichment (also: FLEET_DESK_NO_GH=1). gh failures never fail the build.",
    )
    ap.add_argument("--snapshot", action="store_true", help=f"also write a redacted summary under {SNAPSHOT_DIR}/")
    ap.add_argument("--snapshot-dir", default="", help=f"snapshot destination (default: <repo>/{SNAPSHOT_DIR})")
    args = ap.parse_args()
    repo = Path(args.repo).resolve()
    out_dir = Path(args.out).resolve() if args.out else repo / "site" / "experience"
    use_gh = not (args.no_gh or os.environ.get("FLEET_DESK_NO_GH") == "1")
    path = write_dataset(repo, out_dir, clean=not args.no_clean, use_gh=use_gh)
    data = json.loads(path.read_text(encoding="utf-8"))
    for w in data.get("warnings", []):
        print(f"warn: {w}")
    print(
        f"Fleet Desk data → {path} "
        f"({data['counts']['trails']} trails, {data['counts']['companies']} companies, "
        f"{data['counts']['unlinked_trails']} unlinked, {data['counts']['critic_pairs']} critic pairs)"
    )
    gh = data["gh_enrichment"]
    print(f"  gh enrichment: {gh['status']}{(' — ' + gh['reason']) if gh['reason'] else ''}")
    hist = data["skill_history"]
    print(
        f"  skill history: {'available' if hist['available'] else 'unavailable'} "
        f"({hist['skills_with_history']}/{data['counts']['skills']} packs with commits, depth {hist['depth']})"
    )
    if args.snapshot or args.snapshot_dir:
        dest = Path(args.snapshot_dir).resolve() if args.snapshot_dir else repo / SNAPSHOT_DIR
        snap, size = write_snapshot(data, dest)
        print(f"  snapshot → {snap} ({size / 1024:.1f} KiB, bodies dropped)")


if __name__ == "__main__":
    main()
