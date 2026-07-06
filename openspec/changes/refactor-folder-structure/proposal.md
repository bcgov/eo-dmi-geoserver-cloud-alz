## Why

Today, infrastructure-as-code artifacts (Terraform modules, stack configuration, deployment scripts, and Spring Boot deployment configuration) are scattered across the repository root (`modules/`, `stack/`, `scripts/`, `deployment-config/`), making the project structure unclear and difficult to navigate. Grouping these infrastructure-related items into a dedicated `infra/` folder will:
- Establish clear separation of concerns between application code and infrastructure
- Improve onboarding for new team members
- Make CI/CD workflows and local development scripts more intuitive
- Align with common infrastructure-as-code project patterns

## What Changes

- Create a new `infra/` root folder containing all infrastructure-as-code artifacts
- Move `modules/`, `stack/`, `scripts/`, and `deployment-config/` under `infra/`
- Update all relative path references in:
  - Terraform files (`stack/main.tf`, `stack/rabbitmq-storage.tf`, module READMEs)
  - Shell scripts (`scripts/tf.sh`, `local-run.sh`)
  - GitHub Actions workflows (`.github/workflows/terraform-deploy.yml`, `.github/dependabot.yml`)
  - Documentation files (README.md, AGENTS.md, docs/, runbook.md)
  - Configuration files (openspec/config.yaml, geo-server-app-config files)
- Update backend state configuration and CI/CD environment references to reflect new paths

## Capabilities

### New Capabilities

This is a structural refactoring with no new application capabilities. The change improves project organization and maintainability only.

### Modified Capabilities

- `infrastructure-organization`: Project structure now clearly separates infrastructure artifacts into a dedicated `infra/` folder, making it explicit that `modules/`, `stack/`, `scripts/`, and `deployment-config/` are infrastructure concerns

## Impact

**Terraform modules/stack:** No changes — module sources in `stack/main.tf` (`../modules/*`) and fileset references in `stack/rabbitmq-storage.tf` (`${path.root}/../deployment-config`) are relative paths *between* the moved folders and remain valid since all four folders move together

**Scripts:** `scripts/tf.sh` needs its `REPO_ROOT` computation and `stack_dir()` updated; `local-run.sh` and `geo-server-app-config/local-apply.sh` need stack path updates

**CI/CD:** `.github/workflows/terraform-deploy.yml` (3 references), `.github/dependabot.yml` (1 reference), and related Terraform backend configuration require updates

**Documentation:** ~23 references across README.md, AGENTS.md, docs/, geo-server-app-config/, and openspec/ documentation need to be updated

**Root-level scripts:** `local-run.sh` has 4 references to stack, tfvars, and tfplan paths that need updating

**No changes required:** 
- `geo-server-app-config/` remains at root (Python catalog-as-code application, not infrastructure)
- `integration-tests/` remains at root (application testing, not infrastructure)
- `node-oidc-proxy/` remains at root (application service, not infrastructure)
- ALZ compliance patterns, OIDC authentication, and tagging conventions remain unchanged
- Terraform state naming, environment separation, and secret management unchanged
