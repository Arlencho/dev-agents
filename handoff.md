# Handoff — CRITIC verdict, Fleet Desk Wave 2 UI craft (PR #47, `feat/fleet-desk-ui`)

Seat: frontend-critic (verify only). No production code written, no UI redesigned.
Reviewed `b6e3df0` against `docs/proposals/experience-console-SYNTHESIS.md` §4–§6
and the producer handoff.

## VERDICT: REVISE

One blocking executable failure. Everything else in the Wave 2 scope verifies clean.
The fix is three string literals; no redesign, no contract change.

---

## BLOCKING — B1. Breadcrumb "back" link is a 404 on every role / skill / learning detail page

Detail pages live at the **singular** path (`role/<id>/`), but their index lives at the
**plural** path (`roles/`). The breadcrumb walks up one level and lands on a path that is
never generated.

**Source (`file:line`):**

| Line | Code | Resolves to | Exists |
|------|------|-------------|--------|
| `scripts/experience_build.py:524` | `self.crumb([("← Roles", "../index.html"), (role, None)])` | `role/index.html` | NO (index is `roles/index.html`) |
| `scripts/experience_build.py:574` | `self.crumb([("← Skills", "../index.html"), (s["id"], None)])` | `skill/index.html` | NO (index is `skills/index.html`) |
| `scripts/experience_build.py:620` | `self.crumb([("← Learn", "../index.html"), (L["slug"], None)])` | `learning/index.html` | NO (index is `learnings/index.html`) |

`scripts/experience_build.py:458` (company) gets the same pattern right with `../../index.html`,
which is why this slipped: it is the one crumb whose parent really is one level up.

**Rendered evidence** (`site/experience/role/web-frontend/index.html:24`):

```html
<p class="crumb"><a href="../index.html">← Roles</a><span class="sep">·</span><span>web-frontend</span></p>
```

Header nav on the same page is correct (`href="../../roles/index.html"`), so this is a broken
affordance, not a dead end. It still ships a 404 on 12 of 54 pages (22%).

**Deterministic repro (fixture, no real-repo data needed):**

```
$ TMP=$(mktemp -d)
$ python3 scripts/experience_data.py  --repo tests/fixtures/experience-mini --out $TMP/s
$ python3 scripts/experience_build.py --repo tests/fixtures/experience-mini --out $TMP/s
$ python3 - "$TMP/s" <<'PY'
import re,sys; from pathlib import Path
root=Path(sys.argv[1]); bad=[]
for f in sorted(root.rglob("*.html")):
    h=f.read_text()
    for m in re.finditer(r'href="([^"]+)"',h):
        u=m.group(1)
        if u.startswith(("http","mailto:","#")): continue
        p=(f.parent/u.split("#")[0]).resolve()
        if p.is_dir(): p=p/"index.html"
        if not p.exists(): bad.append(f"{f.relative_to(root)} -> {u}")
print("BROKEN:",len(bad)); [print("  ",b) for b in bad]
PY
BROKEN: 10
   learning/lesson-one/index.html -> ../index.html
   learning/lesson-two/index.html -> ../index.html
   role/fixture-builder/index.html -> ../index.html
   role/fixture-critic/index.html -> ../index.html
   role/fixture-flaky/index.html -> ../index.html
   role/fixture-runner/index.html -> ../index.html
   role/fixture-scribe/index.html -> ../index.html
   skill/draft-pack/index.html -> ../index.html
   skill/evidence-first/index.html -> ../index.html
   skill/fixture-pack/index.html -> ../index.html
```

Same crawl over the real build: **12 broken links / 1104 relative links / 54 pages.**

**Expected:** `../../roles/index.html`, `../../skills/index.html`, `../../learnings/index.html`.

### B1b. Test gap that allowed it

`tests/run-experience-tests.sh:190` asserts only that a crumb *exists* on the trail page
(`grep -q 'class="crumb"'`). No check asserts a crumb *resolves*, and no check crawls links at
all. A `class="crumb"` assertion is satisfied by a 404. Add link integrity to the suite
(the crawler above, asserting `BROKEN: 0`), otherwise this class of bug stays invisible.

---

## Non-blocking observations (do not gate merge)

- **N1. Scope chip conveys placeholder status by opacity alone.**
  `templates/experience/site.css:108` `.chip.dim { opacity: 0.55; }`; the word "placeholder"
  appears only in the `title=` tooltip (`site/experience/index.html`, chips strip). §6.7 says
  status must not be color-only, and `title` is not reliably exposed to touch or SR users.
  Mitigated because the company **cards** on the same page render `placeholder · n=0` as visible
  text, so the information is not lost. Worth a visible marker on the chip in a later pass.
- **N2. `assert_absent_html` pattern is narrower than its name.**
  `tests/run-experience-tests.sh:180` matches `' style="'` (leading space, double quote only).
  `style='…'` or a newline-prefixed attribute would pass. Tighten to `[[:space:]]style=` if you
  want the invariant airtight. Current output is clean either way (0 matches).
- **N3. `home()` is 94 lines** (`scripts/experience_build.py:278`), the longest renderer in the
  file. Acceptable for an f-string page template; flagging only so it does not grow further.
- **N4. Contract-boundary note, NOT this PR's bug.** The real-repo build reports
  `19 trails, 5 companies, 19 unlinked`, so every company page renders `n=0` and its empty
  state. That is Wave 1 join law behaving as specified, and the empty states teach correctly.
  Calling it out for CTO visibility only. **This PR must not be asked to fix it.**

---

## Verified clean (adversarial checks that passed)

**Contract boundary (§3.5, §5.2), intact:**
- `git diff main...HEAD -- scripts/experience_data.py` touches only `phase_note` heading-skip
  (`load_companies`, 5 insertions). No join, PMI, or PMI-gate logic changed. Wave 1 law holds.
- Renderer is JSON-only: the sole data read is `data_path.read_text()` at
  `scripts/experience_build.py:722`. `CSS_SOURCE` (`:29`) is a template asset, not data.

**Craft invariants:**
- Inline `style="` in built HTML: **0**. `<style>` blocks: **0**.
- HTML pages missing `rel="stylesheet"`: **0 / 54**. CSS is external at
  `templates/experience/site.css`, copied to `site/experience/assets/site.css`.
- `make experience`, `make experience-open`, `make desk` all resolve and build.
- `site/experience/` gitignored (`.gitignore:30`), per §7.

**Routes (§4.1), all present:** `/`, `/company/<id>/` (5), `/work/` + `/work/flat/`,
per-company `work/` + `work/flat/`, `/trail/<task_id>/` (19), `/role/<role>/`, `/skill/<id>/`,
`/learning/<slug>/`, `/conductor/`, `/about/`, plus `roles|skills|learnings` indexes.

**Nav (§4.1:157):** renders exactly `Home · Work · Skills · Learn · Roles · Conductor · About`
plus scope chips `Global | aegis | olympus | rios-operator | safeplace | wearforrun`.

**UX freeze (§6):**
- §6.3/§6.9 Wave visible on work rows and grouped headers (`Wave 1 … Wave 19` sections present).
- §6.6 Empty states teach the next command, verified on company, conductor, work, learnings.
- §6.7 a11y: skip link on **54/54** pages; `aria-current` on **54/54**
  (49 `page` on nav, 66 `true` on chips/segments); `:focus-visible` outline at
  `templates/experience/site.css:54`; heading order `h1 → h2` with no skips.
- §6.8 `prefers-color-scheme` dark palette (`site.css:32`), `prefers-reduced-motion` reduce
  (`site.css:55`), mono SHAs (`class="mono">e44ec21`), one bronze accent.
- §5.1 No bare percentages: renders `100% · n=10`, `100% · n=9`.
- §5.2 PMI capped at P2 with the required caption "P3 needs version/promotion history" on both
  `roles/index.html` and `role/<role>/index.html`; band + reason + `<details>` raw inputs present.
- Status is text AND color: 86 pills render `class="st st-done">done`, never a bare swatch.
- Group-by-wave / flat toggle works as static page pairs, zero JS. Producer's open question about
  `company/<id>/work/flat/` depth-4 prefixes: **resolved clean**, 0 broken links in that subtree.

**Tests:** `make test` → `== 121 passed, 0 failed ==`, all suites green. The 24 new Wave 2 smokes
are substantive, not vacuous: they assert concrete class names, pill text, breadcrumb presence,
`base → head`, PMI badge, and run against the deterministic fixture rather than only the real
repo. The one real hole is link resolution (B1b).

## Loop status

Critique batch **1 of 2**. Fix B1 (three literals) and add the B1b link-integrity check, then
this is APPROVE. A third round escalates to CTO.
