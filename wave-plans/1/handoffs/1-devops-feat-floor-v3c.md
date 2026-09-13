## Built

- `scripts/desk_live.py`: `percent_decode()` (bounded `urllib.parse.unquote` loop); `task_path` decodes the token before the must-contain-slash skip; `mark_paths` also hands a token holding `%` to `task_path`.
- `scripts/notify.sh`: the same `percent_decode()` inside `needs_you_due`; `has_operator_path` decodes each token before the slash skip.
- `tests/run-desk-live-tests.sh`: Part L round 4 (12 checks): unit shapes, the product path with the encoded PR 102 title, PR 108 and 109 refused in the hand-written file (count 7 to 9).
- PR 79 body: Round 4 section with real exit codes. Commit `def5c3a`, pushed to `origin/feat/floor-v3c`.

## Decisions

- Full percent decoding, not only `%2F`: `%7E`, `%24`, `%2E%2E` would otherwise be the next round. Bounded at 4 passes so `%252F` unfolds too.
- A token that reads as no path is returned as it came (`50%25` stays). One that is a repo-relative path, branch or URL reads decoded; nothing leaks either way.

## Do not repeat

- A `python3 - <<'PY'` patch script whose payload itself contains a `<<'PY'` heredoc terminates early in the outer shell. Use a distinct terminator or a temp file.

## Evidence

```
./tests/run-desk-live-tests.sh   exit 0   passed: 473 failed: 0  (461 before)
./tests/run-experience-tests.sh  exit 0   337 passed, 0 failed
shellcheck scripts/notify.sh     exit 0
python3 -m py_compile scripts/desk_live.py scripts/experience_build.py  exit 0
node --check templates/experience/floor.js  exit 0
shellcheck -S warning tests/run-desk-live-tests.sh  lines 89, 157, 172 only (pre-existing)
```
