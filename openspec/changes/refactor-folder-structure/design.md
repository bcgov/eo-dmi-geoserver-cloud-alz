## Context

The GeoServer Cloud project currently has infrastructure-as-code artifacts scattered at the repository root alongside application code:

**Current structure:**
```
repo-root/
├── modules/                 # 9 reusable Terraform modules (ALZ-compliant)
├── stack/                   # Single shared Terraform root module for all environments
├── scripts/                 # Terraform automation and utility scripts
├── deployment-config/       # Spring YAML configuration for ACA deployment
├── geo-server-app-config/   # Python catalog-as-code application
├── integration-tests/       # Application integration tests
├── node-oidc-proxy/        # OIDC proxy service
├── docs/                   # Documentation
└── ...
```

This mixing of infrastructure and application artifacts makes it unclear which items are infrastructure concerns vs. application code, particularly for developers and operators unfamiliar with the repo structure.

## Goals / Non-Goals

**Goals:**
- Create a clear organizational boundary between infrastructure-as-code and application code
- Group all Terraform modules, root stack, deployment scripts, and environment configuration under a dedicated `infra/` folder
- Make relative path references in Terraform, CI/CD, and documentation accurate and maintainable
- Establish a pattern that scales as infrastructure grows (e.g., future Helm charts or Pulumi code could follow a similar structure)

**Non-Goals:**
- Restructure application code (`geo-server-app-config/`, `node-oidc-proxy/`, `integration-tests/`)
- Change Terraform remote state naming, environment separation, or OIDC authentication patterns
- Modify ALZ compliance patterns, tagging conventions, or module interfaces
- Introduce new tooling or CI/CD automation (path updates only)
- Change deployment or reconciliation workflows

## Decisions

### Decision 1: Create `infra/` root folder

**Choice:** Create a new `infra/` folder containing `modules/`, `stack/`, `scripts/`, and `deployment-config/`.

**Rationale:**
- Clear organizational intent: `infra/` signals this folder contains infrastructure-as-code only
- Aligns with community conventions (Terraform documentation examples, Enterprise Terraform patterns)
- Minimal disruption: moves 4 existing folders but does not rename them, keeping internal module references short (`../modules/naming`)
- Scales: future infrastructure code (Helm charts, CloudFormation, Pulumi) can naturally follow the same pattern

**Alternatives considered:**
1. **Rename `stack/` to `terraform/` and keep other folders at root** — Creates confusion about where related modules/scripts belong; doesn't solve the "scattered artifacts" problem
2. **Flat structure with prefix: `tf-modules/`, `tf-stack/`, `tf-scripts/`** — More explicit but harder to read; doesn't improve grouping visually
3. **Separate infrastructure and application into top-level `src/` and `infra/`** — Too invasive; requires moving `geo-server-app-config/`, `node-oidc-proxy/` which are application code

### Decision 2: Preserve internal folder names (modules/, stack/, scripts/, deployment-config/)

**Choice:** Do not rename folders inside `infra/`; keep them as `infra/modules/`, `infra/stack/`, `infra/scripts/`, `infra/deployment-config/`.

**Rationale:**
- Reduces churn: module sources in `stack/main.tf` (`../modules/naming`) remain unchanged because stack and modules move together, preserving their relative relationship
- Maintains consistency: external references to modules (e.g., in documentation, examples) are easier to understand if the structure mirrors the folder names
- Preserves semantic clarity: `infra/stack/` is the "root Terraform stack" residing in the infrastructure folder

**Alternatives considered:**
1. **Flatten: move all modules/stack files directly into `infra/`, eliminating subfolders** — Breaks Terraform module source references entirely; harder to extend in the future
2. **Rename to shorter names: `infra/tf/`, `infra/config/`** — Loses semantic meaning; readers don't know what's a module vs. a configuration file

### Decision 3: Update paths in-place; no git history rewrite

**Choice:** Use standard git `mv` to move folders (preserves history) and update references in a single PR.

**Rationale:**
- Standard git tooling; no force-pushes or history rewrites
- Authorship and blame remain intact for each file
- CI/CD can be temporarily disabled during the transition to avoid plan/apply conflicts
- Single PR is easier to review and merge than incremental path updates

**Alternatives considered:**
1. **Incremental updates (update paths first, then move folders)** — Introduces a broken state where paths don't match folder locations; harder to test and debug
2. **BFG or git-filter-branch rewrite** — Overly complex for a folder move; breaks external references and tools relying on commit SHAs

### Decision 4: Update CI/CD and documentation in the same PR

**Choice:** Include all path updates (workflows, documentation, openspec config) in a single PR.

**Rationale:**
- Single point of truth: no inconsistency between deployed code and documentation
- Easier to review: all cross-references are verified in one change
- No transient documentation rot: readers won't encounter stale path examples

**Alternatives considered:**
1. **Update CI/CD first, then documentation in follow-up PR** — Introduces window where docs don't match actual paths; confuses users
2. **Leave documentation updates for later** — Permanent documentation rot; poor DX for newcomers

## Risks / Trade-offs

**Risk 1: Broken CI/CD during migration**
- **Mitigation:** Disable CI/CD (prevent auto-runs) during the move, or merge the PR and verify pipeline passes immediately
- **Mitigation:** Keep local development unaffected by ensuring all relative paths are updated in one commit

**Risk 2: Merge conflicts if in-flight PRs reference old paths**
- **Mitigation:** Coordinate the timing: merge this PR early in the sprint or late on Friday to minimize overlapping branches
- **Mitigation:** Communicate the change in advance; provide a short guide for rebasing in-flight work

**Risk 3: External documentation and examples pointing to old paths**
- **Mitigation:** Update README.md, AGENTS.md, docs/, and architecture ADRs in this PR
- **Mitigation:** No external mirrors or documentation sites are maintained; internal docs are authoritative

**Risk 4: State file corruption if Terraform runs during the move**
- **Mitigation:** Lock Terraform (disable CD/CD workflows, coordinate with team) before moving folders
- **Mitigation:** No state file reference changes required; state paths remain the same (via `${TFSTATE_*}` env vars)

**Trade-off 1: Relative path complexity**
- After the move, relative paths become slightly longer (`../infra/modules/naming` vs. `../modules/naming`), but this is a minor readability cost for improved organization
- Mitigated by consistency and clarity: the folder structure is immediately obvious to new team members

**Trade-off 2: One-time effort to update all references**
- Approximately 29 files require path updates (as discovered in analysis)
- One-time cost; no ongoing maintenance burden

## Migration Plan

**Phase 1: Preparation**
1. Create the `infra/` folder at repo root
2. Prepare `git mv` commands for all four subfolders (modules/, stack/, scripts/, deployment-config/)

**Phase 2: Move and update**
1. Execute `git mv` for each folder to move under `infra/`
2. Update all relative path references in:
   - Terraform files (stack/main.tf, stack/rabbitmq-storage.tf, module READMEs)
   - Shell scripts (scripts/tf.sh, local-run.sh)
   - GitHub Actions workflows (.github/workflows/terraform-deploy.yml, .github/dependabot.yml)
   - Documentation (README.md, AGENTS.md, docs/, geo-server-app-config/)
   - openspec/config.yaml
3. Run `terraform validate` in the new `infra/stack/` to verify module sources resolve correctly
4. Run `local-run.sh` locally to verify local development workflow still works

**Phase 3: Testing & deployment**
1. Create PR with all changes
2. Verify CI/CD pipeline passes (plan should show no infrastructure changes, only path updates in configs/docs)
3. Merge when ready; monitor CD workflow for dev deployment
4. Verify Terraform state remains intact and dev environment is unchanged

**Rollback strategy:**
- If merged but broken: revert the PR (single revert commit)
- Git history is preserved (no BFG); rollback is straightforward
- No manual state file recovery needed; `terraform state` is unaffected

## Open Questions

None. The folder structure is clear, cross-references are well-documented, and the path is straightforward. Ready to proceed with tasks.
