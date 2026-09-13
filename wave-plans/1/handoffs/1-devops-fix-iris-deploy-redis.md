# Handoff: fix/iris-deploy-redis (Refs #2800)

## Built
- `.github/workflows/deploy-iris.yml`: job env `REDIS_SECRET=olympus-redis-url`; new step `redis_secret` (after the URL-contract gate, before deploy) that runs `gcloud secrets describe` and fails with a one-line `::error::` naming the secret; deploy step gains `--update-secrets "REDIS_URL=${REDIS_SECRET}:latest"`, `--vpc-connector olympus-connector`, `--vpc-egress private-ranges-only`; existing `--update-env-vars` merge untouched; comments cite runs 34749946399 and 34750281551, revisions 00004-fh2 / 00005-d6q (failed) and 00006-5cz (hand-applied).
- `docs/operations/env-vars-iris.md`: `REDIS_URL` row now states the exact flag, the pre-deploy assertion, the incident, and that Upstash is reached directly (not via the connector). Two "the scaffold reads no secret" sentences corrected; intro above the table mentions the attach.
- `docs/operations/deployment.md`: Iris step list renumbered with the new gate; new subsection "Redis secret and VPC connector (every deploy)"; "First deploy only" paragraph corrected.

## Decisions
- Secret name lives once, in job env, so the assertion and the flag cannot drift.
- Assertion is `gcloud secrets describe` (existence), not `versions describe latest`. A secret with no version fails `gcloud run deploy` itself, which is already a workflow error, so the narrower check is enough for the stated goal.
- Handoff file left untracked on purpose: not ignored in this repo and never committed before.

## Do not repeat
- The task premise "exactly what deploy-api.yml already passes" is only half true: deploy-api.yml passes the VPC pair on the `olympus-migrate` job only, and passes no `REDIS_URL` flag at all; the API *service* carries both out of band. Do not go looking for a `--update-secrets REDIS_URL` line in deploy-api.yml.
- `olympus-redis-url` is an Upstash `rediss://` URL (public). With `private-ranges-only` the connector is not on the Redis path. The docs say so; do not "fix" them to claim the connector is what makes Redis reachable.
- `scripts/check-env-vars.py` gates `env-vars-api.md` only (DOC_FILE constant). It does not cover Iris; running it is a no-op for this change.
- This machine's `grep` is ugrep; `grep '^+'` inside a pipeline errors. Use `grep -F` or `cut -c1`.

## Evidence
- `actionlint .github/workflows/deploy-iris.yml` exit=0 (whole set exit=1 from three pre-existing SC2016 infos in project-automation.yml, untouched).
- `make check-ci-wiring` exit=0 (27 jobs wired, self-test 15 cases).
- `python3 scripts/check-env-vars.py` exit=0 (covers env-vars-api.md only).
- `bash -n` on both edited `run:` blocks exit=0; step order `urls -> redis_secret -> deploy` confirmed by parsing the YAML.
- Assertion command against the real project: existing secret exit=0, absent name exit=1.
- Live state read before editing: `olympus-iris-00007-2vb` carries `REDIS_URL` secretKeyRef + `olympus-connector` / `private-ranges-only`; revision creators: 00004/00005/00007 github-actions SA, 00006 arlen@olympus-ai.tech at 2026-09-13T09:50:36Z.
- House style: no U+2014/2013/2015, no fake ` -- ` in prose, no vendor names, no Co-Authored-By in the added lines (grep exit codes 1/1/1, count 0).

## Open questions
- Keep the connector pair on Iris or not? Nothing in Iris dials a private range. It is passed to match the live revision and the API's posture; dropping it is a two-line change (workflow + deployment.md subsection).
- `IRIS_QUOTA_DAILY_CAP_MICROS` row says "Set in prod by deploy-iris.yml" but the workflow does not pass it (the code default applies). Out of scope here; worth a follow-up row fix.
