# Handoff — Skip-to-content link

## Built
- Added one skip link as the first focusable element in `index.html` `<body>` (before `<canvas id="fx">`):
  - `<a href="#content" class="skip-link">Skip to content</a>`
- Added minimal `.skip-link` CSS in the existing `<head>` `<style>` block:
  - Visually hidden off-screen by default (`position:absolute; left:-10000px; width:1px; height:1px; overflow:hidden`).
  - Becomes visible on `:focus`/`:active` as a fixed top-left gold-bordered pill (`z-index:100`) using the site's CSS variables.
- Did not modify the intro `#skip` button, favicon, body lock logic, canvas, or any other markup/style.

## Decisions (+why)
- Placed the link before `<canvas id="fx">` so it is the first focusable element in `<body>`; the canvas is `aria-hidden` and not focusable.
- Reused existing CSS custom properties (`--ink`, `--gold`, `--gold-hi`, `--sans`) so the focus state matches the site's palette without adding new colors or dependencies.
- Kept the link as a plain anchor to `#content`; the `#content` section already exists, so no new target was needed.
- Did not intercept the click during the intro `body.lock` phase — the acceptance criteria only require the link to exist, be focusable, and not produce console errors.

## Open questions
- None for the code change itself.

## Do not repeat
- Do not add additional skip links; acceptance requires exactly one.
- Do not rename or restyle the existing `#skip` intro-skip button.

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
$ git commit -m "Add skip-to-content link"
[feat/ab-T07-skip-link 7e08318] Add skip-to-content link
 1 file changed, 8 insertions(+)

$ git push -u origin feat/ab-T07-skip-link
 * [new branch]      feat/ab-T07-skip-link -> feat/ab-T07-skip-link
```

Grep verification:
```bash
$ rg 'skip-link|Skip to content' index.html
index.html:241:.skip-link{position:absolute;left:-10000px;top:auto;width:1px;height:1px;overflow:hidden}
index.html:242:.skip-link:focus,.skip-link:active{position:fixed;left:16px;top:16px; ... }
index.html:249:<a href="#content" class="skip-link">Skip to content</a>
```

## Next hint
- Verify the skip link is the first focusable element in `<body>`, that focusing it reveals the styled "Skip to content" button, and that it points to the existing `#content` section with no duplicates.
