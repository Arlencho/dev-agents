# Local PR Sentinel — User Guide

**Purpose**: A zero-extra-token-cost background agent that discovers and routes un-attached PRs (dependabot, external contributions, board-filed work, etc.) so they don't fall through the cracks.

It replaces (or augments) the expensive Paperclip PR Sentinel heartbeat while preserving the high-quality producer-critic + Security + CTO process defined in `roles/pr-sentinel.md`.

---

## Quick Start

```bash
# See what it would do right now (safe)
make local-sentinel-dry

# Run it once for real
make local-sentinel

# Install as a background service (runs every 30 min automatically)
make local-sentinel-install

# Check if the background service is running
make local-sentinel-status

# Watch the logs
make local-sentinel-logs

# Overall fleet health (recommended daily command)
make fleet-status
```

---

## Installation as Background Service

The recommended way to run the Local Sentinel autonomously is via macOS `launchd`.

```bash
make local-sentinel-install
```

This does:
- Copies the launchd plist to `~/Library/LaunchAgents/`
- Loads the job so it starts automatically
- The sentinel will now run every **30 minutes** in the background

**Useful commands after installation:**

```bash
make local-sentinel-status      # Is it loaded?
make local-sentinel-logs        # Tail the log file
make local-sentinel-uninstall   # Remove the background service
```

**Log location**: `~/Library/Logs/local-pr-sentinel.log`

---

## What the Sentinel Does

Every run it performs (in order):

1. **Main triage** — Scans open PRs targeting `main` and routes unattached ones according to branch prefix:
   - `dependabot/*` → DevOps Engineer (light review)
   - `feat/*`, `fix/*` → CTO (full producer-critic + Security + CTO chain)
   - `docs/*` → Docs Writer + Maintainability Reviewer
   - Everything else → CTO with extra security scrutiny

2. **Self-author block** — Detects PRs authored by `Arlencho` that already have verdict comments and prevents duplicate routing.

3. **Draft auto-flip** — Finds draft PRs on `task/*` branches whose parent Paperclip task has moved to `in_review` + CI is green, then flips them ready and files a CTO Loop 1 task.

4. **BLOCK-FIX re-route** — Detects PRs that received a `BLOCK-FIX` and later received new commits, then files the appropriate CTO re-review task (with 24h bound protection).

5. **Merge Queue Digest** — Updates the rolling "Merge Queue Digest — Olympus" issue with the current state of the board.

6. **Activity Log** — Records a structured scan summary (visible via the "Local PR Sentinel - Activity Log" Paperclip issue or in the console).

---

## Monitoring

### Recommended Daily Command

```bash
make fleet-status
```

This shows in one place:
- Whether Paperclip is running
- Which expensive agents have heartbeat ON (these cost tokens)
- Local Ollama / `olympus-coder` health
- **Local Sentinel Health** (one-line summary with last run age + recent errors + launchd status)
- Last Local Sentinel run + counters
- Status of the Merge Queue Digest

### Key Counters (in the scan summary)

These are now tracked accurately and appear in the structured scan report:

| Counter                | Meaning |
|------------------------|---------|
| `prs_scanned`          | Total open PRs examined this run |
| `tasks_filed`          | How many new routing tasks were created in Paperclip |
| `self_author_blocked`  | PRs skipped because they were authored by the reviewer account and already had a verdict |
| `drafts_flipped`       | Draft PRs that were automatically marked ready + had a CTO Loop 1 task filed |
| `blockfix_filed`       | Re-review tasks filed after a producer pushed fixes on a BLOCK-FIX'd PR |
| `anomalies`            | Interesting edge cases flagged (self-author, bound hits, stale PRs, etc.) |

These numbers are also written to `logs/local-sentinel-status.json` so `make fleet-status` can display a summary.

Errors are now stored as rich objects (`timestamp`, `message`, `category`), making debugging much easier.

**Tip**: After a run, look at the end of the console output or the "Local PR Sentinel - Activity Log" issue in Paperclip for the full structured summary (including categorized errors).

---

## Output & Where to Look

| What | Where to find it |
|------|------------------|
| Scan summary (structured) | Printed at the end of every run + appended to "Local PR Sentinel - Activity Log" issue in Paperclip |
| Merge Queue Digest | Paperclip issue titled **"Merge Queue Digest — Olympus"** |
| Detailed logs | `~/Library/Logs/local-pr-sentinel.log` |
| Current state | `make fleet-status` and `logs/local-sentinel-status.json` |

---

## Relationship to the Original Paperclip Sentinel

| Aspect | Paperclip PR Sentinel | Local PR Sentinel |
|--------|-----------------------|-------------------|
| Cost | Expensive (Sonnet/Opus heartbeat) | Free (local `olympus-coder`) |
| Always-on | Risky (see May 2026 cost incident) | Designed for it |
| Model | Frontier model | Local 14B specialist |
| Governance | Full Paperclip agent | Same routing rules, lighter runtime |
| Recommended use | High-value work | Discovery + routing only |

**Best practice**: Run the Local Sentinel in the background for discovery. Only wake expensive frontier agents (via `make paperclip-agent-on`) when there is real work to do.

---

## Troubleshooting

**"No CTO agent ID available"**
- Paperclip is not running or the CTO agent is not hired in the Olympus company.
- The script gracefully degrades.

**Service not starting after `make local-sentinel-install`**
```bash
make local-sentinel-status
launchctl list | grep local-pr-sentinel
tail -50 ~/Library/Logs/local-pr-sentinel.log
```

**Too many tasks being filed**
- Review the Activity Log issue in Paperclip.
- You can temporarily run with `--dry-run` or unload the service:
  ```bash
  make local-sentinel-uninstall
  ```

---

## Development / Testing

```bash
# Safe dry run (never touches Paperclip or GitHub)
make local-sentinel-dry

# Real run (will file tasks if Paperclip is up)
make local-sentinel
```

When developing changes to the sentinel logic, always test with `--dry-run` first.

---

## Philosophy

The Local PR Sentinel embodies the hybrid model used on Olympus:

- **Cheap, always-on discovery** → Local models
- **High-quality execution** → Frontier models (Grok + selective Claude) orchestrated with strict producer-critic discipline
- **Governance & visibility** → Paperclip as the board + audit layer
- **Human in the loop at the top** → You (via `make fleet-status` and the Merge Queue Digest)

This combination gives high autonomy at dramatically lower cost and with strong quality controls.

---

*Last updated: 2026-05-23*
