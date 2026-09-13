# Handoff: Wave 2 edge for Iris (#2340), on top of PR #2829

> **Second session, 2026-09-12: independent verification pass, no code changed.** Every claim below was re-proven from scratch (tests, vet, gofmt, critic file diff, overlay mutation, live smoke, spec section names, CI run 34712716026 success). Head is still `db8e1ba2`, local == remote, PR still a draft. The PR body gained an "Independent verification pass" section with the exit codes. The stale `irisbin` on 18082 and an `iris` on 8099 were killed; no Iris listener remains.

Branch `feat/ac-w2a-iris-scaffold`. PR #2829 is a DRAFT and must stay one. Four commits on top of `6d6cd12b` (the round-one head), see "Built".

## Built

| Item | Commit | Files |
|---|---|---|
| ONE, W1 challenge on the API assistant paths + the critic test verbatim | `558428a4` | `apps/api/internal/middleware/auth.go`, `assistant_challenge_test.go` (critic's, verbatim), `assistant_challenge_groups_test.go` (mine) |
| `client_id` claim on assistant tokens (needed by FIVE) | `b3474d16` | `apps/api/internal/service/auth.go`, `service/assistant_auth.go`, `service/assistant_client_claim_test.go`, `handler/assistant_oauth_critic_test.go` (mock signature) |
| TWO to SIX, the Iris edge | `612ae15b` | `services/iris/cmd/iris/{main.go,edge_test.go}`, `services/iris/internal/{token,mcp,tools,hostgate}` |
| README | `db8e1ba2` | `services/iris/README.md` |

## Decisions

- **The API challenge needs no new AuthOption.** It is derived from what the assistant groups already wire: `WithScopeAllowed(ScopeAssistant)` plus `WithAssistantAudience(uri)`. The critic's test passes exactly those three options and expects the header, so a new option would have failed it. Non-assistant groups get nothing (pinned by test).
- **Handler-emitted 401s on the OptionalAuth read group are covered by a writer wrapper**, not by teaching handlers about OAuth. `challengeWriter` forwards `Flush` and `Unwrap` exactly like `handler.scopedWriter` (the #784 SSE lesson).
- **Iris does NOT verify the signature.** HS256 with `JWT_SECRET` mints every web session; giving it to Iris would let a connector compromise forge full-access tokens. No introspection endpoint exists on the API. Iris copies the claim gate, forwards the token, and the API verifies on every downstream call. Stated in the README with the cost and the follow-up (`token.Gate` is the seam). Expect the security critic to probe this; the answer is in the README, "Bearer validation".
- **`client_id` was added to the token** because the kill switch is keyed by client id and the token is all a host sends. Two mint sites (code exchange, refresh) both had the id in hand.
- **Env var names:** `ASSISTANT_RESOURCE_URI` is the same name and value as the API's (the audience and the advertised `resource`), `IRIS_PUBLIC_URL` is new (needed for an absolute `resource_metadata` URL; not derived from the Host header), `OLYMPUS_WEB_URL` reuses the Hermes name, `IRIS_DENIED_HOSTS` is the reserved name from `env-vars-iris.md`, now read. `OLYMPUS_API_URL` is now read.
- **Stdlib only, still.** No `go.sum`, Dockerfile untouched, tests use `testing` only like the critic's B1 file.
- **The denied-host sentence** (`hostgate.DeniedSentence`, "Olympus is not available from this assistant right now.") is not among the ten accepted strings in PRD section 9. The task asked for a fixed sentence; it is proposed as S11 in the PR body, not silently shipped as ratified. Tool titles and descriptions are host-facing strings in the same position.
- **Not done, flagged:** rate limiting in the connector and `--concurrency` in the deploy (gating conditions in `env-vars-iris.md` "Why one instance"); the `env-vars-iris.md` and `.env.example` rows for the new env vars (devops-owned files; rows are drafted in the PR body); the `ASSISTANT_RESOURCE_URI` origin question (the API derives its AS `issuer` from it, so it cannot yet be the Iris URI a strict host might require `resource` to match).

## Do not repeat

- (Resolved in session two: both stale listeners killed.) **A stale `irisbin` process was listening on 18082** from an earlier session; my smoke binary failed to bind and every curl hit the old scaffold (404s, no `Cache-Control`). Check `lsof -nP -iTCP:<port> -sTCP:LISTEN` before reading smoke output. It was still running at handoff time; kill it if you need the port.
- Bash tool cwd persists across calls: after `cd apps/api` every later relative path is wrong. Use absolute paths.
- zsh: `${PIPESTATUS[0]}` is bash (`${pipestatus[1]}` works); capture exit codes without a pipe. `======` on a command line is parsed by zsh as an `=cmd` expansion. `--include=*.go` needs quotes under zsh.
- The `-overlay` mutation proof must also remove `assistant_challenge_groups_test.go` (it references `challengeWriter`), or the package fails to build instead of failing the test.
- Everything in the earlier handoff sections still holds (no `git reset --hard` with unrelated changes present; `/health` is canonical).

## Evidence

```
$ cd apps/api && go test -race -count=1 ./... && go vet ./...
24 packages ok, EXIT=0, VET_EXIT=0

$ go test -overlay=<original auth.go, groups test removed> -run TestAssistantChallengeCarriesResourceMetadataPointer ./internal/middleware/
--- FAIL (all four cases: "" does not contain "resource_metadata=")   MUTATION_EXIT=1

$ cd services/iris && GOWORK=off gofmt -l . && go vet ./... && go test -race -count=1 ./...
ok cmd/iris, internal/hostgate, internal/mcp, internal/token, internal/tools   EXIT=0

$ bash scripts/check-service-isolation.sh
services/iris: 10 Go file(s) scanned; no apps/api imports, no database drivers.   EXIT=0

$ live smoke on :18095 (see PR body): 401 + challenge with no bearer, 403 insufficient_scope on a concierge token,
  manifest annotations as specified, not_available on search and create_checkout, denied host B gets the fixed
  sentence twice and one host_denied log line, argument value "SECRET" absent from the log, GET /mcp 405 Allow: POST.

$ house style over committed diff and commit bodies: 0 long dashes, 0 " -- ", 0 vendor names, 0 trailers.
```

## Open questions

- Should `ASSISTANT_RESOURCE_URI` in prod become the Iris MCP URL? Some hosts require the PRM `resource` to match the server they talk to. Today the API derives its AS `issuer` from the same value, so that needs a separate issuer setting first. Not this PR.
- Who lands the introspection endpoint (or a separately keyed assistant signature) so Iris can verify a signature before the first forwarded call?

## Next hint

The next wave forwards `get_trip` / `list_trips` first (pure reads on the assistant read group): add `OLYMPUS_API_URL` client in `internal/olympus`, keep the token in the `Authorization` header as received, map the API's 401/403 to `token_revoked`, and close the signature gap above in the same PR.

---

# Handoff: docs and infra half of the round-two fixes (#2340, PR #2829), devops

Head after this pass: `650d97a19d6f451c7c13ce9f6d1ab41480e71cbd` (local == remote, pushed to `feat/ac-w2a-iris-scaffold`). One commit on top of `db8e1ba2`. PR still a draft. No Go file touched; the Go half of round two (B3 code side, F7, N1 placement, security N2) is still go-backend's.

## Built

| Item | Files |
|---|---|
| B3 / security N3: runbook table has a row for all seven vars `loadConfig` reads, "not yet" notes gone, bootstrap sets the four URLs with prod values, fail-closed statement for `IRIS_PUBLIC_URL` and `ASSISTANT_RESOURCE_URI` | `docs/operations/env-vars-iris.md` |
| `.env.example` mirrors every row with local defaults (`IRIS_SERVICE_TOKEN` kept as RESERVED, NOT READ, which is true) | `services/iris/.env.example` |
| N7: `.gitignore` in the devops bare-name list; comment states what the hook does and does not enforce | `scripts/hooks/scope-check.sh` |
| F5: the `services/` split sentence says the hook enforces the devops side only | `CLAUDE.md` (lines 72, 77) |
| N5: "both services" becomes "all four services" | `README.md` |
| F6: S11 in section 9, PROPOSED, exact `hostgate.DeniedSentence` text; heading and the "checked against voice" paragraph updated | `docs/prd/pages/assistant-channel.md` |
| Security N1 doc side: switch 2 is "front door only" until the API enforces the deny list | `env-vars-iris.md` switch 2, `services/iris/README.md` kill-switch paragraph |
| PR body: S11 bullet says it awaits co-founder sign-off; env var bullet marked done | PR #2829 body (gh pr edit) |

## Decisions

- Bootstrap sets exactly the four URLs. `PORT` is a Cloud Run reserved name (setting it is rejected), `ENVIRONMENT` is passed by `deploy-iris.yml` on every deploy, `IRIS_DENIED_HOSTS` is the kill switch and stays unset. The bootstrap block says so in comments so "sets all of them" is verifiable against the table.
- `IRIS_PUBLIC_URL` prod value `https://olympus-iris-964499096147.europe-north1.run.app`: deterministic from the project number, same shape as the Hermes URL already in the runbooks. Not verified against a live service (none exists yet).
- The fail-closed statement is written as the contract the code must meet, naming the acceptance check (production-shaped boot with only `OLYMPUS_API_URL` and `ASSISTANT_RESOURCE_URI` set, 401 never names localhost). Today's `loadConfig` still falls back to localhost; the code half of Wave 2 closes that.
- Did NOT add `IRIS_PUBLIC_URL` to `deploy-iris.yml --update-env-vars` (the critic's "cleaner option"). The task chose the bootstrap route. Open question below.
- Did NOT anchor the hook matcher to basename (security addendum LOW). `cloudbuild` relies on prefix matching, so it is a deliberate change to every bare-name entry; the comment now records the gap instead of claiming it closed.
- Kill-switch wording is "every tool call (`tools/call`)" everywhere, not "every request" (critic N1), and makes no claim about `initialize` / `tools/list` so it stays true whether or not go-backend moves the check above the method switch.

## Do not repeat

- `Write`/`Edit` tools refuse files only seen via `cat`; a python script with `assert count == 1` replacements is the reliable route under bypass mode.
- Running the critic's Go test without committing it: `go test -overlay overlay.json` with `{"Replace":{"<abs>/services/iris/cmd/iris/zz_x_test.go":"/tmp/x_test.go"}}`; the test's relative `../../.env.example` paths resolve from the package dir. Leaves the tree clean.
- The vendor-name scan over the diff hits `claude --agent`, `CLAUDE.md` and `.claude/`: those are the repo's own literal command and file names in lines that already existed. Do not "fix" them.

## Evidence

```
$ make check-prd-index                                  EXIT=0 (32 pages, 38 links, self-test OK)
$ CLAUDE_AGENT=devops scope-check.sh services/iris/.gitignore        exit=0
$ CLAUDE_AGENT=devops scope-check.sh services/hermes/.gitignore      exit=0
$ CLAUDE_AGENT=devops scope-check.sh services/iris/.dockerignore     exit=0
$ CLAUDE_AGENT=devops scope-check.sh services/iris/cmd/iris/main.go  exit=2
$ CLAUDE_AGENT=devops scope-check.sh services/iris/go.mod            exit=2
$ bash -n scripts/hooks/scope-check.sh && shellcheck scripts/hooks/scope-check.sh   both clean
$ go test -overlay ... -run TestEveryEnvVarReadIsDocumented ./cmd/iris   exit=0 (7/7 PASS, critic's test verbatim)
$ git diff -U0 | grep '^+' | grep -P '\x{2014}|\x{2013}|\x{2015}| -- '   no matches (exit 1)
commit 650d97a1, pushed; remote == local
```

## Open questions

- Boot-refusal or serve-refusal for a missing `IRIS_PUBLIC_URL` in production? If go-backend makes `loadConfig` refuse to boot, the first CI deploy (which runs before the bootstrap) fails its `/health` smoke, and `deploy-iris.yml` must pass `IRIS_PUBLIC_URL` alongside `ENVIRONMENT`. The runbook's "boots with none of this set" sentence assumes serve-refusal. Decide together.
- S11 needs co-founder sign-off (Arlen and/or Spilios) before it is accepted copy. If rejected, `mcp.go` passes an empty text block and `TestKillSwitch` changes one line.
- Hook matcher basename anchoring (security addendum LOW): own change, own PR.

---

# Handoff: round-three Go half (#2340, PR #2829), go-backend

Head after this pass: `c4dcd334` (pushed to `feat/ac-w2a-iris-scaffold`). Three commits on top of the devops head `650d97a1`. PR still a draft. Only `apps/api/` and `services/iris/` Go files touched.

## Built

| Item | Commit | Files |
|---|---|---|
| ONE (critic F7) + THREE (critic B3 code side) | `03fa50d0` | `services/iris/cmd/iris/main.go`, `edge_test.go`, `issuer_parity_test.go` (critic's, verbatim), `envdoc_test.go` (critic's, verbatim) |
| TWO edge half (critic N1, N4) + FOUR (security N2) + SIX (critic N3) | `923782bb` | `services/iris/internal/{hostgate,token,mcp}` |
| TWO API half (security N1) | `c4dcd334` | `apps/api/internal/middleware/auth.go` (+ `assistant_denied_clients_test.go`, mock gains `clientID`), `service/assistant_auth.go`, `service/auth.go`, `handler/assistant_oauth.go` (error mapping + shared-rule paragraph on `assistantMetadataOrigin`), `handler/routes.go`, `config/config.go`, `cmd/server/main.go`, `handler/hermes_scope_enforcement_test.go` (assistant tokens carry `client_id`; fixture takes config mutators; router wiring test) |

## Decisions

- **Issuer parity is a boot step, not a `loadConfig` rule.** The critic's `issuer_parity_test.go` builds a mux from divergent `OLYMPUS_API_URL` / `ASSISTANT_RESOURCE_URI` and fatals if `loadConfig` errors, so the refusal lives in `checkIssuerParity`, called from `main` right after `loadConfig`, in every environment. Compared as origins (scheme://host), so a path on `OLYMPUS_API_URL` does not trip it.
- **The critic's `production_pointer_test.go` is NOT added.** It fatals on a `loadConfig` error for the incomplete bootstrap env, which only passes if the deploy injects `IRIS_PUBLIC_URL`. The task chose fail-closed at boot, so the acceptance check is `TestProductionEdgeNeverPointsAtLocalhost` (same intent, fail-closed shape). Say so if the critic asks.
- **Two refusal shapes at the edge for a cut host.** `tools/call` keeps `not_available` + the S11 sentence (PRD section 9 PROPOSED row stays true); every other method is 403 `insufficient_scope` with the challenge, the API's own verdict for that token. Cutting `tools/call` to a 403 too would have orphaned S11 in the PRD, which is not go-backend's to edit.
- **Missing `client_id` is 401 `invalid_token`, not 403**, on both sides: a refresh re-mints with the claim, so the host should refresh, not ask for more scope. The deny-list hit itself is 403 `insufficient_scope` as the task specified.
- **Alert map keyed by client id** (security's own suggestion): bounded by the deny list by construction, no LRU or bucket needed. `ShouldLog` also returns false for an id that is not denied, so misuse cannot regrow the map.
- **`Refresh` refuses but does not revoke the family**: the switch is a lever that may be lifted. `ExchangeCode` and `/authorize` are not gated (task said `Refresh`); a fresh grant for a cut host would only mint tokens the middleware refuses.
- **Origin 403 keeps no challenge** (SIX, README route). Reason at the check in `mcp.go`, pinned by test; the README sentence is below for devops.

## Notes for devops / the orchestrator (one line each, drafted)

1. `docs/operations/env-vars-api.md`: add the row; until then `scripts/check-env-vars.py` fails on this branch (`make lint`, CI `check-env-vars`). Draft: `| \`ASSISTANT_DENIED_CLIENTS\` | *(empty, no host denied)* | Per-host kill switch for the assistant channel (security round two of PR #2829, N1): comma-separated OAuth client ids, the same values as the \`ASSISTANT_OAUTH_CLIENT_*_ID\` slots, parsed like \`CORS_ALLOWED_ORIGINS\`. A listed host's assistant tokens are refused 403 \`insufficient_scope\` on every assistant path (\`middleware.WithAssistantDeniedClients\`, before any binding I/O, logged as \`event=assistant.client_denied\`) and its refresh grants are refused \`invalid_grant\` at \`/oauth/assistant/token\`; the other host is untouched (D4). Mirrors the connector's \`IRIS_DENIED_HOSTS\`; set both. A change needs a new revision. **Unset:** no host is denied. |`
2. `scripts/check-service-isolation.sh` (critic N2, FIVE): go-backend is hook-blocked on `scripts/`. Draft: extend `DB_GO_PATTERN` and `DB_GOMOD_PATTERN` with `github\.com/go-pg/pg|github\.com/uptrace/bun|gorm\.io|github\.com/jmoiron/sqlx|entgo\.io/ent|github\.com/go-sql-driver/mysql|modernc\.org/sqlite|github\.com/mattn/go-sqlite3`, add a go-pg fixture to the self-test, and add a fourth check that runs `go list -deps -f '{{if not .Standard}}{{.ImportPath}}{{end}}' ./...` per service (GOWORK=off) against the same pattern so a wrapper library that imports a driver transitively is caught too.
3. `services/iris/README.md` (critic N3, SIX): under the transport rules, add: "A request carrying an `Origin` other than `IRIS_PUBLIC_URL` is refused 403 before authentication and without a `WWW-Authenticate` challenge: the check is the DNS-rebinding defence the transport spec requires, no credential can satisfy it, and a challenge would only send a browser-hosted client through discovery and re-authorization to be refused again. Server-side hosts send no `Origin`; a browser-hosted host cannot connect, which the pilot host docs must state before a host is pointed here."
4. `env-vars-iris.md` "boots with none of this set" (line ~114) is no longer true in production: decide between passing `IRIS_PUBLIC_URL` and `ASSISTANT_RESOURCE_URI` in `deploy-iris.yml --update-env-vars` (the critic's cleaner option) or bootstrapping on the first `gcloud run deploy`. Also: switch 2 text "every tool call" can become "every request"; "front door only" retires once `ASSISTANT_DENIED_CLIENTS` is set on `olympus-api`; the README kill-switch paragraph likewise, and "once per binding per hour" becomes "once per host per hour".

## Do not repeat

- The scope hook is a tool hook, not a git hook: `.git/hooks` has only `commit-msg` and `pre-push`. Simulate with the JSON-on-stdin form to know before editing.
- Python f-strings cannot hold Go struct literals (`{{"..."}}` with inner quotes): use a placeholder + `.replace`.
- The Hermes scope fixture's audience is a `urn:` value, so `newAssistantChallenge` emits no header there; assert on status and body in that fixture, the header shape belongs in the middleware tests.
- After `cd apps/api` in one Bash call the cwd persists; the env gate and the isolation script then fail with "no such file". Absolute paths.

## Evidence

```
apps/api:      go vet 0; go test -race ./... 0 (24 ok); golangci-lint 0 issues
services/iris: gofmt clean; go vet 0; go test -race ./... 0 (5 ok)
critic tests:  issuer_parity_test.go and envdoc_test.go byte-identical to the comment (diff exit 0), both PASS
mutation:      go test -overlay=<650d97a1 main.go + edge_test.go> -run TestCriticW2A_AuthorizationServerMatchesTheAPIIssuer -> FAIL, exit 1
gates:         check-service-isolation 0 (36 files); make check-api-spec 0; check-env-vars 1 (ASSISTANT_DENIED_CLIENTS, expected until the doc row)
house style:   0 long dashes / " -- " / vendor names / trailers in the three commits
```

## Open questions

- Should `ExchangeCode` (and `/authorize`) also refuse a denied client, so a traveller cannot connect a cut host at all? One more `s.denied[...]` line; it changes the consent-screen outcome, so it wants a PRD look first.
- Once the API enforces the list, is `IRIS_DENIED_HOSTS` still worth keeping as a separate value, or should Iris read `ASSISTANT_DENIED_CLIENTS` under the same name to remove one more pair of values that must agree (the F7 lesson)?

## Next hint

The first forwarded call (`get_trip` / `list_trips`): with `client_id` now mandatory on both sides, the forward path can log `claims_verified=false` on the edge line and `true` after the API answers, closing security N4's suggestion in the same PR as the `internal/olympus` client.
