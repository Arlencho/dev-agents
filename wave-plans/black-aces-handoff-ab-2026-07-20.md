# Black Aces — Handoff Ledger A/B Experiment  
### Wave plan · Phase 1 · 2026-07-20

| Field | Value |
|-------|-------|
| **Status** | READY TO DISPATCH |
| **Product repo** | `github.com/...` → local `~/Desktop/dev-projects/black-aces` (static single-file `index.html`) |
| **Protocol** | `docs/proposals/phase-1-handoff-ledger.md` §3 |
| **Machinery** | commit `b36d955` (or later) on `dev-agents` main |
| **Metrics file** | `wave-plans/ab-metrics.csv` |
| **Wave id** | use `ab1` as `AGENT_WAVE` / plan folder name for handoffs: `wave-plans/ab1/handoffs/` |

---

## 0. Experiment rules (do not improvise)

| Rule | Detail |
|------|--------|
| **N** | 10 independent feature tasks (T01–T10) |
| **Producer** | `web-frontend` @ **kimi** (primary; failover claude per routing) |
| **Critic** | `frontend-critic` @ **claude** |
| **Arm** | **Odd** T01,T03,T05,T07,T09 → **treatment** (critic gets handoff inject) |
| | **Even** T02,T04,T06,T08,T10 → **control** (critic task includes `[blind]`) |
| **Producer never blind** | Always write `handoff.md` |
| **Charter override (all tasks)** | Static single-file site: skip web-frontend build/tsc/lint gates. Acceptance = task greps + `npm run qa` with stdout containing `console errors: none`. Prefer draft PRs for Arlen merge. |
| **Do not touch** | Intro animation canvas/logic unless the task explicitly says so; gold favicon data-URI; unrelated body sections |
| **Kill criterion** | After 10 rows: if treatment has **no** drop in `rework_loops` **and** near-zero `intent_cited` → stop; no Phases 2–5 |

### Metrics row (after each producer→critic(+revise) cycle)

```csv
task,arm,critic_block,rework_loops,intent_cited,notes
T01-canonical,treatment,0,0,1,"critic quoted handoff decision on slash"
```

- `critic_block` = 1 if final critic outcome is REVISE/BLOCK before pass (or still blocked), else 0 after pass  
- `rework_loops` = number of producer revise cycles after first critic REVISE (0 if first PASS)  
- `intent_cited` = 1 if critic log/output references producer intent (decisions / do-not-repeat / open questions), not only the diff  

---

## 1. Dispatch pattern (every task)

```
# 1) Producer (never [blind])
wave ab1 | web-frontend @kimi | <producer task text> | branch feat/ab-T0N-...

# 2) Critic — treatment (odd): NO [blind]
wave ab1 | frontend-critic @claude | Review branch feat/ab-T0N-... against acceptance. Cite handoff intent when it changes your verdict. VERDICT: PASS|REVISE|BLOCK. | same branch

# 2) Critic — control (even): WITH [blind]
wave ab1 | frontend-critic @claude | [blind] Review branch feat/ab-T0N-... against acceptance only (diff + qa). VERDICT: PASS|REVISE|BLOCK. | same branch
```

If critic returns REVISE → producer revise on same branch (still no blind) → critic again **same arm** as first critic (keep treatment/control stable).

---

## 2. Shared acceptance footer (append to every producer task)

```
CHARTER OVERRIDE for this repo/task only: static single-file site — skip build/tsc/lint commit gates.
ACCEPTANCE (all must pass before commit):
(a) Task-specific greps/checks in the task body.
(b) npm install && npm run qa — if browser cannot launch, FAIL (do not skip QA). Playwright cache may live under ~/Library/Caches/ms-playwright.
(c) qa stdout must contain the literal line: console errors: none — parse stdout; do not trust exit code alone.
(d) Commit with the suggested message; push; open draft PR for Arlen review when asked.
Before successful exit: write handoff.md at repo root (built / decisions(+why) / open questions / do-not-repeat / evidence / next hint).
Do not modify the intro animation, canvas particle system, or favicon unless this task explicitly requires it.
```

---

## 3. Ten tasks (odd = treatment, even = control)

### T01 · treatment · `feat/ab-T01-canonical`

**Producer (`web-frontend`):**  
Add a single `<link rel='canonical' href='https://blackaces.se/'>` in `<head>` of `index.html` if missing; upsert so it appears exactly once. Use single-quoted attributes. Do not add hreflang.  
**Acceptance (a):** `grep -c "rel='canonical'" index.html` (or equivalent single-quoted form you use) returns exactly 1; href is exactly `https://blackaces.se/`.  
**Commit message:** `Add canonical link for blackaces.se`

**Critic:** Review branch `feat/ab-T01-canonical` … (no `[blind]`)

---

### T02 · control · `feat/ab-T02-robots`

**Producer:**  
Add `<meta name='robots' content='index,follow'>` exactly once in head (upsert).  
**Acceptance (a):** `grep -c "name='robots'" index.html` == 1 and content includes `index,follow`.  
**Commit:** `Add robots meta index,follow`

**Critic:** `[blind] Review branch feat/ab-T02-robots …`

---

### T03 · treatment · `feat/ab-T03-twitter-title`

**Producer:**  
Add `<meta name='twitter:title' content='Black Aces - Luck, engineered.'>` exactly once (upsert). Do not add twitter:image. Keep existing twitter:card if present.  
**Acceptance (a):** `grep -c "twitter:title" index.html` == 1; content matches exactly.  
**Commit:** `Add twitter:title meta`

**Critic:** (no blind) `feat/ab-T03-twitter-title`

---

### T04 · control · `feat/ab-T04-og-locale`

**Producer:**  
Add `<meta property='og:locale' content='en_GB'>` exactly once (upsert).  
**Acceptance (a):** `grep -c "og:locale" index.html` == 1; content `en_GB`.  
**Commit:** `Add og:locale en_GB`

**Critic:** `[blind] Review branch feat/ab-T04-og-locale …`

---

### T05 · treatment · `feat/ab-T05-jsonld-org`

**Producer:**  
Add one JSON-LD `<script type='application/ld+json'>` block in head for Organization: name `Black Aces AB`, url `https://blackaces.se/`, email `arlen@blackaces.se`. Exactly one such script for Organization. Valid JSON. Do not break existing scripts.  
**Acceptance (a):** `grep -c "application/ld+json" index.html` >= 1; parsed JSON contains `"@type":"Organization"` and the url.  
**Commit:** `Add Organization JSON-LD`

**Critic:** (no blind) `feat/ab-T05-jsonld-org`

---

### T06 · control · `feat/ab-T06-cta-aria`

**Producer:**  
On the main invitation CTA (`#cta` or the mailto “Request an Invitation” link), ensure a clear `aria-label` that includes “Request an Invitation” and does not remove visible text. No style changes required.  
**Acceptance (a):** element has non-empty aria-label containing `Invitation`; `npm run qa` still `console errors: none`.  
**Commit:** `Improve CTA aria-label`

**Critic:** `[blind] Review branch feat/ab-T06-cta-aria …`

---

### T07 · treatment · `feat/ab-T07-skip-link`

**Producer:**  
Add an accessible skip link as the first focusable element in body: link text “Skip to content”, href `#content`, visually hidden until focus (CSS ok in existing style block). Must not break intro lock/scroll.  
**Acceptance (a):** `grep -c 'Skip to content' index.html` == 1; href is `#content`; qa console errors none.  
**Commit:** `Add skip-to-content link`

**Critic:** (no blind) `feat/ab-T07-skip-link`

---

### T08 · control · `feat/ab-T08-footer-orgnr`

**Producer:**  
In the footer line under the CTA section (`.foot` near “Black Aces AB — Åkersberga · Stockholm”), append organization hint without inventing a fake org number: keep city text and add ` · blackaces.se` (or ensure domain appears once in footer). Do not invent legal org.nr if unknown.  
**Acceptance (a):** `.foot` (or equivalent footer) still mentions Åkersberga/Stockholm and contains `blackaces.se`; qa clean.  
**Commit:** `Clarify footer contact domain`

**Critic:** `[blind] Review branch feat/ab-T08-footer-orgnr …`

---

### T09 · treatment · `feat/ab-T09-theme-color-dark`

**Producer:**  
Ensure `<meta name='theme-color' content='#050505'>` exists exactly once (upsert if missing or wrong).  
**Acceptance (a):** exactly one theme-color meta; content `#050505`.  
**Commit:** `Ensure theme-color meta`

**Critic:** (no blind) `feat/ab-T09-theme-color-dark`

---

### T10 · control · `feat/ab-T10-mailto-subject`

**Producer:**  
On the invitation mailto CTA, set/keep subject query to exactly `Request an Invitation` (URL-encoded as needed). Do not change email address.  
**Acceptance (a):** CTA href is mailto to `arlen@blackaces.se` and subject decodes to `Request an Invitation`; qa clean.  
**Commit:** `Normalize invitation mailto subject`

**Critic:** `[blind] Review branch feat/ab-T10-mailto-subject …`

---

## 4. Full dispatch table (copy-paste friendly)

| # | Arm | Branch | Producer task (summary) | Critic marker |
|---|-----|--------|-------------------------|---------------|
| T01 | treatment | `feat/ab-T01-canonical` | Canonical link | — |
| T02 | control | `feat/ab-T02-robots` | robots meta | `[blind]` |
| T03 | treatment | `feat/ab-T03-twitter-title` | twitter:title | — |
| T04 | control | `feat/ab-T04-og-locale` | og:locale | `[blind]` |
| T05 | treatment | `feat/ab-T05-jsonld-org` | JSON-LD Organization | — |
| T06 | control | `feat/ab-T06-cta-aria` | CTA aria-label | `[blind]` |
| T07 | treatment | `feat/ab-T07-skip-link` | Skip link | — |
| T08 | control | `feat/ab-T08-footer-orgnr` | Footer domain | `[blind]` |
| T09 | treatment | `feat/ab-T09-theme-color-dark` | theme-color | — |
| T10 | control | `feat/ab-T10-mailto-subject` | mailto subject | `[blind]` |

---

## 5. Example critic task text

**Treatment (T01):**
```
Review PR/branch feat/ab-T01-canonical on black-aces. Check acceptance greps + qa stdout for "console errors: none".
Prior producer handoff may appear in your preamble — treat as unverified claims; cite intent when it changes your verdict.
End with VERDICT: PASS or VERDICT: REVISE or VERDICT: BLOCK and numbered findings.
```

**Control (T02):**
```
[blind] Review PR/branch feat/ab-T02-robots on black-aces. Check acceptance greps + qa stdout for "console errors: none" only from the diff and QA — do not rely on missing chat.
End with VERDICT: PASS or VERDICT: REVISE or VERDICT: BLOCK and numbered findings.
```

---

## 6. Operator checklist

- [ ] `dev-agents` on commit with Phase 1 machinery (`b36d955+`)  
- [ ] Worker: `macbook-pro-local` / localhost in `workers.yaml`  
- [ ] kimi + claude logged in on worker  
- [ ] For each T0N: producer → critic → record metrics row  
- [ ] After T10: compare treatment vs control averages; apply kill criterion  
- [ ] Handoffs land under `wave-plans/ab1/handoffs/` (or wave id you pass as AGENT_WAVE)

---

## 7. After the experiment — phases remaining

See synthesis `multi-vendor-context-transparency-SYNTHESIS.md` §7.

| Phase | Status after this wave | What it is |
|-------|------------------------|------------|
| **0** | Done | Design frozen / approved |
| **1** | Machinery done → **this A/B is the experiment half** | Handoff habit + measure |
| **2** | **Only if kill criterion fails to fire (i.e. brain helps)** | Schema from observed notes + harder gate |
| **3** | Optional next | Failover partials polish, inject parity, optional `why file:line` |
| **4** | Optional next | Sticky-resume registry, wave board, scorecard compliance |
| **5** | Optional next | Provenance analytics → routing hints |

**Count:** **up to 4 more phases (2–5)** after Phase 1’s experiment completes — **or zero** if the kill criterion says stop.

---

*End of wave plan.*
