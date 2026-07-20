# Fleet L2 skill packs

Versioned playbooks injected at launch (see `docs/proposals/skills-evolution-SYNTHESIS.md`).

## Layout

```
skills/<pack-id>/SKILL.md   # required
skills/_candidates/         # promotion drafts only — never injected at runtime
```

## Rules

1. **Git is source of truth** — not `~/.claude`, `~/.grok`, or vendor skill dirs.
2. **Global** packs live here; **project** packs live in the product repo under `skills/<id>/SKILL.md` and **replace** global when the same `id` exists.
3. **Promotion:** PR only. Project → critic or human merge. Global → **human merge always**.
4. **No producer self-merge** of skill files on ordinary feature tasks.
5. Every imperative bullet should carry an `[ev: …]` citation (path, learning, brief §, or SHA).
6. Run `scripts/skills-lint.sh` before merging skill changes.

## Map

Role attachment: `config/role-skills.yaml`.  
Inject: `scripts/skill-inject.sh` (called from `scripts/run-remote.sh`).
