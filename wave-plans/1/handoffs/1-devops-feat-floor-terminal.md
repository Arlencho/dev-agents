# Handoff: PR 83 round 2, the five critic block findings on the terminal

## Built

- `scripts/floor_tty.py`: `NotAProjection` gate in `load()` (dict with `schema == "live/1"`, the page's rule); the loop catches `OSError, ValueError, TypeError, AttributeError, KeyError` and paints `Could not read <file>: <reason>` on a cleared screen; `--once` exits 2 with the reason. New `initiatives_section` (4.5, between UP NEXT and the day), wrapped rows with a hanging indent, `Section` trims by whole row. Status line is the page's strip (figures need a `summary`; without one: `no counts: this projection carries no summary`). Missing `needs_you`/`queue`/`today`/`initiatives` read as empty with the page's copy. NOW header `unknown`, queue row `repo not declared`. `file_cite()` prints checkout-relative file and line only.
- `tests/run-floor-tty-tests.sh`: Part D, one block per finding (31 checks); order assertion includes INITIATIVES; the stale test plants a summary.
- `tests/fixtures/floor-tty/{wave,conductor,floor-v3}.txt`: re-pinned.
- `docs/experience.md`: the terminal paragraph names INITIATIVES and the gate.
- PR 83 body: Round 2 heading, exit codes, live `--once` render.

## Decisions

- Off-schema in `--once` exits 2 with the reason on stderr (same path as missing and broken files) rather than printing an empty shell on stdout: a script consuming `--once` must not read a refusal as a render.
- Initiative rows use the page's DOM text form (`repo title: facts`) and wrap rather than shave, because the exit sentence is the answer to question 5.
- `wave 0 of 0` on real rows is the page's behaviour too (`typeof planned === "number"`); left as is.
- PR left as draft: its base is `feat/floor-v3b`, not `main`, by the author's stated choice; marking it ready would expose it to the auto-merge sweep against a non-main base.

## Do not repeat

- A bash heredoc patch containing inner `<<'PY'` heredocs must use a different outer delimiter, or the outer heredoc ends early and nothing is written.
- `wrap()` collapses runs of spaces via `norm()`; do not expect a double-space separator to survive it.
- zsh does not word-split `$var` in `for n in "a b"; do set -- $n`; run per-fixture commands separately.

## Evidence

- `./tests/run-floor-tty-tests.sh` -> exit 0, 97 passed 0 failed
- `shellcheck -S warning tests/run-floor-tty-tests.sh` -> exit 0
- `./tests/run-experience-tests.sh` -> exit 0, 354 passed 0 failed
- `./tests/run-desk-live-tests.sh` -> exit 0, 368 passed 0 failed
- `bash tests/critic/phase-b-honesty-repro.sh` -> exit 0, 6 passed 0 failed
- `make desk-live-once` -> exit 0; `make floor FLOOR_FLAGS=--once` -> exit 0
- commit `00b2d0b` on `feat/floor-terminal`, pushed; PR 83 head `00b2d0b8cbeb17f1ae3ef4461c52e65ed2bff62c`

## Next hint

- The critic re-reviews from its own `/tmp` fixtures; Part D rebuilds them from the report, so a green Part D should match its re-run.
