# Handoff: next 16.3.3 security bump, branch fix/next-rce-advisories

PR #2795 (open, NOT merged). Commit a57552c4. Files: apps/web/package.json, package-lock.json.

## Built

- `next` `^16.2.11` -> `^16.3.3` (lowest version clearing GHSA-p293-qw3h-jr36 and GHSA-2xp9-vwfh-vxw4).
- `maplibre-gl` `^6.0.0` -> `^6.4.1` (clears critical GHSA-jrc7-96c5-q579).
- `@redocly/openapi-core` 1.34.19 -> 1.34.20 transitively, which unpins `js-yaml` 4.3.1 -> 4.3.2 (clears high GHSA-2883-xcg3-v3hh).
- Root `package-lock.json` updated. Root `package.json` unchanged.

## Decisions

- **The task brief was wrong that all 3 audit findings were in `next`.** They are three separate
  packages: next (2 criticals), maplibre-gl (1 critical), js-yaml (1 high). Verified with
  `npm audit --json` before editing. Fixed all three because the stated bar was audit exit 0.
- **Took 16.3.3, not 16.3.4.** Brief asked for the lowest clearing version. npm's caret resolution
  wants the newest, so the versions were pinned via
  `npm install next@16.3.3 maplibre-gl@6.4.1 --workspace apps/web`, which writes the caret floor
  in the manifest and the exact version in the lock (matches dependabot's convention here).
- **Refused full lockfile regeneration.** It resolves js-yaml correctly but drifts 111 packages
  including React 19.2.8 -> 18.3.1, a major downgrade. Used a targeted
  `npm update @redocly/openapi-core` then `npm update js-yaml` instead. Final drift: 13 versions,
  0 added, 0 removed.
- **Exposure assessed from source, in the PR body.** Windows RCE not reachable (Vercel/Linux).
  AVIF RCE not reachable as configured: all 4 `next/image` call sites pass `unoptimized`, there is
  no `images` block in `next.config.ts` so `formats` is the default `["image/webp"]`,
  `remotePatterns` is `[]`, and there are no `.avif` files in `apps/web/public/`.

## Do not repeat

- **Do not hand-edit `package-lock.json`.** I deleted the js-yaml entries with a Python script to
  force re-resolution; npm then pruned js-yaml entirely and `npm ls` returned an empty tree.
  Recovered with `git checkout -- package-lock.json`. Costly detour.
- **Do not bother editing the `js-yaml` override in root `package.json`.** `@eslint/eslintrc@3.3.7`
  already declares `^4.3.2` natively, so bumping that override from `^4.3.0` to `^4.3.2` changes
  nothing. The actual blocker was redocly's exact `4.3.1` pin.
- **`npm install` does not re-apply `overrides` to an already-locked transitive.** `npm update <pkg>`
  does. That asymmetry cost several cycles.
- Running `npm install <pkg>@<version> -w apps/web` against a dirty tree de-hoisted `next` and
  `maplibre-gl` into `apps/web/node_modules`. Wipe `node_modules` first to preserve hoisting.

## Evidence

All exit codes captured directly, not after a pipe. In `apps/web`:

```
npm audit --audit-level=moderate   -> 0   (found 0 vulnerabilities; was 1)
npx tsc --noEmit                   -> 0
npm run test                       -> 0   331 files, 4659 tests passed
npm run build                      -> 0
npm run lint                       -> 0
```

Lock drift, `git show HEAD:package-lock.json` vs working copy: 13 version changes
(next + 9 @next/swc-* + @next/env, maplibre-gl, @redocly/openapi-core, js-yaml), 0 added, 0 removed.

## Open questions

- **E2E critical lane was NOT run locally.** It dual-boots Next + the real Go API and needs a
  migrated Postgres and Redis; `docker info` exits 1 on this machine and `DATABASE_URL` is unset.
  CI's `e2e-critical` job is the gate to check before merging.
- `eslint-config-next` is still 16.3.1 while `next` is 16.3.3. Lint passes, so it was left alone
  rather than widening the diff. Dependabot will catch up.
- Longer term, `@redocly/openapi-core` is at 2.52.0 upstream vs our 1.34.20 (via
  `openapi-typescript@7.13.0` in `packages/api-client`). That is api-designer scope, not touched.
