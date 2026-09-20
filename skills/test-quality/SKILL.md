---
id: test-quality
version: 1
scope: global
summary: A test earns its place by failing on the unfixed code; assert what a person would notice, not the call you just made.
max_lines: 80
---

# Test quality

## Before you call a test done

- [ ] Run it against the unfixed code and watch it fail, in a throwaway worktree or before you apply the fix. A test that has never been red proves nothing, and quoting that red run is what a critic asks for first. [ev: tests/fixtures/fix-round-critic-rule.md]
- [ ] Assert the outcome a person would notice: the value returned, the row written, the text on screen. Not that a mock was called, and not that a function you just wrote exists.
- [ ] Name the behaviour in the test name, so a failure reads as a sentence about the product rather than about the code.
- [ ] Keep one clear reason to fail per test: a case that can fail for three reasons tells you nothing on the day it does.

## In a fix round

- [ ] Re-run the fixtures of the findings you are closing plus the one regression check you name; the full suite runs once, in the final round before merge, or in CI. [ev: tests/fixtures/fix-round-producer-rule.md]
- [ ] If a critic handed you a failing test, make it pass by changing the product, not the assertion. Weakening it is a finding of its own.

## Anti-patterns

- A test that passes both before and after the change: it is documentation with a runner attached.
- Asserting the mock: `expect(save).toHaveBeenCalled()` while nothing checks what was saved.
- Updating a snapshot to match new output without reading the diff line by line.
- Loosening an assertion (`toBeGreaterThan(0)`, `any(String)`) to get a red test green.
- A sleep or a retry added to stop a test flaking, before anyone has asked why it flakes.
