# Risk tiers

Fleet optimization workstream W2 (`docs/proposals/fleet-optimization.md` section 5).
Effort follows risk: the tier of a plan fixes how deep its review goes and when a
person must decide.

Every plan declares one tier with a header line `# TIER: A`, `# TIER: B` or
`# TIER: C`. `scripts/dispatch.sh` refuses to start a plan without one, names the
rule in the stop message, and prints the tier in the dispatch banner. Owner
override: a header line `# ALLOW-NO-TIER`.

## The tier table

| | Tier A | Tier B | Tier C |
|---|---|---|---|
| **Scope** | Money, identity, security, data retention | Traveller-facing product | Internal tooling and docs |
| **Critic set** | Domain critic + security-reviewer, plus api-critic when a contract changes | Domain critic, plus frontend-critic when a page changes | One critic |
| **Round cap** before a recorded merge-or-stop decision | 4 (proposal, owner confirmation pending) | 3 (proposal, owner confirmation pending) | 2 (owner decision 2026-09-14 10:25) |
| **Blocking finding** | Any correctness, security or contract finding | Any user-visible defect or contract drift | Only a finding that makes the tool wrong or misleading; everything else is filed as an issue |
| **Critic model tier** | Unchanged routing | Unchanged routing | Unchanged routing |

Notes:

- **Round cap** counts producer-critic rounds on one PR. At the cap the PR stops
  for a recorded merge-or-stop decision by a person; it does not keep cycling.
- **Blocking finding** is what a critic verdict of BLOCK-FIX may rest on. On
  Tier C anything softer (style, taste, nice-to-have) is filed as an issue and
  does not block the merge.
- **Critic model tier** is unchanged for every tier in this change: critic
  seats keep the routing in `config/routing.yaml`. A later change may route
  Tier C critics to cheaper models once the ledger shows it is safe.

## Exit test (from the proposal)

Over the test window: no Tier C PR goes past its round cap without a recorded
decision, and no Tier A PR merges with fewer critics than its tier requires.
