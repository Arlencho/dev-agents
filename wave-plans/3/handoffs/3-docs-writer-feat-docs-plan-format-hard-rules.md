# Handoff: Plan File Format Hard Rules Documentation

**Date**: 2026-07-20  
**Branch**: `feat/docs-plan-format-hard-rules`  
**Commit**: `e619b26` (1 file changed, +38 insertions)  
**Status**: ✅ Complete

## What Was Done

Updated `docs/plan-file-format.md` with four hard rules learned from production orchestration:

### 1. Branch Naming Convention
- **Rule**: Branch is always the last field; use `feat/<slash-slug>` or `fix/<slash-slug>`
- **Format**: Kebab-case with forward slashes allowed for grouping
- **Examples**:
  - ✅ Good: `feat/payments-db`, `fix/auth-token`, `feat/api/payment-endpoints`
  - ❌ Bad: `feat-payments_db`, `feat/PAYMENTS_DB`, `payments-db` (no scope)

### 2. Task Description — No Unescaped Pipes
- **Rule**: Never put unescaped pipe characters (`|`) in task descriptions
- **Reason**: Plan files are pipe-delimited; unescaped pipes break parser
- **Verdict spacing**: Use space-separated format for decisions:
  - ✅ Good: `review payment service — verdict PASS` or `audit code: REVISE async patterns`
  - ❌ Bad: `review | PASS | approved` or `verdict: PASS | REVISE | BLOCK`

### 3. Producer-Critic Wave Sequencing
- **Rule**: When Producer and Critic work on the same branch, they must be in different waves
- **Rationale**: Eliminates race conditions; Critic needs Producer's commits to exist
- **Example**:
  ```
  2 | go-backend     | implement payment service              | feat/payments-svc
  3 | backend-critic | review payment service implementation | feat/payments-svc
  ```

### 4. Critic Tasks on Existing Branches
- **Rule**: When Critic reviews an existing branch, `run-remote` automatically checks it out
- **Implication**: No need to add branch creation logic to task description
- **Example**: A Critic task can reference `main` or any pre-existing branch

## Verification

✅ **Format table preserved**: Lines 13–18 unchanged  
✅ **No contradictions with README**:
- README's producer-critic pattern (lines 10, 20–48, 249–252) aligns perfectly
- README's wave-ordering and dependency rules fully compatible
- No conflicts with existing orchestration guidance

✅ **All examples syntactically valid**:
- Branch names follow kebab-case conventions
- Task descriptions use correct verdict spacing
- Wave sequencing examples runnable

✅ **Markdown renders correctly**: All headings, code blocks, tables properly formatted

## What's Next

1. **Manual PR creation** (gh CLI unavailable in environment):
   - Visit: https://github.com/Arlencho/dev-agents/pull/new/feat/docs-plan-format-hard-rules
   - Use PR body template below

2. **PR Title**:
   ```
   docs: add hard rules to plan-file-format.md
   ```

3. **PR Body**:
   ```markdown
   ## Summary
   
   Documented four critical rules learned in production orchestration of wave plans:
   
   1. **Branch naming** — always last field, use `feat/slash-slug` format with scope prefix
   2. **Task description safety** — never use unescaped pipes (`|`); use space-separated verdicts like `PASS / REVISE / BLOCK`
   3. **Producer-Critic sequencing** — different waves required when both work same branch (eliminates race conditions)
   4. **Critic branch checkout** — `run-remote` automatically checks out the specified branch for critic review tasks
   
   Existing format table preserved. No contradictions with README's producer-critic invariants or wave-ordering rules.
   
   ## Checklist
   
   - [x] Format table preserved
   - [x] All hard rules documented with examples
   - [x] No contradictions with README or existing orchestration patterns
   - [x] Examples show correct spacing and branch naming
   - [x] Rationale included for each rule
   
   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   ```

4. **Merge requirements**:
   - Squash-merge preferred (1 commit, clean history)
   - No additional changes needed — this is documentation-only
   - No test coverage required for docs

## Files Changed

- `docs/plan-file-format.md` — +38 insertions in "Hard Rules (Production-Learned)" section

## Testing Done

1. ✅ Verified existing format table still present and correct
2. ✅ Checked all relative links resolve (none added)
3. ✅ Validated markdown syntax and table formatting
4. ✅ Reviewed README for contradictions — none found
5. ✅ Confirmed examples are syntactically valid

## Rollback Plan

If this needs to be reverted:
```bash
git revert e619b26
git push origin feat/docs-plan-format-hard-rules
```

## Notes

- **No code changes**: Documentation-only update
- **No new dependencies**: Pure markdown addition
- **Backward compatible**: Existing plans remain valid; new rules add clarity
- **Production-validated**: Rules derived from live orchestration failures
