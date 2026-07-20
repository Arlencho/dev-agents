# Handoff — robots meta

## Built
- Added exactly one robots meta tag in `index.html` `<head>`:
  - `<meta name="robots" content="index,follow">`
- Placed immediately after `<meta charset="utf-8">` and before the viewport meta tag.
- Did not touch intro animation, canvas, favicon, or any other markup/style.

## Decisions (+why)
- Inserted the meta tag rather than replacing existing head content; grep confirmed no prior `robots` meta tag existed.
- Used double-quoted attributes to match the existing meta tag style in the file.
- Skipped `npm run build`, `npm run lint`, and `npx tsc --noEmit` per the task's explicit charter override.

## Open questions
- None for the code change itself.

## Do not repeat
- Do not add additional robots meta tags; acceptance requires exactly one.

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
$ git commit -m "Add robots meta index,follow"
[feat/ab-T02-robots 7f4c143] Add robots meta index,follow
 1 file changed, 1 insertion(+)

$ git push -u origin feat/ab-T02-robots
 * [new branch]      feat/ab-T02-robots -> feat/ab-T02-robots
```

Grep verification:
```bash
$ rg 'robots' index.html
index.html:5:<meta name="robots" content="index,follow">
```

## Next hint
- Verify the robots meta renders in the DOM with exact content `index,follow` and no duplicates.
