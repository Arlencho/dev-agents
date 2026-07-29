#!/usr/bin/env python3
"""
Fleet Desk — data layer (Wave 1 data contract).

Reads git artifacts (companies, handoffs, skills, learnings, role packs) and
emits ONE stable machine-readable projection:

    site/experience/data/index.json

Schema: docs/experience-data.md   (bump `schema_version` on breaking changes)
Law:    docs/proposals/experience-console-SYNTHESIS.md

This module never renders HTML. scripts/experience_build.py renders HTML by
reading the JSON this module writes — JSON first, HTML second.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SCHEMA_VERSION = 1
LAW = "docs/proposals/experience-console-SYNTHESIS.md"
DEFAULT_PACKS = {"evidence-first", "untrusted-prior", "git-ship"}

# PMI gates — frozen in SYNTHESIS §5.2
PMI_GATES = {
    "p1_min_n": 3,
    "p2_min_done": 5,
    "p2_min_success": 0.70,
    "phase0_cap": "P2",
    "cap_reason": "P3 needs version/promotion history (Phase 1)",
}

JOIN_METHODS = ("config_map", "github_repo", "repo_path", "name_token", "unlinked")

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
            if "active phase" in line.lower() or line.strip().startswith("| Wave plan"):
                phase = line.strip()[:120]
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


def load_skills(repo: Path) -> List[Dict[str, Any]]:
    skills: List[Dict[str, Any]] = []
    root = repo / "skills"

    def read(skill_md: Path, status: str) -> Dict[str, Any]:
        meta, body = parse_frontmatter(skill_md.read_text(encoding="utf-8", errors="replace"))
        raw_ver = str(meta.get("version", "1" if status == "active" else "0"))
        version = int(raw_ver) if raw_ver.isdigit() else 0
        body_text, truncated = cap(redact(body), BODY_CAP)
        return {
            "id": meta.get("id") or skill_md.parent.name,
            "version": version,
            "scope": meta.get("scope", "global"),
            "summary": meta.get("summary", ""),
            "status": status,
            "path": friendly_path(skill_md, repo),
            "body": body_text,
            "body_truncated": truncated,
            "roles": [],
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

def compute_pmi(inputs: Dict[str, Any]) -> Dict[str, Any]:
    """SYNTHESIS §5.2. P2 requires outcomes; Phase 0 hard-caps display at P2."""
    n = inputs["n"]
    n_done = inputs["n_done"]
    success = inputs["success_rate"]
    specialized = inputs["specialized_packs"]
    if n_done >= PMI_GATES["p2_min_done"] and success >= PMI_GATES["p2_min_success"]:
        band = "P2"
        reason = (
            f"Playbooked — n_done={n_done} (≥{PMI_GATES['p2_min_done']}), "
            f"success={success:.0%} (≥{PMI_GATES['p2_min_success']:.0%}), n_known={inputs['n_known']}"
        )
        if specialized:
            reason += f"; specialized pack: {', '.join(specialized)}"
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
        "cap": PMI_GATES["phase0_cap"],
        "cap_reason": PMI_GATES["cap_reason"],
        "gates": dict(PMI_GATES),
        "inputs": inputs,
    }


def role_stats(
    trails: List[Dict[str, Any]], role_packs: Dict[str, List[str]], defaults: List[str], repo: Path
) -> Dict[str, Dict[str, Any]]:
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
        inputs = {
            "n": n,
            "n_done": n_done,
            "n_fail": n_fail,
            "n_unknown": n_unknown,
            "n_known": n_known,
            "success_rate": round(success, 4),
            "packs": packs,
            "specialized_packs": specialized,
            "sources": ["wave-plans/**/handoffs/*.jsonl", "config/role-skills.yaml"],
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
            "is_critic": "critic" in role,
            "task_ids": [t["task_id"] for t in items],
            "pmi": compute_pmi(inputs),
        }
    return out


# ── dataset ───────────────────────────────────────────────────────────

def build_dataset(repo: Path) -> Dict[str, Any]:
    companies = load_companies(repo)
    company_ids = [c["id"] for c in companies]
    joins, warnings = load_joins(repo, company_ids)
    trails = load_trails(repo, companies, joins)
    skills = load_skills(repo)
    learnings = load_learnings(repo, skills, companies)
    defaults, role_packs = parse_role_skills(repo / "config" / "role-skills.yaml")
    if not defaults:
        defaults = sorted(DEFAULT_PACKS)
    roles = role_stats(trails, role_packs, defaults, repo)

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
    critic_trails = sum(1 for t in trails if "critic" in t["agent"])
    return {
        "schema_version": SCHEMA_VERSION,
        "generator": "scripts/experience_data.py",
        "law": LAW,
        "phase": 0,
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
        },
        "fleet": {
            "n_done": sum(1 for t in trails if t["status"] == "done"),
            "critic_rate": round(critic_trails / n_trails, 4) if n_trails else 0.0,
            "vendor_mix": dict(Counter(t["provenance"]["vendor"] for t in trails if t["provenance"]["vendor"])),
        },
        "join_rules": [
            {"order": 1, "method": "config_map", "source": "config/experience-joins.yaml"},
            {"order": 2, "method": "github_repo", "source": "companies/*.md github_repo"},
            {"order": 3, "method": "repo_path", "source": "companies/*.md repo slug"},
            {"order": 4, "method": "name_token", "source": "companies/*.md name token"},
            {"order": 5, "method": "unlinked", "source": "project label only — never invents a company"},
        ],
        "pmi_policy": dict(PMI_GATES),
        "warnings": warnings,
        "companies": companies,
        "trails": trails,
        "waves": wave_list,
        "skills": skills,
        "learnings": learnings,
        "role_stats": roles,
        "watchlist": watchlist(trails),
    }


def write_dataset(repo: Path, out_dir: Path, clean: bool = True) -> Path:
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
    data_path.write_text(json.dumps(build_dataset(repo), indent=2, sort_keys=False) + "\n", encoding="utf-8")
    return data_path


def main() -> None:
    default_repo = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description="Fleet Desk data contract — emit site/experience/data/index.json")
    ap.add_argument("--repo", default=str(default_repo), help="repo root to project (default: this repo)")
    ap.add_argument("--out", default="", help="output site dir (default: <repo>/site/experience)")
    ap.add_argument("--no-clean", action="store_true", help="do not wipe the data/ dir first (never touches rendered HTML)")
    args = ap.parse_args()
    repo = Path(args.repo).resolve()
    out_dir = Path(args.out).resolve() if args.out else repo / "site" / "experience"
    path = write_dataset(repo, out_dir, clean=not args.no_clean)
    data = json.loads(path.read_text(encoding="utf-8"))
    for w in data.get("warnings", []):
        print(f"warn: {w}")
    print(
        f"Fleet Desk data → {path} "
        f"({data['counts']['trails']} trails, {data['counts']['companies']} companies, "
        f"{data['counts']['unlinked_trails']} unlinked)"
    )


if __name__ == "__main__":
    main()
