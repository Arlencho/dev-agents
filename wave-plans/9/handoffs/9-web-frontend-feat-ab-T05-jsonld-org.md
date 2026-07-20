# Handoff — Organization JSON-LD

## Built
- Added exactly one JSON-LD `<script type="application/ld+json">` block in `index.html` `<head>` (before `</head>`):
  - `@type`: `Organization`
  - `name`: `Black Aces AB`
  - `url`: `https://blackaces.se/`
  - `email`: `arlen@blackaces.se`
- Valid JSON with `https://schema.org` context.
- Did not touch intro animation, canvas, favicon, or any other markup/style.

## Decisions (+why)
- Placed the JSON-LD block at the end of `<head>` after the inline `<style>`, which keeps structured data out of the visual markup and follows common placement.
- Inserted the block rather than replacing existing head content; grep confirmed no prior JSON-LD script existed.
- Skipped `npm run build`, `npm run lint`, and `npx tsc --noEmit` per the task's explicit charter override.

## Open questions
- None for the code change itself.

## Do not repeat
- Do not add additional Organization JSON-LD blocks; acceptance requires exactly one.

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

Grep verification:
```bash
$ rg 'application/ld\+json|Organization' index.html
index.html:240:<script type="application/ld+json">
index.html:243:  "@type": "Organization",
```

## Next hint
- Verify the JSON-LD script renders in the DOM with exactly one Organization block and the expected `name`, `url`, and `email` values; confirm no duplicate JSON-LD scripts.
