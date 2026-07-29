# Fleet Desk — operator guide

**What it is:** a local, **read-only** static site that projects fleet work, skills, learnings, and role maturity.  
**Law:** [`docs/proposals/experience-console-SYNTHESIS.md`](proposals/experience-console-SYNTHESIS.md)  
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

## What you will see

| Nav | Meaning |
|-----|---------|
| **Home** | Global overview: fleet stat strip (trails, done %, critic share, waves, vendor mix), companies, recent tasks, watchlist, roles, skills, learnings |
| **Work** | All tasks, **grouped by wave** by default — use the `by wave \| flat` toggle for a flat newest-first list. Per-company Work under each company page |
| **Skills** | Global packs + versions + which roles inject them (active / candidate status) |
| **Learn** | Learnings + promoted/documented status |
| **Roles** | Usage counts + **Playbook Maturity Index (PMI)** badges with expandable raw inputs |
| **Conductor** | One-shot conductor trails |
| **About** | Sources, join rules, PMI formula, how to refresh |

**Scope chip** (always visible): `Global | olympus | safeplace | …` — placeholder
companies are dimmed. Same UI grammar in both scopes.

Reading the chrome (Wave 2 visual system):

- **Status is text AND color**: `done` / `failed` pills always carry the word — never color alone.
- **Wave is always visible** on trail rows, wave section headers, and trail detail breadcrumbs (`← Work · scope · wave N`).
- **SHAs, branches, task ids, paths** render in monospace; `base → head` pairs on trail detail.
- **Empty states teach**: every empty table/card names the next command (`make experience`, dispatch).
- Light/dark follows `prefers-color-scheme`; keyboard users get a skip link, visible focus rings, and `aria-current` on nav/scope/toggle.

The stylesheet lives at `templates/experience/site.css` and is copied to
`site/experience/assets/site.css` on every build — edit the template, not the copy.

### Tasks and waves

- **Trail** = one handoff task (atom).  
- **Wave** = grouping field on trails.  
- Open **Work** → sections “Wave 19”, “Wave 17”, … (newest wave first, `Unlinked / no wave` last) → click a row → full trail detail (meta grid, plan line, built / decisions / do-not-repeat / evidence, raw redacted record under a disclosure).  
- Prefer a single list? Click **flat** in the `Group:` toggle (`work/flat/`). The toggle is plain links — no JavaScript required anywhere.

### Company / repo

Click a company chip → company home → **Open Work for &lt;company&gt;** for that product’s joined trails only.  
Unlinked work (e.g. black-aces without a company join) stays on **Global** with an honest label.

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

## Data sources (Phase 0)

- `companies/*.md`  
- `wave-plans/**/handoffs/*.{jsonl,md}`  
- `wave-plans/conductor/`  
- `skills/*/SKILL.md`, `config/role-skills.yaml`  
- `learnings/*` (+ product `docs/qa/learning-*.md` if that repo is on disk)

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

---

## Related

- Data contract / schema: [`docs/experience-data.md`](experience-data.md)  
- Operator fleet ops: [`docs/operator-guide.md`](operator-guide.md)  
- Session modes: [`docs/session-modes.md`](session-modes.md)  
- Skills: [`skills/README.md`](../skills/README.md)  
