> **Correction note:** Because `modules/`, `stack/`, `scripts/`, and `deployment-config/` all move
> together under `infra/`, relative references *between* them (e.g. `../modules/naming` in
> `stack/main.tf`, `${path.root}/../deployment-config` in `rabbitmq-storage.tf`) remain valid and
> must NOT be changed. Only references from files *outside* `infra/` need updating.

## 1. Move Folders to infra/

- [x] 1.1 Verify pre-existing uncommitted changes are preserved (branch `chore/folder-structure` has in-flight edits to `.gitignore`, `README.md`, deleted `stack/.terraform.lock.hcl`)
- [x] 1.2 Move the four folders: `git mv modules infra/modules`, `git mv stack infra/stack`, `git mv scripts infra/scripts`, `git mv deployment-config infra/deployment-config`
- [x] 1.3 Verify all four folders are under `infra/` and git tracked the renames

## 2. Terraform Files (intra-infra — verify only, no changes)

- [x] 2.1 Confirm `infra/stack/main.tf` module sources (`../modules/*`) still resolve (no edit needed)
- [x] 2.2 Confirm `infra/stack/rabbitmq-storage.tf` fileset (`${path.root}/../deployment-config`) still resolves (no edit needed)

## 3. Shell Scripts

- [x] 3.1 `infra/scripts/tf.sh`: fix `REPO_ROOT` computation (`/..` → `/../..`) and `stack_dir()` (`${REPO_ROOT}/stack` → `${REPO_ROOT}/infra/stack`); update usage strings/comments (`./scripts/tf.sh` → `./infra/scripts/tf.sh`)
- [x] 3.2 `local-run.sh`: update 3 refs — `VARFILE` (line ~36), `stack_dir` (line ~175), `TFPLAN` (line ~254): `${REPO_ROOT}/stack` → `${REPO_ROOT}/infra/stack`
- [x] 3.3 `geo-server-app-config/local-apply.sh`: `STACK_DIR="${REPO_ROOT}/stack"` → `${REPO_ROOT}/infra/stack`; comments `../scripts/tf.sh` → `../infra/scripts/tf.sh`, `../stack` → `../infra/stack`

## 4. CI/CD

- [x] 4.1 `.github/workflows/terraform-deploy.yml`: `terraform -chdir=stack` → `-chdir=infra/stack` (3×), `./scripts/tf.sh` → `./infra/scripts/tf.sh` (3×), artifact `path: stack/tfplan` → `infra/stack/tfplan`, `path: stack` → `infra/stack`, `--stack-dir "$GITHUB_WORKSPACE/stack"` → `.../infra/stack` (2×), comments (2×)
- [x] 4.2 `.github/dependabot.yml`: `/modules/*` → `/infra/modules/*`, `/stack` → `/infra/stack`

## 5. geo-server-app-config (stays at root, references move)

- [x] 5.1 `geoserver_apply.py`: default `--stack-dir` `Path("../stack")` → `Path("../infra/stack")`
- [x] 5.2 `geoserver_client.py`: comments referencing `stack/main.tf` → `infra/stack/main.tf`
- [x] 5.3 `environments/*.yaml` (dev/test/prod/tools): comment `terraform -chdir=../stack` → `-chdir=../infra/stack`
- [x] 5.4 `geo-server-app-config/README.md`: `../stack/` → `../infra/stack/` (2×)

## 6. Documentation & Config

- [x] 6.1 `README.md`: update all `scripts/`, `stack/`, `modules/`, `deployment-config/` path refs and the folder-structure diagram
- [x] 6.2 `AGENTS.md`: update refs (`modules/naming/`, folder structure diagram, `stack/`)
- [x] 6.3 `docs/architecture.md`: update `modules/*` and `stack/*` refs
- [x] 6.4 `docs/runbook.md`: update `scripts/tf.sh` and `stack/*` refs
- [x] 6.5 `SECURITY_ANALYSIS-local.md`: update `modules/*`, `stack/*`, `deployment-config/*` location refs
- [x] 6.6 `openspec/config.yaml`: update `modules/`, `stack/` refs

## 7. Validation

- [x] 7.1 Repo-wide grep confirms no stale references to old root-level paths remain (excluding openspec/changes/ history and CHANGELOG-type files)
- [x] 7.2 `terraform -chdir=infra/stack init -backend=false && terraform -chdir=infra/stack validate` passes
- [x] 7.3 `bash local-run.sh --help` (or equivalent syntax check) passes; `bash -n infra/scripts/tf.sh` passes
- [x] 7.4 Git history preserved: `git log --follow --oneline -- infra/stack/main.tf` shows pre-move history
