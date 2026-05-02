# Paperclip Release Changelog

Tracking log produced by the weekly release scan (OLY-5 routine). Each entry is appended by the QA Engineer on scan day.

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

> Next scan due: ~2026-05-28. If upstream has cut a new release by then, re-run OLY-5 to produce the next entry.
