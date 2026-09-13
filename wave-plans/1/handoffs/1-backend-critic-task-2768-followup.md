# Handoff: hold typescript on 6.x, branch ci/hold-typescript-6

## Built

`.github/dependabot.yml` only. One commit, `b439aa3d`, 9 insertions, 0 deletions.

Added to the existing npm entry at `directory: "/"`:

```yaml
    ignore:
      - dependency-name: "typescript"
        update-types:
          - "version-update:semver-major"
```

with a four line WHY comment above it naming the compiler JS API break, the one file
that uses it, PR #2786 and the #2401 guard. PR opened: #2788 (open, not merged).

## Decisions

- **Scoped with `update-types`, no `versions` key.** A `versions: ">= 7"` style rule
  or a bare `dependency-name` entry would also stop the 7.x PR, but the bare form
  blocks 6.x patch and minor bumps too. `update-types: [version-update:semver-major]`
  is the only form that keeps 6.x maintenance flowing, which was the load bearing
  requirement.
- **Verified the schema against the live docs, not memory.** Fetched
  `https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference`
  (HTTP 200) and read the `ignore` parameter table plus the `update-types (ignore)`
  section. This matters because dependabot accepts a malformed `ignore` block silently
  and it just does nothing, so a typo here fails open with no signal.
- **Confirmed the rule parses into the right entry**, not just that the file is valid
  YAML. Valid YAML with the block nested one level off would land the ignore on the
  wrong ecosystem and still parse. Dumped the parsed structure per ecosystem to prove
  it attached to npm at `/` and that gomod and github-actions have `ignore: null`.
- **Did not touch the guard test.** `apps/web/lib/flight-place-contract.test.ts` is not
  in the diff. `git diff main...HEAD --name-only` returns exactly one path.
- **Did not close PR #2786.** It was already CLOSED when I checked
  (`gh pr view 2786`, headRef `dependabot/npm_and_yarn/typescript-7.0.2`), so there was
  nothing to do and it was out of scope regardless. Noted in the PR body.

## Do not repeat

- Do not "fix" this by reworking the guard off the compiler JS API unless something
  concrete depends on TypeScript 7. That was the considered alternative and it was
  rejected as work with no payoff today. If you do the rework later, delete this ignore
  block in the same PR so it does not outlive its reason.
- Do not widen the ignore to a bare `dependency-name: "typescript"` when a 6.x bump
  later goes red. That silently ends all TypeScript maintenance. Fix the bump instead.
- The stale `handoff.md` in this clone was from an unrelated task (PR 2765,
  `docs/settlement-empirical-check`). It is untracked and was overwritten, not
  committed. Do not read a leftover handoff here as context for the current branch.

## Evidence

```
$ python3 -c "import yaml,sys; yaml.safe_load(open('.github/dependabot.yml'))"
$ echo "yaml_safe_load_exit=$?"
yaml_safe_load_exit=0

$ python3 ... (print ecosystem, directory, ignore for each update)
gomod /apps/api ignore= null
npm / ignore= [{"dependency-name": "typescript", "update-types": ["version-update:semver-major"]}]
github-actions / ignore= null

$ git diff --name-only        (pre-commit)
.github/dependabot.yml
count=1

$ git show --stat HEAD
 .github/dependabot.yml | 9 +++++++++
 1 file changed, 9 insertions(+)

$ git diff main...HEAD --name-only
.github/dependabot.yml

$ grep -nP '[\x{2014}\x{2013}\x{2015}]|\s--\s'  on added lines, PR title, PR body, commit message
scan_exit=1   (no match, clean)

$ grep -ci 'co-authored-by'  on PR body + commit message
0
```

`schedule`, `labels` and `open-pull-requests-limit` unchanged on all three ecosystems.
`package.json` and `package-lock.json` untouched. `apps/web/package.json` still pins
`"typescript": "^6.0.2"`; nothing upgraded or downgraded.

## Next hint

The hold has no expiry mechanism. If you want it to surface again rather than rot,
file a low priority issue referencing PR #2788 and the #2401 guard, so the revisit is
scheduled rather than depending on someone re-reading a YAML comment.
