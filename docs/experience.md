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
| **Home** | Global overview: companies, recent tasks, roles, skills, learnings |
| **Work** | All tasks, **grouped by wave** (global). Per-company Work under each company page |
| **Skills** | Global packs + versions + which roles inject them |
| **Learn** | Learnings + promoted/documented status |
| **Roles** | Usage counts + **Playbook Maturity Index (PMI)** |
| **Conductor** | One-shot conductor trails |
| **About** | Sources, join rules, PMI formula, how to refresh |

**Scope chip** (always visible): `Global | olympus | safeplace | …`  
Same UI grammar in both scopes.

### Tasks and waves

- **Trail** = one handoff task (atom).  
- **Wave** = grouping field on trails.  
- Open **Work** → sections “Wave 11”, “Wave 9”, … → click a row → full trail detail (plan title, decisions, do-not-repeat, evidence).

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
