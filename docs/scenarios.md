# Agent Scenarios

Real-world examples of how to use dev-agents in different situations.

---

## Scenario 1: Solo Developer — Fix a Bug

You found a bug. You know exactly what's wrong. Go direct.

```
You ──► go-backend ──► Fix + PR ──► Merge
         (single terminal, ~5 min)
```

```bash
claude --agent go-backend "fix the null pointer in auth.go line 45"
```

No orchestrator needed. One agent, one branch, done.

---

## Scenario 2: Feature Request — "Add User Settings Page"

Touches backend + frontend + database. Start with orchestrator.

```
You ──► Orchestrator
             │
             ├──► "This needs 3 agents in 2 waves"
             │
             │    Wave 1 (parallel)
             │    ├── db-architect: settings migration
             │    └── api-designer: PATCH /users/settings endpoint
             │
             │    Wave 2 (after Wave 1 merges)
             │    ├── go-backend: settings service + handler
             │    └── web-frontend: settings page UI
             │
             └──► "Don't forget: test-engineer should add coverage after"
```

```bash
# Step 1
claude --agent orchestrator "we need a user settings page"

# Step 2: Wave 1
claude --agent db-architect "create settings migration"        # Terminal 1
claude --agent api-designer "add settings endpoints to spec"   # Terminal 2

# Merge Wave 1, then Step 3: Wave 2
claude --agent go-backend "implement settings service"         # Terminal 1
claude --agent web-frontend "build settings page"              # Terminal 2
```

---

## Scenario 3: Sprint Planning — "What Should We Work on This Week?"

Let the orchestrator analyze your backlog.

```
You ──► Orchestrator
             │
             ├──► Reads open GitHub issues
             ├──► Reads CLAUDE.md for priorities
             ├──► Reads recent git history
             │
             └──► "Here's what I recommend:
                   Priority 1: #301 (Duffel booking) — assign to BK
                   Priority 2: #43-47 (mobile) — 5 issues, Wave A
                   Priority 3: #226 (GitHub OAuth) — go-backend, small

                   You can run #226 + #43 in parallel.
                   #301 is BK's — don't touch it."
```

```bash
claude --agent orchestrator "what should we work on this week? check open issues"
```

---

## Scenario 4: Multi-Machine Parallel — "Ship the Mobile App"

Big feature across your MacBook Pro + 2 Mac Minis.

```
┌─────────────────┐
│  MacBook Pro     │
│  (You)           │
│                  │
│  Orchestrator:   │
│  "Mobile needs   │
│   5 tasks in     │
│   3 waves"       │──── dispatch ────┐────────────────┐
│                  │                  │                │
│  Also running:   │                  ▼                ▼
│  security-review │  ┌───────────────────┐ ┌──────────────────┐
│  (reviews PRs    │  │  Mac Mini 1       │ │  Mac Mini 2      │
│   as they come)  │  │                   │ │                  │
└─────────────────┘  │  go-backend:      │ │  mobile:         │
                      │  "API endpoints   │ │  "scaffold Expo  │
                      │   for mobile"     │ │   project"       │
                      │                   │ │                  │
                      │  Then:            │ │  Then:           │
                      │  go-backend:      │ │  mobile:         │
                      │  "push notif      │ │  "auth screens + │
                      │   service"        │ │   search flows"  │
                      └───────────────────┘ └──────────────────┘
                               │                     │
                               └──────┬──────────────┘
                                      ▼
                                ┌───────────┐
                                │  GitHub   │
                                │  6 PRs    │
                                └─────┬─────┘
                                      │
                                      ▼
                                MacBook Pro
                                reviews + merges
```

```bash
# From MacBook Pro
./scripts/run-remote.sh mac-mini-1 git@github.com:Arlencho/olympus-platform.git go-backend "add mobile API endpoints"
./scripts/run-remote.sh mac-mini-2 git@github.com:Arlencho/olympus-platform.git mobile "scaffold Expo project"

# Meanwhile, on MacBook Pro
claude --agent security-reviewer "review incoming PRs for security"
```

---

## Scenario 5: Pre-Launch Audit — "Are We Ready?"

Before a demo or launch, run the review agents.

```
You ──► security-reviewer ──► "Found 3 issues:
             │                  HIGH: raw err.Error() in payment handler
             │                  MEDIUM: no rate limit on webhook endpoint
             │                  LOW: bcrypt cost is 10, recommend 12"
             │
        seo-auditor ──► "Found 5 issues:
             │            HIGH: checkout page missing meta description
             │            MEDIUM: no OG image on booking confirmation
             │            LOW: sitemap.xml doesn't include /activities"
             │
        tech-scout ──► "Claude Code v4.2 released yesterday:
                         - New --background flag for agent execution
                         - Could replace our run-remote.sh script
                         - Effort: small, Impact: high"
```

```bash
claude --agent security-reviewer "full security audit before London demo"
claude --agent seo-auditor "audit all public pages"
claude --agent tech-scout "any recent releases we should adopt before launch?"
```

---

## Scenario 6: New Project — "Start a New SaaS from Scratch"

Scaffold, plan, and start building in one session.

```
./scripts/new-project.sh go-nextjs my-saas
         │
         ├──► Creates repo structure
         ├──► Adds CLAUDE.md from template
         └──► Ready for agents

cd my-saas
claude --agent orchestrator "plan the initial sprint — we need auth, landing page, and Stripe billing"
         │
         └──► Wave 1: db-architect (users table) + api-designer (spec)
              Wave 2: go-backend (auth + billing) + web-frontend (landing + login)
              Wave 3: test-engineer (coverage) + devops (CI + deploy)
```

```bash
./scripts/new-project.sh go-nextjs my-saas
cd my-saas
gh repo create Arlencho/my-saas --private --source=. --push
claude --agent orchestrator "plan initial sprint: auth, landing page, Stripe billing"
```

---

## Scenario 7: "I Don't Know Where to Start"

This is exactly what the orchestrator is for.

```
You: "The app is slow and users are complaining"

Orchestrator ──► Reads codebase, checks issues, analyzes
                  │
                  └──► "Here's what I'd investigate:
                        1. go-backend: check N+1 queries in booking list
                        2. web-frontend: audit bundle size + lazy loading
                        3. devops: check Cloud Run instance config + cold starts

                        Start with go-backend — that's usually where
                        API slowness lives. web-frontend can run in parallel.
                        devops is independent.

                        Want me to create a wave plan?"
```

```bash
claude --agent orchestrator "the app is slow, users are complaining, help me figure out what to do"
```

The orchestrator doesn't just route — it **thinks with you**.
