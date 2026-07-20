# Handoff — twitter:title meta

## Built
- Added exactly one Twitter title meta tag in `index.html` `<head>`:
  - `<meta name="twitter:title" content="Black Aces - Luck, engineered.">`
- Placed immediately after `<title>BLACK ACES</title>` and before the favicon link.
- Did not touch intro animation, canvas, favicon, or any other markup/style.

## Decisions (+why)
- Inserted the meta tag rather than replacing existing head content; grep confirmed no prior `twitter:title` meta tag existed.
- Used double-quoted attributes to match the existing meta tag style in the file.
- Skipped `npm run build`, `npm run lint`, and `npx tsc --noEmit` per the task's explicit charter override.

## Open questions
- None for the code change itself.

## Do not repeat
- Do not add additional `twitter:title` meta tags; acceptance requires exactly one.
- Do not add `twitter:image`; acceptance explicitly forbids it.

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
$ git commit -m "Add twitter:title meta"
[feat/ab-T03-twitter-title 672544a] Add twitter:title meta
 1 file changed, 1 insertion(+)

$ git push -u origin feat/ab-T03-twitter-title
 * [new branch]      feat/ab-T03-twitter-title -> feat/ab-T03-twitter-title
```

Grep verification:
```bash
$ rg 'twitter:title|twitter:image' index.html
index.html:9:<meta name="twitter:title" content="Black Aces - Luck, engineered.">
```

## Next hint
- Verify the `twitter:title` meta renders in the DOM with exact content `Black Aces - Luck, engineered.` and no duplicates; confirm no `twitter:image` tag is present.
