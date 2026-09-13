# Handoff: Multi-Vendor README Update

## Completed

✅ **README.md updated** — Multi-vendor CLI orchestration is now front-and-center (feat/docs-readme-multi-vendor branch)

### What changed:

1. **Intro** — Updated opening paragraph to clearly state that agents run via `claude`, `kimi`, and `grok` CLIs with zero API keys. Subscription login only, no API key export.

2. **New "Operator Quickstart" section** (post "What's new", pre "Repo structure") — Comprehensive guide for running agents on owned hardware:
   - **Two modes**: co-pilot chat (single-agent, one CLI) vs fleet dispatch (multi-agent, parallel waves)
   - **Plan file format**: Full WAVE format with critical warnings about:
     * Pipe character (`|`) escaping (`\|` required inside TASK_DESCRIPTION)
     * VERDICT lines using forward slashes (`/`) not pipes
     * References `docs/plan-file-format.md` for full spec
   - **dispatch.sh usage**: git SSH URLs, Homebrew bash 4+ requirement, `--auto` and `--retries` flags
   - **workers.yaml provider_preferences**: web-frontend set to `kimi` with claude failover
   - **routing.yaml provider_failover**: Explains chains and resolution order
   - **make scorecard**: Cross-vendor rate-cap monitoring and task outcomes
   - **Worker login notes**: claude, kimi, grok login procedures; non-interactive SSH dispatch caveats without inventing secrets

3. **Restructured orchestration paths**:
   - Path A (Paperclip) — unchanged, still documented as recommended
   - Path B (Direct agent) — unchanged
   - **Path C (Fleet dispatch)** — NEW, direct dispatch.sh for multi-agent waves on owned hardware

4. **Repo structure diagram** — updated to highlight:
   - `config/workers.yaml` and `config/routing.yaml` under a new `config/` section
   - `scripts/dispatch.sh` (explicit)
   - `scripts/provider-scorecard.sh` (new)
   - `providers/lib.sh` and vendor-specific launchers

5. **Provider status table** — updated with accurate Auth + Adapter columns:
   - Claude: `claude login` + Markdown + YAML frontmatter
   - Kimi: `kimi login` + `providers/kimi/launch.sh` + role charter injection
   - Grok: `grok login` + `providers/grok/launch.sh` + role charter injection

6. **Documentation section** — reordered and expanded:
   - `docs/plan-file-format.md` moved to top (most useful for operators)
   - Added provider READMEs: `providers/kimi/README.md`, `providers/grok/README.md`

7. **All links verified** — No broken relative links introduced. Tested:
   - docs/ files ✓
   - providers/ READMEs ✓
   - learnings/ ✓
   - PAPERCLIP.md ✓

### Git status:
- **Branch**: `feat/docs-readme-multi-vendor`
- **Commit**: ffeae66 (Update README.md: document multi-vendor CLI orchestration...)
- **Pushed**: ✓ to origin (visible at https://github.com/Arlencho/dev-agents/pull/new/feat/docs-readme-multi-vendor)

### Next steps:

1. **Open PR** (gh not installed; manual):
   - Go to https://github.com/Arlencho/dev-agents/pull/new/feat/docs-readme-multi-vendor
   - Create draft PR with title: `docs: update README for multi-vendor CLI orchestration`
   - Mark as draft (not ready for merge)

2. **QA checklist**:
   - [ ] README renders correctly in GitHub (no markdown syntax errors)
   - [ ] All links clickable and resolve
   - [ ] Code examples are syntactically valid (WAVE format examples)
   - [ ] A new operator can follow Quickstart section to run `./scripts/dispatch.sh` with kimi failover
   - [ ] Make scorecard runs successfully post-dispatch
   - [ ] Paperclip sections still accurate and functional

3. **Merge criteria**:
   - All links verified ✓
   - No broken code examples
   - Internal review: orchestration paths are clear, multi-vendor is front-and-center
   - CTO approval (architectural decision to lead with dispatch.sh over Paperclip for owned hardware)

## Reference

- **Plan file format spec**: `docs/plan-file-format.md`
- **Provider details**:
  - Kimi: `providers/kimi/README.md`
  - Grok: `providers/grok/README.md`
- **Architecture**: `docs/architecture.md` (multi-machine dispatch topology)
- **Issue lifecycle**: `docs/issue-lifecycle.md` (how to track PRs)

## Credentials / Secrets

**None committed.** Login procedures reference standard CLI commands only:
- `claude login` → device-code OAuth
- `kimi login` → device-code OAuth
- `grok login` → device-code OAuth

Non-interactive dispatch note mentions Keychain access but does not document any credentials (intentional — per spec "do not invent secrets").
