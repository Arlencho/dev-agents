# Handoff: PR 79 round 2 (feat/floor-v3c)

## Built

- `scripts/desk_live.py`: `mark_paths()` factors the slash-token loop out of `first_sentence` and is applied in `add()` (every NEEDS YOU line), in `pr_view` (the title) and in the `pr list` join (the same title on seat rows).
- `scripts/notify.sh`: `needs_you_due` keys the seen file on `type|kind|<stable fields>` (comment_id; repo+pr; dispatch_id+task_id; checkout+file+line) and refuses an item whose text still carries an absolute, home, variable, `file:` or parent-escape token (stderr line, nothing sent, not seen).
- `tests/run-desk-live-tests.sh`: Part L round 2, 33 checks, inserted before "a missing projection is nothing to push".
- `docs/experience-data.md`: the push paragraph states both rules.
- PR 79 body: Round 2 heading with real exit codes. Commit e3b44e6, pushed.

## Decisions

- Bare `$HOME` (no slash) is left alone: the critic's fix line asks for the slash-token rule of `task_path`, and a bare variable name is not a path. Stated in the PR body so the critic can object explicitly if wanted.
- A refused item is not recorded as seen, so the same item marked by the projector later is still pushed. Recording it would silently lose a real item.
- `event` and `ts` are outside the stream identity: a quiet seat that heartbeats once and goes quiet again is the same item.
- Milestone, issue and merged-PR titles (Almanac side) keep `scrub_text` only; out of the critic's scope.

## Do not repeat

- `cd scripts` in one Bash call changed the working directory for the sibling calls in the same batch; use absolute paths.
- BSD grep has no `-P`; scan for banned dashes with Python.
- `shellcheck tests/run-desk-live-tests.sh` exits 1 at HEAD already on note-level SC2015/SC2016; compare at `-S warning` (three pre-existing lines: 89, 157, 172).

## Evidence

```
./tests/run-desk-live-tests.sh     exit 0  passed: 450 failed: 0
./tests/run-experience-tests.sh    exit 0  337 passed, 0 failed
shellcheck scripts/notify.sh       exit 0
python3 -m py_compile scripts/desk_live.py  exit 0
node --check templates/experience/floor.js  exit 0
git log --oneline -1  e3b44e6 fix(floor): keep operator paths out of the toast, key the push on the item identity
```

## Next hint

The critic re-reviews PR 79 from comment 5653828539. If it wants bare `$HOME` marked too, extend `task_path` (one `startswith` on a slashless token) and add one `assert_fn`.
