# Handoff — CTA aria-label

## Built
- Added `aria-label="Request an Invitation"` to the main invitation CTA anchor in `index.html` (line 286).
- Kept visible link text unchanged: `Request an Invitation`.
- Did not touch intro animation, canvas, favicon, or any other markup/style.

## Decisions (+why)
- Set the aria-label to match the visible text exactly so it is unambiguous and contains the required word "Invitation".
- Targeted the existing `#cta` element as specified; the id selector used by the click animation remains valid.
- Skipped `npm run build`, `npm run lint`, and `npx tsc --noEmit` per the task's explicit charter override.

## Open questions
- None for the code change itself.

## Do not repeat
- Do not remove the visible link text; acceptance requires keeping it.
- Do not add duplicate aria-labels or additional CTAs.

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
$ git commit -m "Improve CTA aria-label"
[feat/ab-T06-cta-aria 4c741b1] Improve CTA aria-label
 1 file changed, 1 insertion(+), 1 deletion(-)

$ git push -u origin feat/ab-T06-cta-aria
 * [new branch]      feat/ab-T06-cta-aria -> feat/ab-T06-cta-aria
```

Grep verification:
```bash
$ rg 'id="cta"|aria-label' index.html
index.html:286:  <a class="cta" href="mailto:arlen@blackaces.se?subject=Request%20an%20Invitation" id="cta" aria-label="Request an Invitation">Request an Invitation</a>
```

## Next hint
- Verify the CTA renders in the DOM with `aria-label="Request an Invitation"`, visible text preserved, and no duplicate CTAs.
