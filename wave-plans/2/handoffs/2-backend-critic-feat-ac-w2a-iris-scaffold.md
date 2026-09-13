# Handoff: PR #2829 round three (feat/ac-w2a-iris-scaffold)

Head after this round: `317584f3` (one commit on top of `c4dcd334`).

## Built

- `docs/operations/env-vars-api.md`: `ASSISTANT_DENIED_CLIENTS` row under `ASSISTANT_RESOURCE_URI` (B4). `scripts/check-env-vars.py` exit 0.
- `docs/operations/env-vars-iris.md`: switch 2 rewritten (two doors, API side enforced), table row for `IRIS_DENIED_HOSTS` says every message, "Set in prod by" for the four URLs now `deploy-iris.yml` from repository variables, bootstrap section replaced by "Set the URL contract before the first deploy" with `gh variable set` commands and the deterministic Cloud Run URL note (F8, N8).
- `.github/workflows/deploy-iris.yml`: job env reads the four URLs from `vars.*`; new step "Assert the edge URL contract is set" fails loud on unset or non-https values before deploy; deploy passes all four with `--update-env-vars` next to `ENVIRONMENT` (F8, N9).
- `services/iris/README.md`, `services/iris/.env.example`: every-message semantics, once per host per hour, API-side enforcement (N8, B4 sentences).
- `docs/prd/pages/assistant-channel.md` section 9: S11 ACCEPTED, co-founder sign-off 2026-09-12 (issue #2340).
- `docs/operations/deployment.md`: the one Iris sentence that repeated the old "bootstrap after first deploy" order.

## Decisions

- Repository variables, not a post-deploy `gcloud run services update`, carry the URL contract. The critic named this the cleaner option and it removes the ordering problem entirely.
- The preflight step refuses an empty or non-https value rather than deploying: `--update-env-vars "KEY="` sets the key to an empty string on the service, which reproduces the fail-closed boot with a worse error.
- No `Co-Authored-By` trailer: task, project CLAUDE.md (OLY-4) and global rules all forbid it on this repo.

## Do not repeat

- Do not edit `services/iris/internal/hostgate/hostgate.go` or `mcp.go` from the devops seat: the scope hook blocks Go under `services/`. The `DeniedSentence` comment still says PROPOSED; go-backend can update it to ACCEPTED in a follow-up (cosmetic, not a gate).
- `gh variable list` returns nothing on this repo today: the four repository variables must be created before the first Iris deploy or the new preflight step fails by design.

## Evidence

```
python3 scripts/check-env-vars.py          exit 0
make check-prd-index                        exit 0
make check-ci-wiring                        exit 0
actionlint .github/workflows/deploy-iris.yml exit 0
(cd services/iris && go test -count=1 ./...) exit 0
scope-check.sh (devops) on all 7 files      exit 0 each
git push origin feat/ac-w2a-iris-scaffold   c4dcd334..317584f3
```

## Open questions

- Nits N2, N3, N6 stand as accepted by the critic; N6 (`scripts/` not in the CI shellcheck job) is devops scope and could go in a separate small PR.
