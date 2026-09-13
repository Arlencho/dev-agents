## Built

Fixed the three findings from the W1B scope critic review (issue #2340, comment titled "CRITIC ASSISTANT CHANNEL W1B SCOPE") against PR 2804, branch `feat/ac-w1b-scope`. Commit `72f96411`, pushed to the same branch.

1. Security fix (BLOCK): `apps/api/internal/middleware/auth.go` and `apps/api/internal/handler/routes.go`. The concierge scope's liveness check now calls `HasActiveBindingForChannel(ctx, userID, model.ChannelTelegram)` instead of the any-channel `HasActiveBinding(ctx, userID)`, mirroring the assistant branch's existing pattern. `WithConciergeBindingCheck` now takes a `ScopedBindingChecker` + channel argument, same shape as `WithAssistantBindingCheck`.
2. Test: `apps/api/internal/handler/hermes_scope_enforcement_test.go`. `TestHermesScopeEnforcement_AssistantRevocationDoesNotCoupleToConcierge` converted to table-driven with two rows: revoke assistant (unchanged assertion) and the new mirror-image row, revoke telegram while an assistant binding stays active, asserting the concierge token is refused.
3. Advisory: `apps/api/internal/config/config.go` `validate()` now rejects a `CORS_ALLOWED_ORIGINS` entry of `"*"` with a clear error. Two new tests in `config_test.go`.
4. Mechanical follow-on: `apps/api/internal/middleware/auth_scope_test.go` updated (`mockBindingChecker` now implements `HasActiveBindingForChannel`, all `WithConciergeBindingCheck` call sites pass a channel constant) to keep the package compiling under the new signature.
5. Documentation finding (env vars) NOT done: out of this agent's scope (`apps/api/` only). `.env.example` and `docs/operations/env-vars-api.md` need a devops-scoped follow-up.

## Decisions

- Kept `ConciergeBindingChecker`/`HasActiveBinding` on `service.ConciergeService` rather than deleting them: nothing outside its own compile-time assertion test used them after the switch, and removing a working method the review didn't ask to remove would have been more churn than the finding required.
- Reused the existing `ScopedBindingChecker` interface for the concierge checker instead of inventing a third type, since it already had exactly the right shape (`HasActiveBindingForChannel`).
- Did not attempt the `.env.example` / `docs/operations/env-vars-api.md` edits: they are outside `apps/api/`, blocked by this agent's scope-check hook, and per the charter/task authority order the charter wins. Flagged in the PR comment as a devops follow-up instead of silently skipping it.
- Restructured `TestHermesScopeEnforcement_AssistantRevocationDoesNotCoupleToConcierge` into a table (two rows) rather than a second standalone test function, since the review asked for the mirror row to be added to that same test, with both directions pinned together.

## Do not repeat

- Don't assume "add a channel-keyed check" is a same-package, same-signature drop-in. `HasActiveBinding` and `HasActiveBindingForChannel` have different arities, so the option constructor's signature had to change, which cascades into every test call site in the package. Check for that cascade before estimating the diff size.
- The review explicitly required a *behavioral* red for fail-first, not a compile error, because "every earlier fail-first was compile-only" on this branch. Proving that took a real throwaway worktree with the test file copied in but the production fix withheld, run once before the fix and once after, both with `$?` read directly.

## Evidence

```
$ cd apps/api && go build ./...          # exit 0
$ go vet ./...                            # exit 0
$ go test ./... -race                     # exit 0, all packages ok
$ golangci-lint run ./apps/api/...        # exit 0, "0 issues."
$ make check-api-spec                     # exit 0, 79 routes / 83 paths in sync
```

Fail-first proof (throwaway worktree at `d7a4eee5`, test file only, no production fix):
```
=== RUN   .../revoke_telegram_leaves_assistant_untouched_(mirror_image)
    Error: []int{401, 403} does not contain 201
--- FAIL: TestHermesScopeEnforcement_AssistantRevocationDoesNotCoupleToConcierge (0.00s)
exit code 1
```
Same worktree, production fix applied: exit code 0, both subtests PASS.

PR comment: https://github.com/Arlencho/olympus-platform/pull/2804#issuecomment-5633478596

## Open questions

- Who picks up the `.env.example` / `docs/operations/env-vars-api.md` documentation gap: devops agent, or does the dispatcher route just that piece there directly?
- The review's item 3 (W0 dependency / `docs/prd/pages/assistant-channel.md` citations) is explicitly deferred pending #2802's sign-off, per this task's own instruction. Not actioned here, as directed.
