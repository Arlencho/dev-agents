# Handoff: feat/ac-two-hosts, service half of #2825 (go-backend)

Branch `feat/ac-two-hosts`, head `b709b7ab` on top of db-architect's `62f51ebd`. Draft PR #2835, Closes #2825, Refs #2800, #2340. Pushed, not merged.

## Built

All under `apps/api/internal/`:

- `store/postgres/channel_bindings.go`: `revokeReplacedUserChannelBindings` replaces the Go loop with `qtx.RevokeReplacedUserChannelBindings(channel, user_id, external_id)`; `disambiguateBindingConflict` names `idx_channel_bindings_active_user_channel_assistant`; doc comments name all three indexes.
- `service/concierge.go`: `MemoryChannelBindingStore.CreateBindingReplacingActive` uses `r.ExternalID == externalID || (r.UserID == userID && channel != model.ChannelAssistant)`; interface and struct docs updated.
- `service/assistant_auth.go`: the comment above `CompleteConsent` and the note before `PurgeRefreshFamilyForBinding` say #2825 is resolved and how.
- `service/assistant_two_hosts_test.go` (new): `TestProbe_OneTravellerTwoHosts` (permanent), `TestAssistantConsent_TwoHosts_WebsiteDisconnectLeavesOther`, `TestAssistantConsent_SameHostReconsentStillReplaces`, `TestMemoryChannelBindingStore_ReplaceRuleByChannel` (Telegram replaces, assistant adds).
- `store/postgres/channel_bindings_integration_test.go` (new, `integration` tag): two hosts live, same host replaces itself, revoke one leaves the other; Telegram still replaces.

## Decisions

- Kept the probe's exact name `TestProbe_OneTravellerTwoHosts` so the #2340 log and the code line up; its doc comment says it is the B7 probe made permanent.
- `RevokeForUser`, `DeleteBinding`, `RevokeByIdentity` and `IsBindingActiveForUser` were not changed: they already resolve by binding id (B1 fix from #2815), which is per host by construction. The task's "must use the per-host identity" is satisfied by proof (tests), not by a rewrite.
- No PRD change: D4 and § 7.1 already specify two hosts and a per-host disconnect; this is code catching up to the spec.
- Did not add a unit test that forces the new 23505 branch; racing the pre-revokes needs two transactions and the migrations_test already pins the constraint names.

## Do not repeat

- zsh `pipestatus` is 1-indexed and slot 1 is the FIRST command in the pipe, not grep; `cmd | grep ...; echo ${pipestatus[1]}` reports cmd's exit. Use `grep -c` and read the count instead when the question is "did grep match".
- The `#2825` comment the task placed at `assistant_auth.go:713` sits at `:853` on this branch; line numbers in critic reports are for the SHA they reviewed.
- Everything from db-architect's handoff still holds (goose on `~/go/bin`, `GITHUB_REPOSITORY` for the filename gate, no local `psql`, do not commit `handoff.md`).

## Evidence

```
cd apps/api
go build ./...                                                         exit 0
go test -race -count=1 ./...                                           exit 0  (24 ok, 6 no test files, 0 FAIL)
go test -race -count=1 -run 'TestProbe_OneTravellerTwoHosts|TestAssistantConsent_TwoHosts|TestAssistantConsent_SameHostReconsent|TestMemoryChannelBindingStore_ReplaceRuleByChannel|TestCritic_Assistant' ./internal/service/... -v
                                                                       exit 0  (7 PASS)
go test -tags=integration -race -count=1 -run 'TestPostgresChannelBindingStore_|TestPostgresAssistantAuthStore_' ./internal/store/postgres/...
                                                                       exit 0  (9 PASS, testcontainers)
go vet ./...                                                           exit 0
gofmt -l <5 files>                                                     exit 0, no output
golangci-lint run --build-tags integration ./apps/api/internal/service/... ./apps/api/internal/store/postgres/...
                                                                       0 issues, exit 0
style scan (U+2014/2013/2015, " -- ", vendor names) on added lines     0 matches
git push origin feat/ac-two-hosts                                      exit 0
gh pr edit 2835 (title + body)                                         exit 0
```

## Open questions

- #2825 closes with this PR. The orchestrator asked for both halves on one branch; nothing left for the issue.
- N1 from the #2340 round-two report (18 pre-existing long dashes in W1-D files) is still in the tree and out of this task's scope.
