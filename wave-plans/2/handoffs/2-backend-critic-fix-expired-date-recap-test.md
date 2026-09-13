# Handoff — fix/expired-date-recap-test

## Built

Fixed the two tests in `apps/api/internal/service/recap_confirmation_test.go`
that turned main red on 2026-08-30 by hardcoding a hotel stay with
`check_in: "2026-08-25"` / `check_out: "2026-08-28"`:

- `TestRecapGate_ConfirmingUnlocksWhenTheRecapAlsoAsked`
- `TestRecapGate_AffirmativeSurvivesATypo`

Once today passed 2026-08-25, `parser.go`'s `validateParsedDates` started
blanking those fields as past on every turn, which flipped the flow
classification (`hotels` → `trip`) and readiness/missing-set derivation the
tests asserted on. No production code was touched.

Added `futureStayWindow()` (check-in 30 days out, check-out 3 nights after
it, computed with `time.Now()` at test-run time) and threaded it through both
tests' JSON fixtures and chat-message text in place of the literal ISO
strings. Kept the 3-night span fixed, since the expected recap copy in
`TestRecapGate_ConfirmingUnlocksWhenTheRecapAlsoAsked` says "budget for the 3
nights" and that assertion depends on the span, not on the actual calendar
dates.

## Decisions

- **`recapPlusAsk`'s prose had to become date-dependent too, and this was the
  non-obvious part.** The mock/stub `ai_message` in that test isn't just an
  opaque string compared by `assert.Equal` against itself — production's
  `recapIsIncomplete` (`recap_completeness.go`, the § 6.0.6a completeness
  check) actually parses the prose against the real `check_in`/`check_out`
  field values and substitutes a deterministic read-back if the prose doesn't
  name them (with the year). The original literal text ("Athens, August
  25-28 2026…") worked because it happened to describe the literal fixture
  dates — it was never just decorative. Once the dates became relative, I had
  to make the prose track them or the completeness check would substitute a
  different string than the test expected, on ITS OWN correct logic (not a
  test bug). Used the literal ISO form (`"Athens, 2026-09-29 to 2026-10-02,
  1 guest…"`) rather than an English month name, because
  `recapDateReadback`'s exact-ISO-substring branch certifies both the date
  and its year in one shot regardless of what month/year the offset lands on
  — no month-boundary or year-rollover case to reason about.
- **Did not touch the other three tests in the same file**
  (`TestRecapGate_ACorrectionIsNotAConfirmation`,
  `TestRecapGate_AffirmativeToAConciergeFollowUpDoesNotSearch`,
  `TestRecapGate_ARecapWithNoAppendedQuestionStillUnlocks`) even though they
  use the identical expired `2026-08-25`/`2026-08-28` literals. Verified with
  `go test -run TestRecapGate -v` that all three are currently green: none of
  their assertions depend on `.Flow`, so the date-blanking's effect on flow
  re-basing doesn't reach anything they check. They're real members of the
  broader hardcoded-date class (see the follow-up issue) but not part of the
  failure this PR fixes, and the task scope was explicit about not fixing the
  class.
- **Did not touch `recap_confirmation_critic_test.go`**, which has the exact
  same `2026-08-25`/`2026-08-28` pair in
  `TestRecapGate_AQuestionDoesNotFireTheSearch`, for the same reason (its
  assertions don't depend on `.Flow` either, so it's currently green). Named
  explicitly in the follow-up issue as the most likely next occurrence of
  this exact bug.

## Do not repeat

- Don't assume a hardcoded past date in a fixture is automatically what's
  making a test fail, or automatically safe to leave. It's ONLY a live bug
  when something downstream actually branches on "is this in the past" and an
  assertion depends on that branch's outcome. Proving which is which requires
  running the test, not just grepping for the date pattern.
- Don't assume the stub/mock `ai_message` text in these `runTurn`-driven
  tests is inert prose. `recap_completeness.go` really does parse it against
  the real field values on the recap beat, so a fixture's prose has to keep
  agreeing with its own fields' actual dates, not just with a fixed string
  the assertion compares against.
- `agent_conductor_flight_only_ready_test.go`'s `TestFlightsMissingRequired_ValueOracle`
  already has the right shape for testing past-date behavior without wall-clock
  dependence: it takes `today` as an explicit test parameter instead of reading
  `time.Now()`. Point future date-sensitive tests at that pattern before
  reaching for `futureStayWindow()`'s wall-clock approach, which only exists
  because `runTurn`'s pipeline has no `today` injection seam.

## Evidence

Target test, 5x green, `count=1`, real exit codes (not piped):
```
$ go test ./internal/service/... -run '^TestRecapGate_ConfirmingUnlocksWhenTheRecapAlsoAsked$' -count=1
ok  	github.com/Arlencho/olympus-platform/apps/api/internal/service	0.342s
RUN 1 EXIT CODE: 0
ok  	github.com/Arlencho/olympus-platform/apps/api/internal/service	0.359s
RUN 2 EXIT CODE: 0
ok  	github.com/Arlencho/olympus-platform/apps/api/internal/service	0.347s
RUN 3 EXIT CODE: 0
ok  	github.com/Arlencho/olympus-platform/apps/api/internal/service	0.345s
RUN 4 EXIT CODE: 0
ok  	github.com/Arlencho/olympus-platform/apps/api/internal/service	0.361s
RUN 5 EXIT CODE: 0
```

Full `apps/api` suite with `-race`, `count=1`:
```
$ go test ./... -race -count=1
ok  	.../apps/api/cmd/backfill-duffel-order-id	1.417s
ok  	.../apps/api/cmd/server	3.182s
ok  	.../apps/api/cmd/worker	2.117s
ok  	.../apps/api/internal/ai	3.911s
ok  	.../apps/api/internal/apievent	3.219s
ok  	.../apps/api/internal/config	1.781s
ok  	.../apps/api/internal/crypto	2.576s
ok  	.../apps/api/internal/email	3.234s
ok  	.../apps/api/internal/handler	30.482s
ok  	.../apps/api/internal/integration	3.042s
ok  	.../apps/api/internal/inventory	6.698s
ok  	.../apps/api/internal/logsafe	2.831s
ok  	.../apps/api/internal/middleware	2.871s
ok  	.../apps/api/internal/model	2.671s
ok  	.../apps/api/internal/notifier	15.703s
ok  	.../apps/api/internal/payment	2.545s
ok  	.../apps/api/internal/pricing	2.763s
ok  	.../apps/api/internal/provider	5.543s
ok  	.../apps/api/internal/provider/maps	2.658s
ok  	.../apps/api/internal/service	44.603s
ok  	.../apps/api/internal/store/postgres	1.866s
ok  	.../apps/api/internal/stripelog	3.022s
ok  	.../apps/api/internal/testfixture	2.200s
ok  	.../apps/api/internal/worker	2.978s
FULL SUITE EXIT CODE: 0
```

`go build ./...` and `go vet ./internal/service/...`: both exit 0.

Class scan (report-only, not fixed here):
```
$ grep -rlE '2026-(0[1-9]|1[0-2])-[0-3][0-9]' apps/api/internal --include='*_test.go' | wc -l
131
```
(a python scan excluding comment-only lines gets the same 131; restricting to
`2026-0[1-9]` only gets 115 — the "128" figure cited in the task's own framing
is in the same range, exact count depends on regex/exclusion choices). Full
detail, named candidates, and the mechanical-detection proposal are in issue
#2742.

CI-gap finding (report-only): `git show --stat --name-only` on `b79201cd` and
`34ad429d` (the two commits on `main` after `0fc77ab7`) confirms both touch
only `apps/web/` and `docs/`, so `go-test`'s `paths-filter` in
`.github/workflows/ci.yml` correctly skipped it on both — `go-test` last
actually ran on `main` at `0fc77ab7` (2026-08-24). Filed as issue #2743.

## Open questions

None for this PR. #2742 and #2743 are scoped as follow-ups, not blocking.
