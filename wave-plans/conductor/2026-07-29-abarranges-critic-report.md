# Frontend Critic Report — PR #2059 (`feat/learn-abarranges-rsc`)

**Critic seat:** Frontend Critic  
**Producer commit:** `e6817060` — `test(web): guard against RSC whitespace loss next to inline tags`  
**Scope:** `apps/web` + learning doc on branch vs `main`  
**Date:** 2026-07-29  

## VERDICT: REVISE

Two MED findings block APPROVE. Multi-line detection works and the three product fixes are correct; the guard still lacks a self-test that it can go red, and the learning note overclaims closure.

---

## Findings

### 1. MED — Guard has no positive-control self-test (silent rot)

**Where:** `apps/web/app/legal/jsx-whitespace.test.ts:72-85`

The suite only asserts:

1. `files.length > 0`
2. `violations === []` on the live tree

If `CLOSING_TAG_AT_EOL`, `TEXT_AT_LINE_START`, `PROSE_AT_EOL`, or `OPENING_TAG_AT_LINE_START` is broken or loosened, the test stays green. A regression guard that cannot prove it detects known-bad input is not a guard.

**Executable repro (already proven on this branch):**

```bash
# tag → text: test goes RED
cat > apps/web/app/_probe.tsx <<'EOF'
export function Probe() {
  return (
    <p>
      <strong>Pelops AI AB</strong>
      arranges and sells packages.
    </p>
  );
}
EOF
cd apps/web && npm test -- app/legal/jsx-whitespace.test.ts
# → FAIL: "...closes an inline tag at end of line..."

# text → tag: test goes RED
cat > apps/web/app/_probe.tsx <<'EOF'
export function Probe() {
  return (
    <h1>
      Tell me about
      <em>the trip</em>
    </h1>
  );
}
EOF
npm test -- app/legal/jsx-whitespace.test.ts
# → FAIL: "...ends with prose and the next line opens an inline tag..."

rm -f apps/web/app/_probe.tsx
```

**Producer fix (proposed failing-test addition — apply as diff):** export or unit-test the detector against in-memory fixtures so CI fails if detection dies, even when the tree is clean.

```diff
--- a/apps/web/app/legal/jsx-whitespace.test.ts
+++ b/apps/web/app/legal/jsx-whitespace.test.ts
@@ -47,6 +47,7 @@ function collectTsx(dir: string): string[] {
 }
 
-function findViolations(file: string): string[] {
+/** Exported for positive-control unit tests below. */
+export function findViolationsInSource(source: string, rel = "fixture.tsx"): string[] {
+  const lines = source.split("\n");
+  const violations: string[] = [];
+  for (let i = 0; i < lines.length - 1; i++) {
+    const line = lines[i];
+    const next = lines[i + 1];
+    if (CLOSING_TAG_AT_EOL.test(line) && TEXT_AT_LINE_START.test(next)) {
+      violations.push(`${rel}:${i + 1} closes an inline tag at end of line`);
+    }
+    if (PROSE_AT_EOL.test(line) && OPENING_TAG_AT_LINE_START.test(next)) {
+      violations.push(`${rel}:${i + 1} ends with prose and the next line opens an inline tag`);
+    }
+  }
+  return violations;
+}
+
+function findViolations(file: string): string[] {
   const lines = readFileSync(file, "utf8").split("\n");
   const rel = path.relative(WEB_ROOT, file);
-  const violations: string[] = [];
-  for (let i = 0; i < lines.length - 1; i++) {
-    const line = lines[i];
-    const next = lines[i + 1];
-    if (CLOSING_TAG_AT_EOL.test(line) && TEXT_AT_LINE_START.test(next)) {
-      violations.push(
-        `${rel}:${i + 1} closes an inline tag at end of line and the next ` +
-          `line starts with text — add {" "} after the tag or the words ` +
-          `render glued together`,
-      );
-    }
-    if (PROSE_AT_EOL.test(line) && OPENING_TAG_AT_LINE_START.test(next)) {
-      violations.push(
-        `${rel}:${i + 1} ends with prose and the next line opens an inline ` +
-          `tag — add {" "} before the tag or the words render glued together`,
-      );
-    }
-  }
-  return violations;
+  // keep full messages; or delegate to findViolationsInSource and map messages
+  return findViolationsInSource(readFileSync(file, "utf8"), rel).map((v) =>
+    v.includes("closes")
+      ? v.replace(/closes.*/, 'closes an inline tag at end of line and the next line starts with text — add {" "} after the tag or the words render glued together')
+      : v.replace(/ends.*/, 'ends with prose and the next line opens an inline tag — add {" "} before the tag or the words render glued together'),
+  );
 }
 
 describe("JSX whitespace next to inline tags (ABarranges regression)", () => {
@@ -83,3 +84,28 @@ describe("JSX whitespace next to inline tags (ABarranges regression)", () => {
     expect(violations).toEqual([]);
   });
+
+  it("detects tag→text when closing tag is last on the line", () => {
+    const src = [
+      "export function F() {",
+      "  return (",
+      "    <p>",
+      "      <strong>Pelops AI AB</strong>",
+      "      arranges and sells",
+      "    </p>",
+      "  );",
+      "}",
+    ].join("\n");
+    expect(findViolationsInSource(src).length).toBeGreaterThan(0);
+  });
+
+  it("detects text→tag when prose ends the line and em/strong opens the next", () => {
+    const src = [
+      "export function F() {",
+      "  return (",
+      "    <h1>",
+      "      Tell me about",
+      "      <em>the trip</em>",
+      "    </h1>",
+      "  );",
+      "}",
+    ].join("\n");
+    expect(findViolationsInSource(src).length).toBeGreaterThan(0);
+  });
+
+  it("does not flag explicit {\" \"} remedy", () => {
+    const src = [
+      "export function F() {",
+      "  return (",
+      "    <p>",
+      "      <strong>Pelops AI AB</strong>{\" \"}",
+      "      arranges",
+      "    </p>",
+      "  );",
+      "}",
+    ].join("\n");
+    expect(findViolationsInSource(src)).toEqual([]);
+  });
 });
```

(Producer may clean the refactor; the requirement is: at least two RED-path fixtures + one green remedy fixture committed in the suite.)

---

### 2. MED — Learning doc overclaims "Closed" and under-documents scope gaps

**Where:** `docs/qa/learning-rsc-jsx-whitespace.md:3-5` and `:41-46`

| Claim in doc | Reality on `e6817060` |
|---|---|
| **Status: Closed (fixed 2026-07-23, commits `30f4e875` / `a9eb5ecf`)** | This PR (2026-07-29) found **three more** multi-line instances in `atlas-home-page.tsx` and `dev/atlas-v04-foundation/page.tsx`. Closure date/commits are incomplete. |
| Guard "scans … for both hazard patterns" | True for **newline** tag→text and text→tag only. **Same-line** glue is not scanned (proved below). |
| Implicit "class closed" | Live same-line block-em headings still produce glued `textContent` (explore / stays / stories), by PRD/design intent. |

**Same-line false negative (proved):**

```text
Input:  Discover places that<em>match your energy.</em>
Guard:  NO VIOLATION (test stays green with this as sole probe file)
DOM textContent: "Discover places thatmatch your energy."
```

Live sources (not introduced by this PR; PRD/design intentional; `.ra-view-h1 em { display: block }` so **visual** is two lines):

- `apps/web/app/explore/explore-view.tsx:183`
- `apps/web/app/stays/stays-view.tsx:90`
- `apps/web/app/stories/stories-view.tsx:51`

**Producer fix (doc only — do not rewrite product/legal copy):**

1. Status line → e.g. `Mitigated + guarded (multi-line). Last product hits fixed 2026-07-29 (e6817060).`
2. Explicit **out of scope** note:
   - same-line missing space (`that<em>match`) is not scanned
   - intentional PRD block-em headings (explore/stays/stories) omit the space; visual OK via `display:block`; `textContent` still glues
3. Optional: note that block comments containing the bad pattern can false-positive the scan

---

### 3. LOW — Block-comment false positive risk

**Where:** `apps/web/app/legal/jsx-whitespace.test.ts:48-68` (line-oriented scan, no comment awareness)

Synthetic:

```tsx
{/* fixed:
<strong>AB</strong>
arranges
*/}
```

→ scanner reports tag→text violation. No current tree hit; risk if someone documents the bad pattern in a JSX comment. Acceptable residual if documented (see Finding 2).

---

### 4. LOW — Stale comment in hero unit tests after space fix

**Where:** `apps/web/app/atlas-home-page.test.tsx:263-266` and `:368-369`

Comments still say there is "no inline whitespace separating the two fragments." After `{" "}` in `atlas-home-page.tsx:470` / `:549`, `heading.textContent` is now spaced (`"Tell me about the trip you'd love."`). Update the comments (or assert the spaced full string) so the test file does not re-teach the pre-fix mental model.

---

## What was verified (commands + results)

### Diff under review

```text
e6817060 test(web): guard against RSC whitespace loss next to inline tags
 apps/web/app/atlas-home-page.tsx               |  4 +-
 apps/web/app/dev/atlas-v04-foundation/page.tsx |  2 +-
 apps/web/app/legal/jsx-whitespace.test.ts      | 85 ++++++++++++++++++++++++++
 docs/qa/learning-rsc-jsx-whitespace.md         | 46 ++++++++++++++
```

### Vitest include + CI

- `apps/web/vitest.config.ts:25` — `include: ["**/*.test.{ts,tsx}"]` → matches `app/legal/jsx-whitespace.test.ts`
- `.github/workflows/ci.yml:509-539` — job `TypeScript Test (Vitest)` runs `npm run test` in `apps/web`

### Guard green on clean tree

```bash
cd apps/web && npm test -- app/legal/jsx-whitespace.test.ts
# ✓ 2 tests passed
```

### Full multi-line scan (same logic as test)

```text
files scanned 248
violations none
```

### Directional proof (inject file → restore)

| Probe | Expected | Result |
|---|---|---|
| multi-line `</strong>` → text | RED | RED with tag→text message |
| multi-line prose → `<em>` | RED | RED with text→tag message |
| same-line `that<em>match` | green (gap) | green — **false negative** |
| remedy `{" "}` multi-line | green | green (no FP on legal pages) |

### Hero / dev fixes — copy meaning

| File:line | Change | User-visible meaning |
|---|---|---|
| `atlas-home-page.tsx:470` | `Tell me about` → `Tell me about{" "}` | Space only. Visual unchanged (`.ra-h1 em { display:block }` at `globals.css:1076-1080`). `textContent`: `Tell me aboutthe trip` → `Tell me about the trip`. |
| `atlas-home-page.tsx:549` | `Where are we` → `Where are we{" "}` | Same class. |
| `dev/atlas-v04-foundation/page.tsx:29` | `Self-hosted fonts.` → `Self-hosted fonts.{" "}` | Space only. |

`npm test -- app/atlas-home-page.test.tsx` → 26/26 passed.

### Legal baseline still spaced

`package-info/page.tsx`: `<strong>Pelops AI AB</strong>\n{" "}\narranges resegaranti` — correct.

### Exclusions by design (not defects for this PR)

- `<a>` / `<span>` not in `INLINE_TAGS` — correct for ABarranges class (`strong`/`b`/`em`)
- `</strong>\n{stat.label}` in stats row not flagged — `{` fails `TEXT_AT_LINE_START`; `.ra-stats .stat strong { display:block }` separates visually
- Design mocks under `docs/design/atlas-v2-source/*` still use compact multi-line / same-line forms — not product UI, not scanned

---

## Loop budget

This is **loop 1 of 2**. Producer should:

1. Add positive-control fixtures to the vitest guard (Finding 1)
2. Correct learning-doc status + explicit same-line / block-em scope notes (Finding 2)
3. Optionally refresh hero test comments (Finding 4)

Then re-request critic pass. On loop 2, critic re-runs probes; third attempt escalates to CTO.

---

## Summary for conductor

| Field | Value |
|---|---|
| VERDICT | **REVISE** |
| HIGH | 0 |
| MED | 2 |
| LOW | 2 |
| Ship blockers | Positive-control self-test; learning-doc accuracy/scope |
| Product copy rewrites | None required |
