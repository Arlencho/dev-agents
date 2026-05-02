# Issue Lifecycle — Status Transitions

Every agent must move issues through the correct status as they work. This is not optional — the project board is how the team tracks progress.

## Statuses

```
Todo → In Progress → In Review → QA → Done
                                        ↑
                          Blocked ──────┘
```

| Status | Meaning | Who sets it |
|--------|---------|-------------|
| **Todo** | Not started | Default when created |
| **In Progress** | Agent or human actively working on it | Agent at start of work |
| **In Review** | PR created, waiting for CI or human review | Agent after pushing PR |
| **QA** | Code merged, needs manual verification or smoke test | Agent or human after merge |
| **Done** | Verified working in production | Human after verification |
| **Blocked** | Cannot proceed — dependency, question, or external blocker | Anyone who hits a wall |

## Agent Responsibilities

### When you START working on an issue:
```bash
# Move to "In Progress"
gh issue edit <NUMBER> -R <owner>/<repo> --add-label "status:in-progress"
```
Also comment: "Starting work on this."

### When you CREATE a PR:
```bash
# Move to "In Review"
gh issue edit <NUMBER> -R <owner>/<repo> --add-label "status:in-review"
```
The PR body should reference: `Closes #NUMBER`

### When PR is MERGED:
```bash
# Move to "QA"
gh issue edit <NUMBER> -R <owner>/<repo> --add-label "status:qa"
```
Comment: "Merged and deployed. Needs verification: [describe what to check]"

### When VERIFIED in production:
```bash
# Move to "Done" — human does this after verifying
gh issue close <NUMBER> -R <owner>/<repo>
```

### When BLOCKED:
```bash
gh issue edit <NUMBER> -R <owner>/<repo> --add-label "status:blocked"
```
Comment: "Blocked by: [reason]. Waiting on: [what/who]"

## Rules

1. **Never skip statuses** — Todo → Done is not allowed. Every issue goes through In Progress → In Review → QA.
2. **Never close without QA** — merged code must be verified before marking Done.
3. **Always comment on transitions** — say what you did and what's next.
4. **Blocked issues need a reason** — don't just set blocked, explain why.
5. **The orchestrator tracks status** — it reads the board to know what to assign next.

## For the Orchestrator

Check progress by status:
```bash
# What's in progress right now?
gh issue list -R <owner>/<repo> --label "status:in-progress"

# What's waiting for review?
gh issue list -R <owner>/<repo> --label "status:in-review"

# What's merged but needs QA?
gh issue list -R <owner>/<repo> --label "status:qa"

# What's blocked?
gh issue list -R <owner>/<repo> --label "status:blocked"
```
