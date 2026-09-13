# Handoff: consent-gate CSP fix, issue #2340 finding B1

## Built

`apps/api/` only, on `fix/ac-consent-gate`, commit `bdcdd05e`, pushed. PR #2828 stays draft.

- `internal/middleware/security_headers.go`: added `AssistantHTMLCSP`, a per-route middleware that mints a fresh nonce per request and sets `Content-Security-Policy: default-src 'none'; script-src 'nonce-...'; frame-ancestors 'none'`, plus `CSPNonceFromContext` so a handler can read the nonce it minted. Root `DefaultCSP` and the root `SecurityHeaders` installation are untouched.
- `internal/handler/routes.go`: wrapped the assistant OAuth browser routes that can render HTML (authorize, Google begin, consent, magic-link request/verify) in a chi sub-group using `AssistantHTMLCSP`. The back-channel `token` and `revoke` endpoints stay outside that group and keep the exact root policy.
- `internal/handler/assistant_oauth.go`: moved the Allow-button enable logic out of an inline `onchange` attribute into a single `<script nonce="{{.Nonce}}">` tag on the consent template. `renderConsent` now reads the nonce via `middleware.CSPNonceFromContext(r.Context())`. Server-side refusal of a consent POST without `consent` is unchanged.
- `internal/handler/assistant_oauth_csp_test.go` (new): drives the full authorize -> magic-link -> consent flow through `handler.NewRouter` (root middleware chain, not the handler directly) and asserts the consent page's CSP nonce matches its script tag, that `/health` keeps the exact unmodified root CSP, and that the sibling `revoke` back-channel route also keeps it.

## Decisions

- Nonce encoding is `base64.RawURLEncoding`, not `StdEncoding`. Std alphabet can emit `+`, which `html/template` HTML-escapes inside the attribute (`&#43;...`); a real browser unescapes that fine, but it meant the test's raw-string comparison of the header nonce against the attribute text failed even though the fix was correct. URL-safe base64 has no `+`, `/`, `=`, so the header and attribute text are byte-identical without needing to model HTML entity decoding in the test.
- Scoped `AssistantHTMLCSP` to every assistant OAuth route that can EVER render HTML (including error branches of otherwise-redirecting POSTs), not just the one route with a script tag. Only the consent page has a `<script>` tag, but login/code/error pages share the same html/template rendering path, and keeping the CSP grouping simple (one group, one doc comment, matches the critic's remedy text verbatim) beats a tighter per-branch policy for a handful of routes with no plausible future divergence.
- Did not add `'unsafe-inline'` anywhere; a nonce is strictly tighter and was the finding's suggested remedy.

## Do not repeat

- Don't compare a CSP nonce against `html/template` output with a plain string match if the encoding can produce `+`, `/`, or `=`. Either URL-safe-encode the nonce (what this fix does) or HTML-unescape the extracted attribute text before comparing.
- `apps/web/CLAUDE.md` and `go.work.sum` show as locally modified in this tree; both predate this task (present in the very first `git status` before any edit here) and were deliberately left out of this commit. Do not sweep them into an unrelated `apps/api` commit.

## Evidence

```
$ cd apps/api && go build ./...
(exit 0)

$ go vet ./...
(exit 0)

$ gofmt -l internal/handler/assistant_oauth.go internal/handler/routes.go internal/handler/assistant_oauth_csp_test.go internal/middleware/security_headers.go
(no output, exit 0)

$ go test -race -count=1 ./...
ok  	.../cmd/backfill-duffel-order-id
ok  	.../cmd/server
ok  	.../cmd/worker
ok  	.../internal/ai
ok  	.../internal/apievent
ok  	.../internal/config
ok  	.../internal/crypto
ok  	.../internal/email
ok  	.../internal/handler
ok  	.../internal/integration
ok  	.../internal/inventory
ok  	.../internal/logsafe
ok  	.../internal/middleware
ok  	.../internal/model
ok  	.../internal/notifier
ok  	.../internal/payment
ok  	.../internal/pricing
ok  	.../internal/provider
ok  	.../internal/provider/maps
ok  	.../internal/service
ok  	.../internal/store/postgres
ok  	.../internal/stripelog
ok  	.../internal/testfixture
ok  	.../internal/worker
EXIT_CODE=0

$ go test -race -count=1 -v -run 'TestAssistantOAuth_ConsentPageEnablePathSurvivesProductionCSP|TestAssistantOAuth_RootCSPUnchangedOnNonHTMLRoute|TestAssistantOAuth_TokenAndRevokeKeepRootCSP' ./internal/handler/...
--- PASS: TestAssistantOAuth_ConsentPageEnablePathSurvivesProductionCSP
--- PASS: TestAssistantOAuth_RootCSPUnchangedOnNonHTMLRoute
--- PASS: TestAssistantOAuth_TokenAndRevokeKeepRootCSP
PASS

# RED proof: stashed the three source fixes (kept the new test file),
# reran the same -run filter against the pre-fix tree.
--- FAIL: TestAssistantOAuth_ConsentPageEnablePathSurvivesProductionCSP
    ...should not contain "onchange="
    ...Content-Security-Policy must carry a script-src 'nonce-...' directive, got "default-src 'none'; frame-ancestors 'none'"
--- PASS: TestAssistantOAuth_RootCSPUnchangedOnNonHTMLRoute
--- PASS: TestAssistantOAuth_TokenAndRevokeKeepRootCSP
FAIL
# then: git stash pop (fix restored)

$ git push origin fix/ac-consent-gate
   08230ef6..bdcdd05e  fix/ac-consent-gate -> fix/ac-consent-gate

$ gh pr view 2828 --json isDraft,headRefName,url
{"headRefName":"fix/ac-consent-gate","isDraft":true,"url":"https://github.com/Arlencho/olympus-platform/pull/2828"}
```

PR body updated with a "Finding B1 fix" section and the test-plan evidence above.

## Open questions

- B2 (doc: section 9 `Where` column still pointing S4/S5 at the tile) and the four nits in the same critic comment are untouched here; this task was scoped to B1 only.
- Prior N1 to N3 findings from the same critic round remain open per the earlier handoff on this branch, unrelated to this change.
