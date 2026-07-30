# Fleet Desk — operator guide

**What it is:** a local, **read-only** static site that projects fleet work, skills, learnings, and role maturity.  
**Law:** [`docs/proposals/experience-console-SYNTHESIS.md`](proposals/experience-console-SYNTHESIS.md) · v2: [`docs/proposals/fleet-desk-v2-SYNTHESIS.md`](proposals/fleet-desk-v2-SYNTHESIS.md) (Phase A)  
**Not:** GitHub Issues, skill promote UI, or a live agent control panel.

---

## Start the view (every time after a wave)

From the `dev-agents` repo root:

```bash
# Build data contract → then site → site/experience/ (gitignored)
make experience

# Build + open in your browser
make experience-open

# Alias
make desk

# Data only (JSON contract, no HTML)
make experience-data

# Redacted, shareable rollup → docs/experience/snapshot/ (optional)
make experience-snapshot
```

`make experience` is two steps in a fixed order:

```text
git artifacts → site/experience/data/index.json → site/experience/**.html
```

The HTML reads **only** that JSON — see [`docs/experience-data.md`](experience-data.md)
for the schema. If something is missing from a page, check the JSON first.

Each step cleans only what it owns, so the two are safe to run independently:

| Command | Rewrites | Leaves alone |
| --- | --- | --- |
| `make experience-data` | `site/experience/data/` | every rendered `.html` page |
| `make experience` | `data/` then all `.html` | — (full rebuild) |

So `make experience-data` refreshes the contract **without** wiping an already
rendered site: reload the browser and the pages read the new JSON.

Then open:

```text
site/experience/index.html
```

Or full path:

```text
file:///…/dev-agents/site/experience/index.html
```

Optional local server (if `file://` is awkward):

```bash
make experience
cd site/experience && python3 -m http.server 8765
# browse http://127.0.0.1:8765/
```

**Refresh model:** re-run `make experience` after dispatch waves or skill/learning edits. The footer shows generation time.

---

## What you will see (v2 navigation)

Two attention modes, toggled in the header: **Almanac** (the settled record —
every page below except Floor) and **Floor** (the live radar — a static shell
in Phase A). Tagline: *See the fleet move. Keep the record honest.*

Every page opens with a **hierarchy strip**:

```text
Global › Company › Repo › Mission › Wave / Task
```

Levels that do not apply yet render dimmed (`…`, `any`, `—`); the current
level is highlighted. You should always know where you are in the tree.

| Nav | Meaning |
|-----|---------|
| **Home** | Global rollup: pipeline strip, fleet stats, companies, top missions, live teaser, recent work, watchlist, roles, skills |
| **Missions** | Issue-centric portfolio: one card per mission with path `company / repo / #issue`, state pill, wave count, settled meter |
| **Work** | All tasks, **grouped by wave** by default — `by wave \| flat` toggle; each row links up to its mission when the trail cites an issue |
| **Skills** | Global packs + versions + which roles inject them (active / candidate status) |
| **Learn** | Learnings + promoted/documented status |
| **Roles** | Usage counts + **Playbook Maturity Index (PMI)** badges with expandable raw inputs |
| **Conductor** | One-shot conductor trails |
| **Floor** | Ops Floor shell: Wave lanes + Conductor spine **structure** with honest empty states — no fake agents (Phase B wires real events) |
| **About** | Sources, join rules, PMI formula, derived-view rules, how to refresh |

**Pipeline language everywhere:** Queued · In flight · Blocked · Settled.
The Almanac is a projection of *settled* handoffs, so `done` → **Settled** and
`failed`/`unavailable` → **Blocked**, while Queued and In flight render as an
honest **—** with a pointer to the Ops Floor. Counts are never invented.

**Missions** are derived, not stored: trails that cite the same GitHub issue
(`#123` or a full issue URL in the handoff) group into a mission. A mission
with several waves renders one collapsible card per wave with its seat/task
table; a mission with exactly one trail collapses to the **simple 1:1** view
(issue → 1 task → 1 seat) with the wave chrome hidden. Bare `#123` refs group
per company (the repo is ambiguous), and 6+-digit tokens like hex colors never
become missions. When `gh` did not resolve the issue, the card says the title
comes from a trail. Full rules: [`docs/experience-data.md`](experience-data.md)
§ Derived views.

**Scope chip** (always visible): `Global | olympus | safeplace | …` — placeholder
companies are dimmed. Same UI grammar in both scopes.

Reading the chrome (v2 visual system — dark-first Almanac craft):

- **Status is text AND color**: `done` / `failed` / pipeline pills always carry the word — never color alone.
- **Wave is always visible** on trail rows, wave section headers, mission detail wave cards, and trail detail breadcrumbs (`← Work · scope · wave N`).
- **SHAs, branches, task ids, paths** render in monospace; `base → head` pairs on trail detail.
- **Empty states teach**: every empty table/card names the next command (`make experience`, dispatch, `make desk-live` on the Floor).
- Dark theme is the default; light honors `prefers-color-scheme`. Keyboard users get a skip link, visible focus rings, and `aria-current` on nav/scope/toggle; `prefers-reduced-motion` kills all animation.

The stylesheet lives at `templates/experience/site.css` and is copied to
`site/experience/assets/site.css` on every build — edit the template, not the copy.

### Tasks and waves

- **Trail** = one handoff task (atom).  
- **Wave** = grouping field on trails.  
- Open **Work** → sections “Wave 19”, “Wave 17”, … (newest wave first, `Unlinked / no wave` last) → click a row → full trail detail (meta grid, plan line, built / decisions / do-not-repeat / evidence, raw redacted record under a disclosure).  
- Prefer a single list? Click **flat** in the `Group:` toggle (`work/flat/`). The toggle is plain links — no JavaScript required anywhere.

### Company / repo

Click a company chip → company home: repo chips (1..N from the manifest), a
company-scoped pipeline strip, its **missions**, then joined work trails →
**Open Work for &lt;company&gt;** for that product’s joined trails only.  
Unlinked work (e.g. black-aces without a company join) stays on **Global** with an honest label.

### The Ops Floor

**Floor** (`site/experience/live/index.html`) is the live radar. With no
`live.json` in the build it is the honest teach shell: ghost Wave lanes, a
dashed Conductor spine, an empty waiting-on strip, and an offline LED — never
fake agents, fake timers, or invented live state. When
`site/experience/data/live.json` (schema `live/1`) exists, the Floor renders a
labeled snapshot of it: ambient LED (live / STALE / offline), the waiting-on
strip, pipeline counts, Wave seat lanes grouped by wave (ghost lanes for plan
seats not yet started), a Conductor serial spine when `mode=conductor`, repo +
plan hierarchy context when the stream carries them, and a redaction-safe
event tail. Live state will **never** be stored in `index.json` — see the v2
SYNTHESIS §3 Phase B.

### The live data path (Phase B)

`scripts/dispatch.sh` appends redaction-safe JSONL events to
`logs/fleet-events/<dispatch_id>.jsonl` (+ a `latest` pointer), and
`make desk-live` folds them into `site/experience/data/live.json`
(schema `live/1`: `waiting_on`, `seats`, `mode`, `staleness`, `last_event_ts`)
while serving the desk on `http://127.0.0.1:8777/live/` with SSE at `/events`.

```bash
make desk-follow        # **recommended** — serve Floor + open browser (live, no reload)
make desk-live          # same watcher without auto-opening the browser
make desk-live-once     # write live.json once, no server (file:// desks)
FLEET_EVENTS=0 ./scripts/dispatch.sh ...   # opt out of the stream entirely
```

### Follow live (not only after finish)

| You want | Do this |
|----------|---------|
| **Watch a wave while it runs** | Terminal A: `make desk-follow`. Terminal B: `dispatch.sh` or `fleet-session.sh run …` |
| **Timers / motion** | Floor polls every ~3s — **no page reload** (HTTP only, not `file://`) |
| **Stuck?** | Ambient **QUIET** + waiting-on `quiet_stream` when no events for ~90s while still “running” |
| **Autopilot / long shell work** | Wrap so Floor sees it: `./scripts/fleet-session.sh run --label my-run -- <cmd>` |

```bash
# Example: follow make test on the Floor
make desk-follow   # leave open
./scripts/fleet-session.sh run --label make-test --repo dev-agents -- make test
```

Chat “Command running” alone is **not** on the Floor. Events must hit `logs/fleet-events/`
(`dispatch.sh` already does; use `fleet-session.sh` for other long jobs).

The Floor page loads `assets/floor.js`, a tiny poller that re-reads
`data/live.json` every few seconds over http and repaints the LED, waiting-on
strip, pipeline counts, lanes/spine, and event tail in place — recomputing
staleness from the projection's own thresholds, so a stream that stops goes
STALE then OFFLINE on its own. The build-time renderer derives staleness the
same way (from `last_event_ts` against the projection's `stale_after_s` /
`offline_after_s`, never from the stored `staleness.state` alone), so a
`live.json` left behind by a dead run rebuilds as STALE/OFFLINE on both the
Floor and the home teaser — the teaser has no poller, so its build-time
derivation is the whole product there. Over `file://` the fetch is usually
blocked; there the build-time snapshot stays on screen (refresh with
`make desk-live-once` + `make experience`). Either way only stream facts are
rendered.

Never in the stream: task descriptions, prompts, transcripts, absolute paths.
Logs and plans travel as **filenames**. Full schema:
[`experience-data.md` § Live event stream](experience-data.md#live-event-stream-phase-b--logsfleet-eventsjsonl).
The home page's Live teaser mirrors the same projection snapshot when present.

### Replay scrubber (Phase C)

Settled runs can be scrubbed on the Floor without looking like a live dispatch.

1. Run `make desk-follow` (or `make desk-live`) — HTTP so the scrubber can call `/api/runs` and `/api/replay`.
2. Open **Floor**. When the projection is terminal (settled / aborted), click **Enter REPLAY**.
3. Drag the scrubber — the Floor re-projects only events with `seq <= as_of_seq`.
4. Honesty chrome: violet LED + **REPLAY** watermark. Green LIVE is never painted in replay.

```bash
# One-shot historical snapshot (file:// desks — no scrubber UI without a server)
python3 scripts/desk_live.py --once --dispatch-id 20260729-180000-dev-agents --as-of-seq 4 --replay
make experience   # rebuild pages against data/live.json
# Catalog known streams
python3 scripts/desk_live.py --list-runs
```

### Trail ↔ mission ↔ floor links (Phase C)

| From | To |
|------|----|
| **Trail** detail | Ops Floor (live) + REPLAY entry |
| **Mission** page | Ops Floor + REPLAY |
| **Floor** seats | trail detail when seat `branch` matches an Almanac trail |
| **Floor** cross-links | Work · Missions · plan context |

Joins stay honest: no invented mission when the Almanac has none.

---

## While using (daily loop)

1. Run or finish a fleet wave (`dispatch.sh`).  
2. `make experience-open`.  
3. Scan **Home** or **Work** for what landed.  
4. Drill **Roles** if you care about seat maturity / vendor mix.  
5. Check **Learn** / **Skills** before promoting a lesson (promotion is still a **PR**, not a button here).

Companion CLIs (unchanged):

```bash
make evidence      # quality scorecard from handoffs
make scorecard     # rate-caps / cooldowns
make vendor-auth   # CLI session preflight
```

---

## Phase 1 enrichment (what got richer, and when it is silent)

All four are **optional inputs**: if the tool or the data is missing, the build
still succeeds and the JSON says so instead of guessing.

| Enrichment | What you get | When it is missing |
|------------|--------------|--------------------|
| **Skill git history** | `git log` per `SKILL.md` (≤ 20 commits: sha, date, subject), version + revision counts | No git → `skill_history.available: false` + a build warning; nothing is invented |
| **PMI P3** | A role can now reach **P3 (proven loop)**: P2 outcomes **plus** a specialized pack with `version ≥ 2` and ≥ 2 revisions, **or** a pack citing a promoted learning | Stays at P2 with a reason that names what is missing |
| **Critic pairing** | `critic_rate` is now producer↔critic pairing on the **same branch**, with `critic_pairs[]` and per-trail `reviewed_by` / `reviews` | No pairs → falls back to the Phase 0 name-based rate and labels itself `role_name_fallback` |
| **`gh` PR/issue links** | `pr_url`, `pr_state`, resolved issue **titles** on trails | `gh` missing, logged out, offline or slow → empty fields + `gh_enrichment.status`; **the build never fails**. Disable with `--no-gh` / `FLEET_DESK_NO_GH=1` |

`make experience-snapshot` writes `docs/experience/snapshot/summary.json` (~25 KiB today):
counts, PMI bands + reasons, critic pairs, skill versions, one-line trail rows.
Free-text bodies are dropped, so it is safe to share; committing it is your call.

**Where Phase 1 lands on the pages:** trail detail shows the PR row and resolved
issue titles (only when `gh` matched this repo) plus `Reviewed by` / `Reviews`
links between trails that share a branch; role detail expands a P3 badge into its
`proven_loop_evidence` lines (and P2 roles say plainly why the gate is not met);
skill detail lists revisions, first/last commit and up to 20 commit subjects —
or an honest *git history unavailable* line when the projection had no git;
Home carries a **critic pairs** stat; About states the `critic_rate_method` with
its raw basis counts and the `gh_enrichment` status of the build.

Exact gates, field lists and the v1 → v2 migration:
[`docs/experience-data.md`](experience-data.md).

---

## Data sources

- `companies/*.md`  
- `wave-plans/**/handoffs/*.{jsonl,md}`  
- `wave-plans/conductor/`  
- `skills/*/SKILL.md`, `config/role-skills.yaml`  
- `learnings/*` (+ product `docs/qa/learning-*.md` if that repo is on disk)
- `git log -- skills/*/SKILL.md` (version history, depth 20)
- `gh pr list` / `gh issue list` — **only** when `gh` is authed; titles only, never bodies

Optional joins: `config/experience-joins.yaml` (`pattern: company_id`).
Join order: explicit map → `github_repo` → repo slug → company name token → **unlinked**
(ad-hoc work keeps a project *label*; a label is never turned into a company).
Every trail records its `join_method` and the token that matched.

**Never** embeds agent transcript logs from `~/dev/agent-logs/` — only the log
*filename* is used as a join hint. Token-shaped strings are redacted before they
reach the JSON, and the tests fail if any survive.

### Machine-readable view

```bash
make experience-data
python3 -c "import json;d=json.load(open('site/experience/data/index.json'));print(d['counts'])"
```

`make experience-data` only rewrites `site/experience/data/` — rendered HTML from
an earlier `make experience` stays on disk.

Schema and stability rules: [`docs/experience-data.md`](experience-data.md).

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Empty Work | No handoffs yet, or run `make experience` after dispatch |
| Company has 0 trails | Join failed — see join method on trail detail; add `experience-joins.yaml` or improve task/branch naming |
| Stale page | Re-run `make experience` |
| Page missing a field | Check `site/experience/data/index.json` — HTML can only show what the contract carries |
| `schema mismatch` error | Data JSON is from an older build: re-run `make experience` |
| Browser blocked file:// | Use `python3 -m http.server` under `site/experience` |
| No PR links on trails | Check `gh_enrichment.status` in the JSON (`unavailable` / `unauthenticated` / `error`), then `gh auth login`. Trails dispatched into a product repo never match this repo's PRs — that is correct |
| Role stuck at P2 | Read `pmi.reason`: P3 needs a specialized pack with `version ≥ 2` and ≥ 2 commits, or one citing a promoted learning |
| `critic share` looks odd | Read `fleet.critic_rate_method`: `branch_pairing` (reviewed producers) or `role_name_fallback` (no branch pair found) |

---

## Related

- Data contract / schema: [`docs/experience-data.md`](experience-data.md)  
- Operator fleet ops: [`docs/operator-guide.md`](operator-guide.md)  
- Session modes: [`docs/session-modes.md`](session-modes.md)  
- Skills: [`skills/README.md`](../skills/README.md)  
