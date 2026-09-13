# Handoff — PR #2721 review fixes (branch `ci/e2e-aptget-hang`)

## Built

Commit `e7601354` on `ci/e2e-aptget-hang`, pushed; PR #2721 body updated in place. No new PR, no merge.

- `scripts/ci/install-playwright-deps.sh` — **one behavioural line**: `sudo pkill -KILL -f '/usr/lib/apt/methods'` added inside `reap_apt`, beside the existing apt-get pkills, guarded with `2>/dev/null || true`. Header worst-case bullets rewritten: the 149s figure is the *script's* runtime, and the step's runtime equals it only while every apt descendant is reaped.
- `.github/workflows/ci.yml` — **comment-only**. The download step's `~2.5 + 4 + 5 = ~11.5` corrected to the honest `2.5 + 4 + 3 + 5 = 14.5 > 12`, with why it rarely bites (fatal download step ends the job at ~6.5 min) and the realistic bad run (~11 min). The OS-deps step's "Worst case 149s" now states the helper-reap precondition. **No `timeout-minutes:` value changed** (`git diff -U0 | grep timeout-minutes` → comment lines only).

## Decisions (+why)

- **Reap, not redirect.** Redirecting the apt attempt away from the step pipe hides the survivor: the process keeps running with its sockets and apt locks into the next attempt and the rest of the job, and apt's output — the only diagnostic during a stall — is lost. Killing it removes the cause. One line, symmetric with its neighbours, no-op on a healthy run.
- **SIGKILL, no TERM first.** The helper is an orphan mid-fetch with nothing to clean up, and a TERM+sleep would add latency to a path that is already fighting a 31s slack.
- Did not touch the fatal browser-download step, the non-fatal design, the path filter, or the font-package finding.

## Evidence (measured, not read)

Repro: Ubuntu 24.04 container (`--cap-add=NET_ADMIN`), apt pointed at a black-holed mirror via `iptables -A OUTPUT -d 192.0.2.1 -j DROP` so `connect()` blocks for the kernel SYN-retransmit budget (`tcp_syn_retries=6` ≈ 127s — this is where the reviewer's ">122s" comes from). Stub `npx` spawns `sudo apt-get update` rather than exec-ing it, reproducing the CI topology. Harness runs the script with `2>&1 | cat` because a GH step's stdout *and* stderr are one pipe the runner reads to EOF; it timestamps script exit and pipe EOF to files (off-pipe). Scaled caps: 10s attempt, 2 attempts, 2s backoff → script worst case 26s instead of 149s.

```
########## BEFORE (HEAD~1 script) ##########
SCRIPT_EXIT rc=0 at t+26s
PIPE_EOF at t+149s                       <-- step still open 123s after the script exited
ps at t+60s:  1608  1  60 S /usr/lib/apt/methods/http
              1637  1  45 S /usr/lib/apt/methods/http

########## AFTER (patched script) ##########
SCRIPT_EXIT rc=0 at t+26s
PIPE_EOF at t+26s                        <-- pipe released with the script
ps at t+60s / t+200s: (none — nothing survived)
```

No-regression: healthy run vs a real mirror → `OS deps installed on attempt 1.`, exit and EOF both t+0s. Non-network failure (stub exits 1, reap matches nothing) → exit and EOF both t+6s.

Static: `bash -n` OK, `shellcheck` clean, `yaml.safe_load(ci.yml)` OK, `scripts/check-ci-job-wiring.py` → 25 jobs wired, 1 exempt.

## Do not repeat

- **Don't measure this with a tarpit** (a listener that accepts and never answers). On an *established* socket the helper notices its parent's death and exits within ~2s, and the bug looks unreproducible. The survivor only exists while the helper is blocked in `connect()` — you need a silent DROP.
- **Don't let the stub `npx` `exec` into apt-get,** and don't skip a process-group escape. GNU `timeout` signals the child's whole process group, so in a naive repro it kills the helper itself and the reap looks unnecessary. With reap disabled and no escape, nothing survived — that experiment is what proved the escape matters.
- **Don't pipe only stdout in a harness.** apt gives the fetch helper pipes to *itself* on fd 0/1; the step's descriptor it retains is fd 2. A stdout-only harness reports EOF at 26s and hides the bug.
- Don't `pkill -f '/usr/lib/apt/methods'` from a `bash -c` whose own cmdline contains that string — it kills your shell (exit 137). Put cleanup in a script file.

## Open questions / Next hint

- The 149s worst case is now honest *given* the reap. If a future apt version renames the methods dir, the pattern goes stale silently; a cheap follow-up would be to assert "no apt descendants remain" at script exit and warn if any do.
- `docker rm -f aptrepro` and `pkill -f tarpit.py` clean up the local repro.
