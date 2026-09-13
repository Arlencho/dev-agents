# Handoff: PR 2765 review findings, branch docs/settlement-empirical-check

## Built

`docs/operations/deployment.md` only, docs only, across two commits on the branch.

- `aee0857a` addressed F1, F2, F4, F5, F6, F7, F8, F9, F10 and recorded F3 as open.
- `10b8b478` (this run) removed a residual on F2 and made the gate commands non-interactive.

The F2 residual: the gate added in `aee0857a` is correct, but the bolded lead of step 6
still read "The fix is a web redeploy, not an env change". That sentence sat directly
above a gate whose step 2 requires restoring the environment BEFORE deploying, so the
section gave opposite instructions to a skimming reader and a careful one. Bolded text
is what a mid-incident operator reads. The lead now states that neither half works alone
and that the remedy is ordered: environment first, then redeploy.

Also `vercel env add` prompts without `--value` and `vercel env rm` prompts without
`--yes`, so the gate commands would hang a scripted operator. Both flags added.

## Decisions

- **Did not race the sibling run.** Two dispatches of this identical task ran
  concurrently in the same clone (logs `...175657` and `...175732`). Detected mid-task:
  the file changed under me between two reads, `git diff --stat` went 24 to 42
  insertions, and `ps` showed two `dispatch.sh` pipelines. A read-modify-write from my
  side would have silently dropped the sibling's edits. Stopped writing, waited for its
  process to exit, then audited its result and topped up only what was missing.
- **Appended to the existing PR comment instead of adding a second one.** The task asked
  for one comment; the sibling had already posted it. Used `gh pr comment --edit-last`.
- **F3 left open deliberately**, as instructed. No execution record invented, no
  unobserved date written. Steps 2 to 4 are marked PENDING FIRST EXECUTION, declared
  source-derived, with manual browser verification named as QA-owned.

## Do not repeat

- Do not assume a dirty working tree in this clone is stale leftover state. Check for a
  concurrent dispatch (`ps aux | grep dispatch.sh`) before editing shared files.
- Do not verify a doc fix only against the finding text. The F2 remedy was added
  correctly and the unsafe sentence it was meant to replace survived four lines above it.
  Read the resulting section end to end as an operator would.
- `vercel env ls` in this repo needs `--project web --scope arlens-projects-009d3307`.
  A bare invocation fails to stderr and yields empty stdout, which impersonates the
  "flag absent" finding. That is F1 and it is now documented in the file.

## Evidence

```
$ vercel env ls production --project web --scope arlens-projects-009d3307
NEXT_PUBLIC_FEATURE_CHAT_CARD_PAYMENT   1   Non-sensitive   Production   21d ago
$ cd apps/web && vercel env ls production
Error: Your codebase isn't linked to a project on Vercel. Pass --project <name> ...
$ git diff --stat 62bb5206..HEAD
docs/operations/deployment.md | 61 ++++++++--- (46 insertions, 15 deletions)
$ git diff 62bb5206..HEAD | grep "^+" | grep -P "\x{2014}|\x{2013}|\x{2015}| -- "
(no matches)
$ git rev-parse HEAD origin/docs/settlement-empirical-check
10b8b478b841edf5fd3d0fa49051dcc473345e87
10b8b478b841edf5fd3d0fa49051dcc473345e87
```

PR 2765 OPEN, not merged, head `docs/settlement-empirical-check`, one human comment.

## Open questions

- `deployment.md:86` carries the same unlinked `vercel env ls` defect as F1. Pre-existing
  text, not cited by the reviewer, not in this PR's diff. Fold in or file a follow-up?
- The F3 PENDING notice has no tracker issue. A QA-owned issue would give it one and
  stop it becoming permanent furniture.
