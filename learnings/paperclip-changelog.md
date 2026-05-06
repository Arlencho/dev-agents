# Paperclip Release Changelog

Tracking log produced by the weekly release scan (OLY-5 routine). Each entry is appended by the QA Engineer on scan day.

---

## 2026-05-04 — Scan by Orchestrator (OLY-419)

| Field | Value |
|---|---|
| Pinned version | `2026.427.0` |
| Latest version | `v2026.428.0` (released 2026-04-28) |
| Releases ahead of pinned | **1** |
| Flagged releases | **None** (no body matches BREAKING / migrate / deprecat) |

### 5 most recent releases (newest → oldest)

| Tag | Released | Notes |
|---|---|---|
| `v2026.428.0` | 2026-04-28 | Sidebar pause/resume agents, virtualized issue threads, **productivity review service** (auto-opens review issues for no-comment streaks, long-active runs, high-churn loops). **Failed `stranded_issue_recovery` issues now block-in-place** instead of spawning nested recovery loops — directly relevant to the OLY-424→OLY-430 cascade we just hit. New-hire approval opt-in by default. Per-company `attachmentMaxBytes` (10 MB default). 4 additive DB migrations (`0071`–`0074`). |
| `v2026.427.0` | 2026-04-27 | **Current pinned version.** Multi-user access/invite flows, structured issue-thread interactions, run liveness continuations, sub-issue checklist, issue subtree pause/cancel/restore, 14 additive DB migrations (0057–0070). |
| `v2026.416.0` | 2026-04-16 | Issue chat thread (assistant-ui), execution policies, blocker dependencies, MCP server beta, issue search. Security fix GHSA-68qg-g8mg-6pr7 (auth hardening). 8 additive DB migrations (0049–0056); `pg_trgm` extension required for 0051. |
| `v2026.403.0` | 2026-04-03 | Inbox overhaul, feedback/evals, document revisions, telemetry, execution workspaces (experimental). 4 additive DB migrations (0045–0048). |
| `v2026.325.0` | 2026-03-25 | Company import/export, skills library, routines engine. 7 additive DB migrations (0038–0044). |

### Flagged releases (BREAKING / migrate / deprecat)

Scope: only releases **newer** than pinned `2026.427.0`. Scan covered `v2026.428.0`.

**None flagged.** All four `0071`–`0074` migrations are explicitly additive per the upgrade guide; no existing data modified. Default flip on `require_board_approval_for_new_agents` (now `false`) only affects new inserts — existing companies preserve their stored value.

### Operational signal worth noting (not a breaking change)

`v2026.428.0` ships **two changes that bear on issues we've been seeing locally**:

1. **Block-in-place on failed `stranded_issue_recovery`** (#4600) — the recovery cascade pattern (OLY-227 → OLY-228, OLY-419 → OLY-424 → OLY-430) where each transient failure spawns a fresh recovery shell is exactly what this fixes. Upgrading would meaningfully reduce the cascade-noise problem documented in `feedback_recovery_cascade_auth_root_cause.md`.
2. **Productivity review service auto-opens review issues** for no-comment streaks / long-active runs / high-churn loops (#4700, #4701) — overlaps with our manual liveness-checker patterns; needs a read-through before upgrading to make sure the new auto-issues don't double-up with our existing detectors.

**Recommendation:** non-urgent upgrade candidate. No CEO action required. Re-evaluate at next scan, or batch with a post-demo housekeeping window.

---

## 2026-04-28 — Scan by QA Engineer (OLY-6)

| Field | Value |
|---|---|
| Pinned version | `2026.427.0` |
| Latest version | `v2026.427.0` (released 2026-04-27) |
| Releases ahead of pinned | **0** |
| Flagged releases | **None** |

### 5 most recent releases (newest → oldest)

| Tag | Released | Notes |
|---|---|---|
| `v2026.427.0` | 2026-04-27 | **Current pinned version.** Multi-user access/invite flows, structured issue-thread interactions, run liveness continuations, sub-issue checklist, issue subtree pause/cancel/restore, 14 additive DB migrations (0057–0070). |
| `v2026.416.0` | 2026-04-16 | Issue chat thread (assistant-ui), execution policies, blocker dependencies, MCP server beta, issue search. Security fix GHSA-68qg-g8mg-6pr7 (auth hardening). 8 additive DB migrations (0049–0056); `pg_trgm` extension required for 0051. |
| `v2026.403.0` | 2026-04-03 | Inbox overhaul, feedback/evals, document revisions, telemetry, execution workspaces (experimental). 4 additive DB migrations (0045–0048). |
| `v2026.325.0` | 2026-03-25 | Company import/export, skills library, routines engine. 7 additive DB migrations (0038–0044). |
| `v2026.318.0` | 2026-03-18 | Plugin framework/SDK, issue documents, Hermes adapter, execution workspaces. 10 additive DB migrations (0028–0037). |

### Flagged releases (BREAKING / migrate / deprecat)

Scope: only releases **newer** than pinned version `2026.427.0`. None exist — pinned IS latest.

**None flagged.**

> Next scan due: ~2026-05-11 (weekly cadence per OLY-419 routine). If upstream has cut a new release by then, re-run to produce the next entry.
