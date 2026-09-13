# Handoff: PR #2754 review fixes (docs/prd-baggage-card-and-route-map)

## Built
Three docs-only edits in one commit `92575f13`, pushed to the existing branch (PR #2754 updated in place, not merged).
- `docs/prd/pages/atlas-chat.md:3687` — route-map Label row: trailing absolute rewritten.
- `docs/prd/pages/flight-detail-fare.md:209` — glyph-precedent pointer corrected.
- `docs/prd/pages/flight-detail-fare.md:211` — Responsive passage split into inherited vs required.
Diff: 2 files, +14 -6. Nothing under `apps/`.

## Decisions
- F1: kept the first sentence half intact per the review; scoped the fallback to the missing-CODE case and deferred the missing-CITY case explicitly to `01-conventions.md` 24.1's single permitted exception. Quoted 24.1's own phrase so the deferral is checkable.
- F2: cited `flight-widget.tsx:592` and `:611` by line, matching the citation style already used in these specs (`provider/duffel.go:780`, `next.config.ts:143-152`). Wrapping stated as existing; pair integrity stated as a requirement on new markup.
- F3: pointer changed to `atlas-chat.md` 11.5 (not bare 11) since 11.5 is the Accessibility subsection carrying the rule. Inline prose untouched.
- F4 from the review was deliberately NOT fixed: the task scoped this pass to three findings.
- No ACCEPTED/approved/sign-off language added; all `STATUS: PROPOSED` banners unchanged.

## Do not repeat
- Do not "fix" the inline `style={{}}` on `flight-widget.tsx:586-593`. Pre-existing, out of scope, belongs to the implementation PR.
- Do not add new spec content to these blocks while under review; growing the spec invalidates the passed review.
- `flexWrap: "wrap"` is at line 592, not 591 as the review approximated. Verify before citing.

## Evidence
- `sed -n '592p;611p' apps/web/components/widgets/flight-widget.tsx` → `flexWrap: "wrap",` / `{flightCardFactParts(f, cabinLabel).join(" · ")}`
- `grep -n "^### 11.5" docs/prd/pages/atlas-chat.md` → 3586
- `grep -n "^## 20\." docs/prd/01-conventions.md` → 732; `### 24.1` → 1401; exception text at 1431-1434
- `git diff -U0 | grep '^+' | grep -Ein "accepted|approved|signed off"` → none
- Push: `f173ce26..92575f13  docs/prd-baggage-card-and-route-map`
- PR comment: https://github.com/Arlencho/olympus-platform/pull/2754#issuecomment-5471271307

## Open questions
- Section 9.5 (unknown baggage count) still needs a co-founder decision before any code ships. F4 (tension between `flight-detail-fare.md:175` and `:443`) remains open for the sign-off pass.
