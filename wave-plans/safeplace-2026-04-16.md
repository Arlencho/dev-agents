# SafePlace Wave Plan — 2026-04-16

Owner: Arlen Rios. Repo: `github.com/arlenrios/safeplace` (default branch `main`).
Related: `CLAUDE.md` in repo root; last retro at commit `87bf46a`.

## 1. Plan summary

- **Wave 1 — land the four in-flight features already sitting uncommitted on `main`** (#100 admin diagnostics, #101 Skolverket, #102 safety-score snapshots, #103 enrich-locations CLI). Each is 80–90% done; we finish, test, PR, and hand the production deploy back to the user.
- **Wave 2 — cheap infra wins that unlock everything else**: Cloud SQL upgrade (#104), `/health` + `/ready` (#106), Prometheus metrics (#30), query perf monitoring (#77), SMHI noise purge (#76).
- **Wave 3 — data quality / ground truth**: BRÅ correlation (#98/#105 merged), BRÅ historical import (#12), Polisen decline investigation (#41), `other_crime` classifier (#43), per-agent LLM provider (#75).
- **Wave 4 — product and UX polish**: richer profile pages (#107), push notifications (#108), a11y (#28), `main.go` split (#26), safety-panel v2 (#1) + multi-layer rankings (#8).
- **Deferred / research** (vendor contact required, keep open but not scheduled): #5, #7, #9, #10, #11, #13, #15, #16, #70.

Constraint for every wave: agents finish code and run **local** migrations + tests only. The user executes every production migration and `make deploy` manually.

## 2. Duplicates and close-outs (do before Wave 1)

| Issue | Action | Reason |
|-------|--------|--------|
| #98 | Close as duplicate of #105 | Same title, same scope, same acceptance criteria. #105 has the richer body — keep it, close #98 with a comment linking to #105. |
| #4 | Verify then close | Live Polisen poller (every 10 min) already upserts into `raw_events` which is immutable and partitioned. The "permanent archive" requirement is satisfied. Confirm with a one-line grep in `ingestion/adapter/se/polisen.go` and close if it still applies. |
| #6 | Close | All three sources (Trafikverket, Krisinformation, SMHI) are live in `ingestion/adapter/se/*.go` per `CLAUDE.md`. This issue is historical. |
| #5 | Keep open, relabel `research` | Historical SMHI archive (Oct 2021–Dec 2025) still not imported — it's a batch backfill, not live polling. Not blocking anything. |

Do these close-outs before dispatching Wave 1 so the board reflects reality.

## 3. Wave 1 — dispatch

Four branches, four agents run in parallel. No shared domain files, but **three of them touch `cmd/web/main.go` or `cmd/ingest/main.go`** for route/loader wiring — see section 5 Risks for the merge-order rule.

### #100 — Admin UI diagnostics

- **Branch:** `feat/admin-dashboard`
- **Lead agent:** `go-backend`. Pulls in `db-architect` (migrations 000015+000016) and `test-engineer` (one unit test). Template polish stays with `go-backend` — the template is already 418 lines and essentially done.
- **Key files:** `cmd/web/admin.go`, `web/templates/admin.html`, `db/migrations/000015_admin_user.*`, `db/migrations/000016_system_config.*`, `cmd/web/main.go` (route wiring), `ingestion/news/matcher.go` (read thresholds from DB).

```
claude --agent go-backend "Finish GitHub issue #100 (admin UI for matching-quality diagnostics) on branch feat/admin-dashboard.

The following files are already ~90% done in the working tree and uncommitted — review them before writing anything new:
- cmd/web/admin.go (488 lines, handlers)
- web/templates/admin.html (418 lines, UI)
- db/migrations/000015_admin_user.up.sql + down.sql
- db/migrations/000016_system_config.up.sql + down.sql

Checklist:
1. Read the issue body (gh issue view 100) — acceptance criteria authoritative.
2. Confirm admin.go compiles and is go vet clean. Fix if not.
3. Wire routes into cmd/web/main.go:
   - GET /admin → handleAdminDashboard
   - GET /api/admin/matching-quality
   - GET /api/admin/signal-breakdown
   - GET /api/admin/config (read)
   - POST /api/admin/config (write)
   Protect all of the above with requireAdmin middleware that uses the existing optionalSession cookie and checks users.is_admin=TRUE. Non-admin → 403 for API, redirect to / for the page.
4. Refactor ingestion/news/matcher.go: the severity→threshold map must be loaded from system_config at poll time (cache for the duration of one match pass). If system_config is empty or the row is missing, fall back to the current hardcoded values and log a warning.
5. Run migrations 000015 and 000016 LOCALLY against the safeplace_postgres container on port 5433. Verify the dashboard renders (curl the HTML, eyeball the template).
6. Add ONE unit test in cmd/web/admin_test.go for POST /api/admin/config: enforce JSON shape (reject unknown keys, reject non-numeric thresholds, reject thresholds outside 0.0–1.0).
7. Run: go build ./..., go vet ./..., go test -short ./... — all must pass.
8. git add, commit with message 'feat(admin): matching-quality diagnostics dashboard (#100)', push, open PR targeting main, move issue #100 to 'In Review'.

STOP after the PR is opened. DO NOT run migrations in production, do not flip is_admin=TRUE in prod, do not run make deploy. The user will handle all prod steps after reviewing the PR. Report back with the PR URL and a one-paragraph summary of what changed."
```

### #101 — Skolverket adapter

- **Branch:** `feat/skolverket-adapter`
- **Lead agent:** `go-backend`. Pulls in `db-architect` (migration 000014 review + spatial ETL query) and `test-engineer` (adapter tests — mostly already written).
- **Key files:** `ingestion/adapter/se/skolverket.go`, `ingestion/adapter/se/skolverket_test.go`, `db/migrations/000014_skolverket.*`, `cmd/ingest/main.go` (`runBatchLoaders`), `ingestion/aggregate/aggregate.go`, `cmd/web/context.go` (or wherever `/api/context` handler lives).

```
claude --agent go-backend "Finish GitHub issue #101 (Skolverket schools data source) on branch feat/skolverket-adapter.

The following files are already ~80% done in the working tree and uncommitted — review them before writing anything new:
- ingestion/adapter/se/skolverket.go (231 lines, fetcher using compact API)
- ingestion/adapter/se/skolverket_test.go (85 lines)
- db/migrations/000014_skolverket.up.sql + down.sql (Bronze: raw_skolverket_data; Gold: schools, school_kommun_stats)

Checklist:
1. Read the issue body (gh issue view 101) — acceptance criteria authoritative. API: https://api.skolverket.se/planned-educations/v3/compact-school-units — free, no auth.
2. Confirm the adapter compiles and the tests pass: go test ./ingestion/adapter/se/... Fix any staleness.
3. Wire the loader into cmd/ingest/main.go runBatchLoaders, matching the exact pattern used for Kolada and SCB: NewSkolverketLoader(pool), NeedsRefresh(ctx, maxAge), LoadAll(ctx). Append it AFTER the SCB block, BEFORE the national-averages aggregate step.
4. After raw load, run a spatial ETL step: UPDATE schools SET municipality_code = (SELECT k.code FROM kommun_areas k WHERE ST_Within(schools.location, k.geom) LIMIT 1) WHERE municipality_code IS NULL. Only runs on rows with non-null geocoded locations.
5. In ingestion/aggregate/aggregate.go add an AggregateSchoolKommunStats step that populates school_kommun_stats (schools_total, primary_count, upper_secondary_count per kommun) from the schools table.
6. Expose in GET /api/context response: add schools_in_kommun int (from school_kommun_stats joined on the resolved kommun_code for the incoming lat/lng). Default 0 if no match.
7. Run migration 000014 LOCALLY against safeplace_postgres (port 5433). Run the ingest binary locally and confirm raw_skolverket_data gets ~5,000 rows. Confirm school_kommun_stats is populated for all 290 kommuner. curl /api/context?lat=59.33&lng=18.07 and confirm schools_in_kommun is non-zero.
8. Run: go build ./..., go vet ./..., go test -short ./... — all must pass.
9. git add, commit 'feat(ingestion): Skolverket schools adapter + context signal (#101)', push, open PR targeting main, move issue #101 to 'In Review'.

STOP after the PR is opened. DO NOT run the migration in production, do not deploy ingest. The user will handle prod. Report back with PR URL and a summary including row counts from the local run."
```

### #102 — safety_score_snapshots

- **Branch:** `feat/safety-snapshots`
- **Lead agent:** `db-architect` (migration, the backfill/snapshot query, retention policy). Pulls in `go-backend` (scheduled job + history endpoint), `api-designer` (contract for `/api/safety/history`), `web-frontend` (sparkline on report page).
- **Key files:** `db/migrations/000017_safety_snapshots.*`, `cmd/ingest/main.go` (new cron tick), new file `cmd/ingest/snapshots.go`, `cmd/web/safety.go` or new `cmd/web/history.go`, `cmd/web/main.go` (route), `web/templates/report.html` (Chart.js sparkline).

```
claude --agent db-architect "Finish GitHub issue #102 (safety_score_snapshots: historical time-series) on branch feat/safety-snapshots.

The migration is already in the working tree uncommitted:
- db/migrations/000017_safety_snapshots.up.sql + down.sql

You are the LEAD on this task because it is primarily about correctly recording and serving time-series data. The scope includes Go code and a frontend sparkline — complete those yourself using go-backend and web-frontend conventions, or explicitly note what you need the user to dispatch next.

Checklist:
1. Read issue 102 (gh issue view 102). Acceptance criteria authoritative.
2. Review migration 000017: confirm the UNIQUE constraint is on (lat, lng, radius_m, window_end), the spatial index uses GIST, and the temporal index covers window_end. Fix if not.
3. Product decision needed — PICK ONE and document in the PR body: snapshot all saved_locations nightly (smallest scope, cleanest demo); OR snapshot all 290 kommun centroids at radius=5000 nightly (more useful for analytics but ~290 rows/day vs <20). RECOMMEND kommun centroids for v1 because saved_locations is low-volume in a showcase build — but make the call.
4. Implement the daily job in cmd/ingest/snapshots.go. Triggered from cmd/ingest/main.go with a time.NewTicker(24*time.Hour) and run-on-startup. It iterates the chosen location set, calls the existing safety-scoring logic (factor it out of cmd/web/safety.go into a shared package if needed — do NOT duplicate), and upserts rows into safety_score_snapshots (ON CONFLICT DO NOTHING because of the UNIQUE constraint).
5. Add handler GET /api/safety/history?lat=X&lng=Y&from=YYYY-MM-DD&to=YYYY-MM-DD (defaults: last 90 days). Returns {points: [{window_end, score, event_count}]} sorted ascending. Use ST_DWithin (radius 100m) to match 'close enough' coordinates to snapshotted ones — exact lat/lng matches are too brittle.
6. Wire the route into cmd/web/main.go inside the /api block. No auth needed for the showcase.
7. Frontend: in web/templates/report.html add a Chart.js line chart above the events section; fetch /api/safety/history on page load; hide the chart if the response has < 2 points.
8. Run migration 000017 LOCALLY. Start ingest locally, wait for one snapshot write (or force it by inserting a historical date manually). Verify the history endpoint + sparkline render.
9. go build ./..., go vet ./..., go test -short ./...
10. git add, commit 'feat(snapshots): historical safety_score_snapshots table + history API (#102)', push, open PR targeting main, move issue #102 to 'In Review'.

STOP after the PR is opened. DO NOT run migrations in production, do not deploy anything. In the PR body, explicitly state which snapshot-target decision you made (saved_locations vs kommun centroids) and why. Report back with the PR URL."
```

### #103 — enrich-locations CLI

- **Branch:** `feat/enrich-locations-cli`
- **Lead agent:** `go-backend`. Pulls in `test-engineer` (flag + selection-query tests) and `devops` (Makefile target + `docs/ops.md`).
- **Key files:** `cmd/enrich-locations/main.go`, new `cmd/enrich-locations/main_test.go`, `Makefile`, new `docs/ops.md`.

```
claude --agent go-backend "Finish GitHub issue #103 (productionize enrich-locations CLI) on branch feat/enrich-locations-cli.

The CLI is already present, uncommitted:
- cmd/enrich-locations/main.go (373 lines)

Checklist:
1. Read issue 103 (gh issue view 103). Acceptance criteria authoritative.
2. Confirm the CLI currently reuses ingestion/claude (or the llm-providers wrapper — check which is current) and ingestion/normalize geocoder. The prompt and provider config must match what ingestion/locate/agent.go uses in-service. If they drift, fix the drift — extract a shared Prompt() and NewProviderFromEnv() if needed, and make BOTH the in-service agent and the CLI call it.
3. Add these flags (use the stdlib flag package, not cobra):
   - --municipality CODE  (string, optional, e.g. '1280' = Malmö; filters by normalized_events.municipality_code)
   - --precision-below LEVEL  (string, optional, values: street_address|street|area|municipality; targets events at that level OR below, meaning re-process if current level is lower on the ordering)
   - --limit N  (int, default 100, caps events processed)
   - --dry-run  (bool, prints proposed updates, skips writes)
   - --json  (bool, emits one JSON record per event to stdout for analytics-agent parsing)
4. Add cmd/enrich-locations/main_test.go with tests for:
   - flag parsing (valid + invalid precision levels)
   - the event-selection SQL builder (verify --municipality and --precision-below produce the expected WHERE clauses via sqlmock or a builder-level unit test; no live DB required)
5. Add a 'make enrich-locations' target in Makefile that runs 'go build -o bin/enrich-locations ./cmd/enrich-locations'. Add the binary to make build.
6. Create docs/ops.md (new file — does not exist yet) with a 'Backfilling a kommun after a prompt change' section documenting the CLI. Keep it ~60 lines: purpose, flags, example invocation for rios-brain tunnel, dry-run-first workflow.
7. Add bin/ to .gitignore if not already present.
8. LOCALLY: run ./bin/enrich-locations --municipality 1280 --limit 5 --dry-run against local postgres. Confirm no writes, correct JSON output.
9. go build ./..., go vet ./..., go test -short ./...
10. git add, commit 'feat(cli): productionize enrich-locations backfill tool (#103)', push, open PR, move issue #103 to 'In Review'.

STOP after the PR is opened. DO NOT run against production. The user will run the rios-brain tunnel invocation after reviewing. Report back with PR URL and sample --dry-run --json output."
```

### Wave 1 merge order

1. `feat/skolverket-adapter` **first** — it touches `cmd/ingest/main.go` only (batch loader block) and `ingestion/aggregate/aggregate.go`. Lowest risk.
2. `feat/safety-snapshots` second — also touches `cmd/ingest/main.go` (new ticker) and `cmd/web/main.go` (one route). Likely conflict with #101 in `cmd/ingest/main.go` → rebase, trivial to resolve.
3. `feat/admin-dashboard` third — touches `cmd/web/main.go` (new route group) and `ingestion/news/matcher.go`. Likely conflict with #102 in `cmd/web/main.go` → rebase.
4. `feat/enrich-locations-cli` last — touches `cmd/enrich-locations/`, `Makefile`, `docs/ops.md`, `.gitignore`. Zero overlap with the other three; merges cleanly whenever.

Tell the Wave 1 agents to open PRs against `main`, not against each other. The user rebases in this order locally.

## 4. Waves 2–4 (one-liner each)

### Wave 2 — infrastructure

- **#104 Cloud SQL upgrade** — `devops` — bench p50/p95/p99 before, upgrade `db-f1-micro` → `db-g1-small`, bench after, document cost delta in `docs/ops.md`. Scheduled downtime required.
- **#106 /health + /ready endpoints** — `go-backend` — `/health` returns 200 always, `/ready` checks `pool.Ping()` + returns 503 on failure. Register with Cloud Run startup probe.
- **#30 Prometheus metrics** — `go-backend` — add `prometheus/client_golang`, expose `/metrics`, instrument API latency histogram + ingestion success/error counters.
- **#77 Query perf monitoring** — `db-architect` — enable `pg_stat_statements`, document top 10 slow queries, add missing indexes where `EXPLAIN ANALYZE` shows seq scans on `normalized_events`.
- **#76 SMHI noise purge** — `db-architect` — `DELETE FROM normalized_events WHERE source='smhi' AND severity <= 2` (~191k rows), wrap in transaction, run `VACUUM ANALYZE` after.

### Wave 3 — data quality

- **#98+#105 BRÅ correlation** (merged) — `db-architect` + analytics-agent — pull BRÅ CSVs for 2023–2025, compute Pearson + Spearman vs our scores, document outliers in `docs/validation/bra-outliers.md`, target r > 0.7.
- **#12 BRÅ historical import** — `db-architect` — BRÅ publishes per-kommun 1996–present; import to `raw_bra_data` Bronze + roll up into `crime_statistics`. Complements the Kolada feed.
- **#41 Polisen decline** — `investigate` — 312 events/7d vs 58k historical is a 20× drop; diagnose whether it's our poller, Polisen's API, or a filter regression.
- **#43 other_crime classifier** — `go-backend` — 15% of Polisen events land in `other_crime`; add keyword+LLM classifier to split into `fraud`, `drugs`, `public_order`, `other_minor`.
- **#75 per-agent LLM provider** — `go-backend` — allow `LLM_PROVIDER_LOCATE=qwen` and `LLM_PROVIDER_VERIFY=anthropic` as env-var overrides on top of the global default.

### Wave 4 — product / UX

- **#107 Richer profile pages** — `web-frontend` — add historical crime sparkline, demographics radar, school count, top news headlines to `/se/{code}`.
- **#108 Push notifications** — `go-backend` + `web-frontend` — VAPID keypair generation, `push_subscriptions` table, hook into the existing `alerts.go` loop, update `sw.js` push handler with real payload.
- **#28 Accessibility** — `web-frontend` — keyboard nav on map controls, ARIA labels on filter pills, focus-visible outlines, reduced-motion media query.
- **#26 Split main.go** — `maintainability-reviewer` + `go-backend` — `cmd/web/main.go` is 2,096 lines; split handlers by domain (safety, auth, report, admin, api-v1) into separate files leaving only routing + startup in `main.go`.
- **#1 Safety panel v2 + #8 multi-layer rankings** — `web-frontend` — score reasoning breakdown, subcategory rings, toggle rankings across (events | per_capita | socioeconomic composite).

## 5. Risks and gotchas

- **File overlap on `cmd/web/main.go`** — #100 (admin route group) and #102 (history endpoint) both add to `r.Route("/api", ...)`. Merge #102 first to keep #100's admin block isolated. Called this out in merge-order above.
- **File overlap on `cmd/ingest/main.go`** — #101 adds a Skolverket block to `runBatchLoaders`, #102 adds a new `snapshots` ticker to startup. Both will hit the same file but different regions; rebase resolves it. Worst case is 1-minute manual merge.
- **`ingestion/news/matcher.go` refactor (#100) is riskier than the issue implies** — swapping hardcoded thresholds for a DB read inside a hot polling loop introduces per-poll query latency and a cache-invalidation question. Prompt tells the agent to cache for the duration of one match pass; make sure reviewer checks that.
- **#102 snapshot job writes to a new table daily forever** — retention is an open question in the issue. Force the agent to decide (kommun centroids at ~290 rows/day = ~106k rows/year, fine; saved_locations can grow unbounded — recommend capping at 10k). Retention policy can be a Wave-2 follow-up.
- **#104 Cloud SQL upgrade means ~5–10 min web + API downtime.** Schedule outside daytime Swedish hours. Warn the user to announce. Org policy still blocks public IPs — the upgrade stays on private IP, no access change.
- **#100 admin migration 000015 adds `is_admin` to `users`** — safe (NULL default). But the prompt tells the agent to NOT flip `is_admin=TRUE` in prod — remember to do that manually via `scripts/db-query.sh --write` after the PR merges.
- **#12 BRÅ historical import will overlap crime_statistics currently populated by Kolada.** Decide up front: is BRÅ authoritative and Kolada becomes a fallback, or do they coexist with provenance tracking? This is a design call for Wave 3 start, not Wave 1.
- **Stale worktrees under `.claude/worktrees/`** — I spotted 9+ agent worktrees still on disk from prior sessions. Not urgent but run `git worktree prune` plus `rm -rf .claude/worktrees/agent-*` before Wave 1 to avoid agents picking stale branches.
- **`ingestion/news/.!31864!verify.go`** — leftover 0-byte temp file noted in MEMORY.md. Delete before Wave 1 so `go vet ./...` stays clean.
- **The analytics-agent can run read-only audits in parallel with every wave** — cheap, high-signal. Consider running it once per wave as a gate ("data quality score before/after").
