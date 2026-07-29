# Task packet (Conductor)

Copy into chat or save next to a one-line plan under `wave-plans/conductor/`.

## Pin / symptom

<!-- What the human sees or what broke -->

## Likely root class

<!-- e.g. RSC whitespace, dead route, allowlist gate -->

## Role seat

<!-- e.g. web-frontend | go-backend | db-architect — from fleet roles, not free text -->

## Scope

- In:
- Out:

## Done-when

<!-- Falsifiable checks -->

## Evidence / pointers

<!-- URLs, file paths, issue numbers -->

## Learning expectation

- [ ] None expected  
- [ ] Expert should add learning stub if novel (path: )

## One-line plan (for dispatch.sh)

```
1 | <role> | <task description — pipes OK> | feat/<short-kebab>
```

Grammar: `docs/plan-file-format.md`

## Dispatch (after human "go")

```bash
./scripts/dispatch.sh git@github.com:<org>/<repo>.git wave-plans/conductor/<name>.plan
```
