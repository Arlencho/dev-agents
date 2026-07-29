# Handoff — feat/fleet-desk-data-contract (PR #46) REVISE pass

Scope: critic findings F1 and F2 only. No UI redesign, no scope expansion.

## Built

- `scripts/experience_data.py` — `write_dataset()` cleans only `<out>/data`,
  not the whole out dir. `--no-clean` help updated to match.
- `scripts/experience_build.py` — new `clean_html(out)`: removes rendered
  `*.html` and the dirs they leave empty, skipping `<out>/data`. Called at the
  top of `Renderer.render()`, so full-rebuild hygiene survives F1's fix.
- `scripts/experience-build.sh` — step comments describe the new split.
- `docs/experience.md` — table of what each command rewrites vs leaves alone,
  plus a note under "Machine-readable view".
- `tests/fixtures/experience-mini/logs/` (new) — realistic agent transcript
  with marker `FIXTURE_TRANSCRIPT_BODY_MUST_NOT_BE_INGESTED`, token shapes,
  home paths, fake private key. `README.md` explains why it exists.
- 4 fixture `.jsonl` handoffs now carry absolute `orchestrator_fields.log`
  paths (3× `/Users/fixtureop/...`, 1× `/home/fixtureop/...`).
- `tests/run-experience-tests.sh` — 77 → 97 checks. New Part C (F1 regression)
  and a real transcript/log-path block with vacuity guards (F2).

## Decisions

- **Split cleaning by ownership** rather than just deleting the rmtree. If the
  data step stops wiping and nobody else cleans, `make experience` starts
  leaving pages for deleted trails forever. Moving HTML cleanup into the HTML
  renderer fixes F1 without trading it for a stale-page bug. `data/` is
  excluded explicitly on both sides.
- **Attached log paths to existing fixture handoffs** instead of adding new
  ones. Trail count (22) and per-role PMI inputs stay untouched, so no
  unrelated assertions needed editing.
- **Added not-vacuous guards** (fixture log exists, has the marker, has secret
  shapes, ≥4 trails carry log names). F2 existed because a fixture silently
  went empty; the guards make that failure mode loud next time.
- Kept the fake private-key block in the fixture log: it is the only coverage
  for the `BEGIN … PRIVATE KEY` redaction shape. Push was not blocked by
  secret scanning.

## Evidence

```
$ bash tests/run-experience-tests.sh | tail -1
== 97 passed, 0 failed ==
```

Mutation testing — each mutant applied to a clean tree, suite re-run, then reverted:

| Mutant | Failures |
| --- | --- |
| `if clean and out_dir.exists(): shutil.rmtree(out_dir)` restored | 5 (Part C: index/work/about/sub-tree/unrelated HTML) |
| `log_body` read from `logs/<name>` into the trail | 4 (transcript body, agent-log dir, secret shapes, home paths) |
| `"log_name": str(orch.get("log") or "")` (no `.name`) | 3 (filename-only, agent-log dir, home paths) |

F1 spot check before writing the test:

```
$ make experience && make experience-data && test -f site/experience/index.html
HTML index SURVIVED
```

Stale-page hygiene still works:

```
$ mkdir -p site/experience/trail/ghost-trail && touch .../index.html && make experience
stale page pruned (good)
data/index.json intact
```

Commit `1823655`, pushed to `feat/fleet-desk-data-contract`.
PR comment: https://github.com/Arlencho/dev-agents/pull/46#issuecomment-5117307666

## Do not repeat

- Do not "fix" F1 by simply deleting the rmtree — that regresses stale pages.
  The two-sided ownership split is the working shape.
- Do not add new fixture handoffs to test log handling: it shifts PMI counts
  and breaks the `22 trails` / `n_done` assertions.
- Multi-line Python expressions passed to `assert_json` must be parenthesised;
  `eval` in eval-mode rejects a bare newline before `and`.
- `logs/*.log` in `.gitignore` is root-anchored, so the fixture logs under
  `tests/fixtures/.../logs/` do commit. Verified with `git check-ignore -v`.

## Open questions

- `clean_html()` prunes any empty directory under the site except `data/`. If a
  future phase ships non-HTML assets (real CSS/JS files), they survive, but
  their directory would be pruned if it ever went empty. Worth revisiting when
  assets land; not a Phase 0 concern.
