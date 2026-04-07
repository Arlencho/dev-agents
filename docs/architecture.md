# Dev Agents Architecture

## Single Machine — Parallel Agents

When running on one machine (e.g., your MacBook Pro), agents run as parallel processes in separate terminals or as background tasks within a single Claude Code session.

```
┌─────────────────────────────────────────────────────────┐
│                    MacBook Pro                           │
│                                                         │
│  ┌─────────────┐                                        │
│  │ You (CTO)   │                                        │
│  │             │── "I need to add payments"              │
│  └──────┬──────┘                                        │
│         │                                               │
│         ▼                                               │
│  ┌─────────────────┐                                    │
│  │  Orchestrator    │  Analyzes → Plans → Assigns       │
│  │  (tech lead)     │  "Wave 1: db + api spec           │
│  │                  │   Wave 2: backend                  │
│  │                  │   Wave 3: frontend + tests"        │
│  └────────┬─────────┘                                   │
│           │                                             │
│           │ Wave 1 (parallel)                           │
│           ├──────────────────┬──────────────────┐       │
│           ▼                  ▼                  ▼       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ db-architect  │  │ api-designer │  │   devops     │  │
│  │ Terminal 1    │  │ Terminal 2   │  │ Terminal 3   │  │
│  │              │  │              │  │              │  │
│  │ branch:      │  │ branch:      │  │ branch:      │  │
│  │ feat/pay-db  │  │ feat/pay-api │  │ feat/pay-ci  │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                 │                 │           │
│         └────────┬────────┘─────────────────┘           │
│                  ▼                                      │
│           Merge to main                                 │
│           (api spec first, then db, then ci)            │
│                  │                                      │
│           │ Wave 2 (parallel)                           │
│           ├──────────────────┬──────────────────┐       │
│           ▼                  ▼                  ▼       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ go-backend   │  │ web-frontend │  │test-engineer │  │
│  │ Terminal 1   │  │ Terminal 2   │  │ Terminal 3   │  │
│  │              │  │              │  │              │  │
│  │ branch:      │  │ branch:      │  │ branch:      │  │
│  │ feat/pay-svc │  │ feat/pay-ui  │  │ feat/pay-tst │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                 │                 │           │
│         └────────┬────────┘─────────────────┘           │
│                  ▼                                      │
│           Merge to main                                 │
│           (backend first, then frontend, tests last)    │
│                  │                                      │
│                  ▼                                      │
│  ┌──────────────────┐  ┌──────────────────┐             │
│  │security-reviewer │  │   seo-auditor    │             │
│  │ "Review payment  │  │ "Audit checkout  │             │
│  │  code for vulns" │  │  page for SEO"   │             │
│  └──────────────────┘  └──────────────────┘             │
│                                                         │
│  ┌──────────────────┐                                   │
│  │   tech-scout     │  (runs weekly, independent)       │
│  │ "Any new Claude  │                                   │
│  │  Code features?" │                                   │
│  └──────────────────┘                                   │
│                                                         │
└─────────────────────────────────────────────────────────┘
                         │
                         ▼
                   ┌───────────┐
                   │  GitHub   │  PRs, CI, merge
                   │  (remote) │
                   └─────┬─────┘
                         │
                    ┌────┴────┐
                    ▼         ▼
              ┌──────────┐ ┌──────────┐
              │ Cloud Run│ │  Vercel  │
              │ (Go API) │ │  (Web)   │
              └──────────┘ └──────────┘
```

---

## Multi-Machine — Distributed Agents

When running across your MacBook Pro + 2 Mac Minis, the MacBook acts as orchestrator and the Mac Minis execute agents in parallel.

```
                    ┌──────────────────────────────────────┐
                    │          MacBook Pro (You)            │
                    │                                      │
                    │  ┌─────────────┐                     │
                    │  │ You (CTO)   │                     │
                    │  └──────┬──────┘                     │
                    │         │                            │
                    │         ▼                            │
                    │  ┌─────────────────┐                 │
                    │  │  Orchestrator    │                 │
                    │  │  Plans waves,    │                 │
                    │  │  dispatches to   │                 │
                    │  │  machines        │                 │
                    │  └────────┬─────────┘                │
                    │           │                          │
                    │  Also runs locally:                  │
                    │  ┌──────────────────┐                │
                    │  │security-reviewer │ (reviews PRs)  │
                    │  │seo-auditor       │ (audits pages) │
                    │  │tech-scout        │ (weekly scan)  │
                    │  └──────────────────┘                │
                    │                                      │
                    └──────────┬───────────────────────────┘
                               │
                    ┌──────────┼───────────┐
                    │          │           │
          SSH + run-remote.sh  │  SSH + run-remote.sh
                    │          │           │
                    ▼          │           ▼
┌───────────────────────┐     │    ┌───────────────────────┐
│     Mac Mini 1        │     │    │     Mac Mini 2        │
│     (Backend)         │     │    │     (Frontend)        │
│                       │     │    │                       │
│  ┌──────────────┐     │     │    │  ┌──────────────┐     │
│  │ go-backend   │     │     │    │  │ web-frontend │     │
│  │              │     │     │    │  │              │     │
│  │ branch:      │     │     │    │  │ branch:      │     │
│  │ feat/pay-svc │     │     │    │  │ feat/pay-ui  │     │
│  └──────────────┘     │     │    │  └──────────────┘     │
│                       │     │    │                       │
│  ┌──────────────┐     │     │    │  ┌──────────────┐     │
│  │ db-architect │     │     │    │  │   mobile     │     │
│  │              │     │     │    │  │              │     │
│  │ branch:      │     │     │    │  │ branch:      │     │
│  │ feat/pay-db  │     │     │    │  │ feat/pay-mob │     │
│  └──────────────┘     │     │    │  └──────────────┘     │
│                       │     │    │                       │
│  ~/.claude/agents/ ──►│     │    │◄── ~/.claude/agents/  │
│  (symlinked from      │     │    │  (symlinked from      │
│   dev-agents repo)    │     │    │   dev-agents repo)    │
│                       │     │    │                       │
└───────────┬───────────┘     │    └───────────┬───────────┘
            │                 │                │
            │     ┌───────────┴──────────┐     │
            │     │                      │     │
            └────►│       GitHub         │◄────┘
                  │                      │
                  │  PRs from all 3      │
                  │  machines merge      │
                  │  to main             │
                  │                      │
                  └──────────┬───────────┘
                             │
                        ┌────┴────┐
                        ▼         ▼
                  ┌──────────┐ ┌──────────┐
                  │ Cloud Run│ │  Vercel  │
                  │ (Go API) │ │  (Web)   │
                  └──────────┘ └──────────┘
```

---

## Setup Per Machine

```
┌─────────────────────────────────────────────────────┐
│                   Any Machine                        │
│                                                     │
│  1. git clone dev-agents                            │
│  2. ./scripts/bootstrap.sh claude                   │
│     │                                               │
│     └──► Symlinks agents to ~/.claude/agents/       │
│          ├── go-backend.md ──► roles/go-backend.md  │
│          ├── web-frontend.md                        │
│          ├── orchestrator.md                        │
│          ├── ... (11 agents total)                  │
│          └── seo-auditor.md                         │
│                                                     │
│  3. git clone <project-repo>                        │
│  4. claude --agent <role> "task"                    │
│                                                     │
│  Updating agents:                                   │
│  cd dev-agents && git pull                          │
│  (symlinks auto-update — no re-bootstrap needed)    │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## Agent Communication Flow

Agents don't talk to each other directly. They communicate through **git**:

```
  Agent A                    Git (main)                  Agent B
  (go-backend)                                          (web-frontend)
     │                          │                          │
     │── commit + push ────────►│                          │
     │                          │                          │
     │                          │◄──── pull + rebase ──────│
     │                          │                          │
     │                          │── commit + push ────────►│
     │                          │                          │
```

The orchestrator coordinates **timing** (wave order) and **scope** (which files each agent touches). It doesn't relay messages between agents.

---

## Your Setup

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  MacBook Pro     │     │   Mac Mini 1     │     │   Mac Mini 2     │
│                  │     │                  │     │                  │
│  Role:           │     │  Role:           │     │  Role:           │
│  Orchestrator    │     │  Backend work    │     │  Frontend work   │
│  + Reviews       │     │                  │     │                  │
│  + Merges        │     │  Agents:         │     │  Agents:         │
│                  │     │  go-backend      │     │  web-frontend    │
│  Agents:         │     │  db-architect    │     │  mobile          │
│  orchestrator    │     │  api-designer    │     │  seo-auditor     │
│  security-review │     │  devops          │     │  test-engineer   │
│  tech-scout      │     │                  │     │                  │
│                  │◄───►│                  │◄───►│                  │
│  SSH dispatch    │     │  SSH receive     │     │  SSH receive     │
│                  │     │                  │     │                  │
└──────────────────┘     └──────────────────┘     └──────────────────┘
         │                       │                        │
         └───────────────┬───────┘────────────────────────┘
                         ▼
                   ┌───────────┐
                   │  GitHub   │
                   └───────────┘
```
