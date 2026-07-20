# Handoff — Footer contact domain

## Built
- Updated the `#content` footer line in `index.html`:
  - From: `<p class="foot">Black Aces AB — Åkersberga · Stockholm</p>`
  - To: `<p class="foot">Black Aces AB — Åkersberga · Stockholm · blackaces.se</p>`
- Added `blackaces.se` exactly once while preserving the existing city text (`Åkersberga · Stockholm`).
- Did not touch the legal org.nr block, intro animation, canvas, favicon, or any other markup/style.

## Decisions (+why)
- Appended the domain to the existing footer sentence using the same mid-dot separator already used between the city names, keeping the visual rhythm consistent.
- Kept the existing legal/org.nr paragraph untouched because the task explicitly forbids inventing or modifying legal org.nr text.
- Skipped `npm run build`, `npm run lint`, and `npx tsc --noEmit` per the task's explicit charter override.

## Open questions
- None for the code change itself.

## Do not repeat
- Do not add additional `blackaces.se` mentions in the footer; acceptance requires exactly one.
- Do not remove or alter the city text (`Åkersberga` / `Stockholm`).

## Evidence
```bash
$ npm run qa
content top=2520 cls=seen
hand top=3420 cls=blk seen done
ace5 top=4409 cls=blk seen done
record top=5338 cls=blk seen done
contact top=6012 cls=blk seat seen done
console errors: none
```

```bash
$ git commit -am "Clarify footer contact domain"
[feat/ab-T08-footer-domain 2cf468c] Clarify footer contact domain
 1 file changed, 1 insertion(+), 1 deletion(-)

$ git push -u origin feat/ab-T08-footer-domain
 * [new branch]      feat/ab-T08-footer-domain -> feat/ab-T08-footer-domain
```

Grep verification:
```bash
$ rg 'blackaces\.se|Åkersberga|Stockholm' index.html
index.html:287:  <p class="foot">Black Aces AB — Åkersberga · Stockholm · blackaces.se</p>
```

## Next hint
- Verify the footer renders with the city text intact and `blackaces.se` appearing exactly once, and that `npm run qa` reports no console errors.
