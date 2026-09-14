# Fleet optimization: the most optimal way of working

Proposal for the owner's review. Version 1, 2026-09-14 10:15. Status: APPROVED by the owner on 2026-09-14 10:20 ("I approve"). Decisions 2 and 3 in section 8 are asked one at a time. The fleet is stopped since 10:02 (no seats running, queue runner paused).

## 1. Why

Between 2026-09-12 and 2026-09-14 the fleet delivered real product (the assistant channel end to end, the Floor, the orchestration loop) and never let a defect reach production. It also spent several times more elapsed time and spend than the work needed. Most of the cost was gaps, repeats and review depth, not building. The owner asked for the end goal first, then the work, then how to prove it worked.

## 2. The end goal

- The owner decides, the system delivers. The owner's time goes to product, money, copy and sign-offs, never to asking how it is going.
- Effort follows risk. Money, identity and traveller-facing work get the deepest review; internal tooling gets a light, fast pass.
- Every token has a purpose that can be named. Spend is visible per initiative and per PR, and proportional to value.
- Work is paid for once. A failure is detected in minutes, retried automatically, and never silently repeated or silently stuck.
- Waiting is the exception. Nothing sits between steps unless a person has to decide, and those decisions sit in one place with one action each.
- One truth, at a glance. What runs, what is next, what landed, what needs the owner: current, never noise.
- Quality is invariant, cost is variable. The bar never drops; the machinery a change needs to meet it does.
- Vendor-agnostic and session-agnostic. The way of working lives in the system, not in one model or one session.

## 3. Baseline: what was observed, 2026-09-12 to 2026-09-14

Each line names its source. Numbers marked unverified are estimates to be replaced by the ledger in workstream 1.

| Measure | Observed | Source |
|---|---|---|
| First-party seat cost, one day | about 178 dollars over 45 seat results on 2026-09-13 | sum of total_cost_usd in logs/dispatch-runs/20260913-*.log |
| First-party limits hit | 3 times: 17:30 on 09-13, about 00:25 on 09-14, 08:39 on 09-14 (monthly limit of the top tier) | seat result lines |
| Silent stall, spend limit | about 3 hours, 17:30 to 20:14 on 09-13 | dispatch logs and session record |
| Silent stall, hung seats | about 2 hours, 03:18 to 05:23 on 09-14 | last model event per seat |
| Critic rounds on internal tooling | orchestrator loop 7, notifications 5, needs-you cleanup 4 | PR comments on dev-agents 82, 79, 89 |
| Wall time of a one-line fix round | 52 minutes producer plus about 20 minutes critic | dev-agents PR 89 round 4 dispatch log |
| Floor v3 elapsed versus work | 22 hours elapsed, about 6 hours of seat work (unverified split) | session record |
| Rework caused by the orchestrator | a directory-wide commit turned main red for 2 hours; a branch deletion closed a stacked PR; one misread routing request | memory records of 2026-09-13 and 09-14 |
| Escaped defects in production | none found | issue 2340 and production walks |
| Cost of the orchestrator session itself | not measured | none |
| Cost of cross-vendor seats | not measured; their logs show no cost line (unverified) | seat logs |

## 4. Principles the work must keep

1. Measure before changing; every change names the metric it moves.
2. The quality bar is a constraint, not a variable.
3. Lessons go into the system (checks, seat instructions), not into a session.
4. This programme follows its own rules: internal tooling tier, light review, targeted tests.

## 5. The work, in order

Each workstream has a scope, a deliverable, and an exit test. Later workstreams depend on the ledger.

### W1. The ledger (measurement)

Scope: one record per seat run with repository, initiative, plan, PR, round, role, provider, model, tier, start, end, active time, waiting time, outcome, tokens and cost where the provider reports them, and a marker when cost is unknown. Rolled up per round, per PR and per initiative. Includes the orchestrator session as its own line where it can be read, and says so when it cannot.

Deliverable: the ledger file and a daily rollup, readable in the terminal and shown on the Floor as one line per initiative.

Exit test: for every PR merged in a test week, the ledger answers what it cost, how long it took, how many rounds, and how much of the time was waiting, and the numbers reconcile with the provider usage pages within a stated tolerance.

### W2. Risk tiers

Scope: three tiers, declared in every plan header. Tier A: money, identity, security, data retention. Tier B: traveller-facing product. Tier C: internal tooling and docs. The tier fixes the critic set, the maximum number of rounds before a person decides, what counts as a blocking finding, and the model tier of the critics.

Deliverable: the tier table in the fleet docs, the header in the plan format, and a dispatch check that refuses a plan without a tier.

Exit test: over the test window, no Tier C PR goes past its round cap without a recorded decision, and no Tier A PR merges with fewer critics than its tier requires.

### W3. Right-sized verification

Scope: fix rounds run the tests for the touched code; the full suite runs once before merge or in CI; critics re-run only the fixtures of the findings being closed plus a named regression check. Already started as dev-agents PR 94 (open, round 1 BLOCK-FIX).

Deliverable: PR 94 finished and merged.

Exit test: median wall time of a fix round drops to under 20 minutes in the test window, with no increase in defects found after merge.

### W4. Reliability: work is paid for once

Scope: the four filed gaps. Hung seat detection and retry (dev-agents issue 92). Provider limit detection, hold instead of retry, and a stop row (issue 84). Memory guard reading the real free share (issue 91). Verdicts read from where critics post them (issue 90). Plus a provider tier shift before a known cap is reached.

Deliverable: the four issues closed.

Exit test: in the test window, every stall is detected within 30 minutes, no seat is relaunched by hand, and no unattended hour passes with work stuck.

### W5. Lean seats

Scope: a fix round or review round starts from the finding, the diff and the named files, not from the whole repository and every charter again. Prompt packets are sized to the task.

Deliverable: a round packet format and the launcher reading it.

Exit test: tokens per fix round, from the ledger, fall against the W1 baseline, with rounds to SAFE unchanged or better.

### W6. A lighter orchestrator

Scope: the runner handles hops, stops, the ledger and merges that are fully green on Tier C; the orchestrator session is woken for decisions, not for polling; automatic merge for Tier A and B stays off until the ledger shows the gate is trustworthy.

Deliverable: the runner owning those steps, and the session polling removed.

Exit test: in the test window the owner asks no status question the Floor could have answered, and the orchestrator session cost, where measurable, falls.

## 6. How we prove it worked

Two weeks of normal work after W1 to W4 are merged, compared with the baseline in section 3 and with the ledger numbers of the first week.

| Measure | Baseline | Target |
|---|---|---|
| Cost per merged PR, by tier | unknown | known for every PR; Tier C down, Tier A unchanged or up if needed |
| Critic rounds, Tier C | 4 to 7 | at most 2 |
| Fix round wall time, median | 72 minutes on the observed case | under 20 minutes |
| Unattended stall time | about 5 hours in two nights | zero hours; every stall detected within 30 minutes |
| Work share of elapsed time | about a quarter on the Floor (unverified) | above three quarters |
| Unplanned provider limit hits | 3 in two days | none |
| Status questions from the owner | many per day | none the Floor could answer |
| Escaped defects in production | none | none (the guardrail) |

## 7. How the programme runs

- Tier C for all of it: web producer seat and plan critic, two rounds at most per PR, targeted tests.
- W1 first and alone; W2 to W4 in parallel after W1 merges; W5 and W6 after the first week of ledger data.
- Each workstream is one PR with its exit test written into the PR body before code.
- The queue runner stays paused until W4 merges.

## 8. Decisions for the owner, one at a time

1. Approve this proposal as the programme, or change the order.
2. The round cap for Tier C: two rounds proposed.
3. Whether the ledger includes the orchestrator session cost, which may need reading the provider usage page by hand once a day until it can be automated.

## 9. Not in scope

- Changing which provider holds which seat (settled 2026-09-14).
- Product work on Olympus, paused until the owner restarts it; the three open Olympus and fleet PRs stay as they are.
- Any automatic merge on Tier A or B.
