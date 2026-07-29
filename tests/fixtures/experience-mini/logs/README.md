# Fixture agent transcript logs

These files exist so the "no agent transcript dumps" law
(`docs/proposals/experience-console-SYNTHESIS.md` §"Still reject") is tested
against something real instead of an empty string.

`wave-plans/*/handoffs/*.jsonl` fixtures point `orchestrator_fields.log` at
realistic absolute operator paths (`/Users/fixtureop/dev/agent-logs/...`).
The bodies here contain a marker plus secret shapes and operator home paths.

`tests/run-experience-tests.sh` asserts that neither the transcript body nor
the directory part of the log path ever reaches `site/experience/`. Fleet Desk
keeps the log **filename** only, as a join hint.

Nothing in this directory is a real credential.
