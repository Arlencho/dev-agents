# Handoff — og:locale meta

## Built
- Added exactly one Open Graph locale meta tag in `index.html` `<head>`:
  - `<meta property="og:locale" content="en_GB">`
- Placed immediately after `<title>BLACK ACES</title>` and before the favicon link.
- Did not touch intro animation, canvas, favicon, or any other markup/style.

## Decisions (+why)
- Inserted the meta tag rather than replacing existing head content; grep confirmed no prior `og:locale` meta tag existed.
- Used double-quoted attributes to match the existing meta tag style in the file.
- Skipped `npm run build`, `npm run lint`, and `npx tsc --noEmit` per the task's explicit charter override.

## Open questions
- None for the code change itself.

## Do not repeat
- Do not add additional `og:locale` meta tags; acceptance requires exactly one.

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
$ git commit -m "Add og:locale en_GB"
[feat/ab-T04-og-locale c377518] Add og:locale en_GB
 1 file changed, 1 insertion(+)

$ git push -u origin feat/ab-T04-og-locale
 * [new branch]      feat/ab-T04-og-locale -> feat/ab-T04-og-locale
```

Grep verification:
```bash
$ rg 'og:locale' index.html
index.html:9:<meta property="og:locale" content="en_GB">
```

## Next hint
- Verify the `og:locale` meta renders in the DOM with exact content `en_GB` and no duplicates.
