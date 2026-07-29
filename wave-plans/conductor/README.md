# Conductor one-shot plans

Drop **single-task** (or tiny) plans here from Conductor mode.

```
1 | web-frontend | Fix ABarranges missing space after bold entity | feat/fix-abarranges-space
```

Then after human **go**:

```bash
./scripts/dispatch.sh git@github.com:<org>/<repo>.git wave-plans/conductor/<file>.plan
```

Grammar: `docs/plan-file-format.md`  
Contract: `docs/session-modes.md`
