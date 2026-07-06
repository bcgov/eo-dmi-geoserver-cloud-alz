# Agent Configuration & Skill Registry

This file provides guidance for AI agents (Claude, Copilot, Claude Code, etc.) working on the **GeoServer Cloud on Azure Container Apps** project.

---

## Project Overview

**Project:** GeoServer Cloud on Azure Container Apps — BC Gov Azure Landing Zone (ALZ)  
**Repo:** bcgov/eo-dmi-geoserver-cloud-alz  
**Status:** Spec-driven infrastructure-as-code development  

**Tech Stack:**
- Terraform (>=1.15) — infrastructure, modules, stacks
- Python 3.14 + Typer + Pydantic v2 — catalog-as-code (geo-server-app-config/)
- GitHub Actions — OIDC federated identity, no client secrets
- Azure Container Apps — workload profiles, internal load balancer
- PostgreSQL Flexible Server + PostGIS — pgconfig catalog
- Azure Key Vault — secrets management (kv:// references in env YAML)
- Azure Container Registry — Terraform-imported images
- RabbitMQ — event bus (AMQP, Container App)
- GeoServer ACL — authorization service

---

## Conventions & Constraints

### Terraform & Infrastructure
- **Single Terraform stack** per environment; env identity injected via `TF_VAR_*` / `TFSTATE_*` env vars
- **Naming & tagging** via `infra/modules/naming/` (BC Gov ALZ mandatory tags — non-negotiable)
- **No public IPs** — gateway is the only egress point on internal LB
- **Private endpoints** + private DNS for PostgreSQL and Key Vault
- **OIDC-only auth** for Terraform state and deployments (no client secrets)
- **Never modify platform** `*-networking` resource groups

### Code & Commits
- **Conventional Commits** enforced on PR titles (amannn/action-semantic-pull-request)
- **mise.toml** is the single source of truth for all pinned tool versions
- **Pre-commit hooks** validate Terraform, YAML, formatting

### Spec-Driven Workflow
- **openspec/config.yaml** defines project context, rules, and artifact templates
- All features/bugs/refactors start as OpenSpec proposals → designs → specs → tasks
- **Change status**: proposal → approved → in-progress → complete → archived
- Each change has: proposal.md (what & why), design.md (how), specs/, tasks.md (implementation steps)

### Environments & Deployments
- **Environments:** dev / test / prod
- **CI:** PR plan only (ci.yml) — no apply on PR
- **CD:** Push to main → apply dev (cd-dev.yml); test/prod via dispatch (gated workflows)

### Key References
- **Catalog-as-code reconciliation:** geo-server-app-config/ reconciles YAML → GeoServer REST API
- **Reusable module pattern:** geoserver-service Terraform module for every GeoServer Cloud microservice
- **Secret management:** kv://vault/secret and tf://output notation in env YAML (zero hardcoded secrets)

---

## Priority Skills (All Local)

These skills are defined in `.github/skills/` and should be invoked with `/opsx:<name>` pattern.

### 🎯 TIER 1: Proposal & Discovery

#### `/opsx:propose` — **openspec-propose**
**When to use:** User wants to describe a new change and auto-generate all artifacts.  
**Input:** Change name (kebab-case) or description of what to build.  
**Output:** Complete proposal, design, specs, and tasks in one step.  
**Why:** Fast-track spec creation; ensures all artifacts follow project rules and context.  
**Key constraint:** Always follows `openspec/config.yaml` rules for proposal/design/tasks sections.

#### `/opsx:explore` — **openspec-explore**
**When to use:** User wants to explore existing changes, understand what's been proposed, or review completed work.  
**Input:** Optional change name filter or artifact name.  
**Output:** List of changes with status, artifact availability, and actionable next steps.  
**Why:** Prevents duplicate proposals; ensures awareness of ongoing work; shows which artifacts are complete.

---

### 🔨 TIER 2: Implementation

#### `/opsx:apply` — **openspec-apply-change**
**When to use:** Ready to implement tasks from an approved change.  
**Input:** Change name (auto-inferred from context if only one active).  
**Output:** Task-by-task implementation; marks tasks complete as work finishes.  
**Why:** Keeps implementation aligned with design; prevents scope creep; documents what was built.  
**Guardrail:** Do not skip tasks or modify design mid-implementation; pause and ask if issues emerge.

---

### 🔄 TIER 3: Artifact & Workflow Management

#### `/opsx:sync` — **openspec-sync-specs**
**When to use:** After implementing, sync completed tasks back to specs/design artifacts.  
**Input:** Change name.  
**Output:** Updated spec files, design diagrams, task status — all synchronized.  
**Why:** Ensures artifacts stay true-to-code; maintains runbook accuracy; unblocks dependent changes.

#### `/opsx:archive` — **openspec-archive-change**
**When to use:** All tasks are complete and implementation is merged.  
**Input:** Change name.  
**Output:** Change moved to archive; plan entries removed from active backlog.  
**Why:** Keeps OpenSpec current; prevents zombie changes; keeps planning view clean.

---

## External Skill References

For BC Gov patterns, architecture guidance, and infrastructure best practices, consult:

### BC Gov Agent Skills Repository
**URL:** github.com/bcgov/agent-skills  
**Use when:**
- Terraform patterns or Azure Landing Zone (ALZ) compliance questions
- GitHub Actions hardening (OIDC, permissions, fork-gate, secrets)
- Container security on Azure Container Apps
- PostgreSQL + PostGIS best practices
- Azure private networking (NSG, PE, service delegation)

**Key skills from bcgov/agent-skills:**
- `azure-networking` — VNet, subnet, NSG, private-endpoint patterns
- `github-actions` — BC Gov hardening for workflows, Dependabot, branch protection
- `github-repo-setup` — repository maturity assessment against BC Gov standards
- `openshift-deployment` — not directly applicable (this uses ACA), but reference for container patterns

---

## Token Optimization: RTK (Rust Token Killer)

**All agents should use RTK for shell commands.** This reduces context usage by 60-90% with zero behavior change.

### Quick Reference
```bash
# Git operations (60-80% savings)
rtk git status          rtk git diff            rtk git log

# File operations (60-75% savings)
rtk ls <path>           rtk read <file>         rtk grep <pattern>

# Testing (90-99% savings) — shows failures only
rtk pytest tests/       rtk cargo test

# Build & Lint (80-90% savings) — shows errors only
rtk tsc                 rtk lint                rtk prettier --check

# GitHub (26-87% savings)
rtk gh pr view <n>      rtk gh run list         rtk gh issue list
```

See `.github/copilot-instructions.md` for full RTK command reference.

---

## Agent Workflow Examples

### Example 1: Proposing a New Feature
```
User: "Add support for WFS 2.0 in the catalog-as-code layer"

Agent steps:
1. Recognize this is a new change → invoke `/opsx:propose`
2. Derive kebab-case name: "add-wfs-2-support"
3. Generate proposal (what & why), design (Python architecture), specs (WFS 2.0 endpoints), tasks (Python files to modify)
4. Output: "Ready for implementation. Run `/opsx:apply add-wfs-2-support` or ask me to start coding."
```

### Example 2: Implementing a Reviewed Change
```
User: "Let's implement the SSO auth update"

Agent steps:
1. Recognize this is implementation → invoke `/opsx:apply` (auto-infer "sso-auth-3x-upgrade")
2. Read all context files (proposal, design, specs, tasks)
3. Work through each task:
   - Update GitHub Actions secrets (OIDC, IDENTITY_HEADER avoid)
   - Modify Terraform for service principal
   - Update Python JDBC roles configuration
   - Test ACL authorization flow
4. Mark tasks complete as work finishes
5. On completion: "All tasks done! Run `/opsx:sync` to update specs, then `/opsx:archive` when merged."
```

### Example 3: Exploring Ongoing Work
```
User: "What's in flight right now?"

Agent steps:
1. Invoke `/opsx:explore` with no filter
2. Show all active changes (status != archived)
3. List which artifacts are complete, which need work
4. Recommend next action: "fix-catalog-schema-import is ready for implementation" or "sso-auth-3x-upgrade is waiting for design review"
```

---

## Agent Constraints & Guardrails

### Always
- ✅ Use RTK for all shell commands (saves ~70% of tokens)
- ✅ Read `.github/copilot-instructions.md` and `openspec/config.yaml` for current project state
- ✅ Consult `.github/skills/` before inventing custom prompts
- ✅ When in doubt, invoke `/opsx:explore` to see existing work before proposing new changes
- ✅ Invoke `/opsx:propose` before creating any artifacts manually

### Never
- ❌ Modify `infra/modules/naming/` or platform `*-networking` resources without explicit user consent
- ❌ Hardcode secrets into YAML/Terraform; use kv:// or tf://output notation
- ❌ Create PR without running `terraform plan` and validating against current state
- ❌ Skip the design step for changes involving networking, OIDC, or Key Vault
- ❌ Commit directly to main; always create a PR and wait for GitHub Actions validation
- ❌ Modify `mise.toml` pinned versions without updating the openspec change record

### If Uncertainty Arises
- Ask the user for clarification rather than guessing
- Suggest running `/opsx:explore` to see if similar work has been proposed
- Recommend opening an issue in GitHub if the work spans multiple changes
- Do not apply changes that fail Terraform validation

---

## Files to Know

```
openspec/
├── config.yaml                      # Project context, tech stack, rules
├── specs/catalog/spec.md            # Global catalog specification
└── changes/
    ├── fix-catalog-schema-import/   # Example completed change
    │   ├── .openspec.yaml
    │   ├── proposal.md
    │   ├── design.md
    │   ├── specs/
    │   └── tasks.md
    └── [other changes...]

.github/
├── copilot-instructions.md          # RTK token optimization guide
├── workflows/
│   ├── ci.yml                       # PR plan (no apply)
│   ├── cd-dev.yml                   # Push main → apply dev
│   ├── cd-test.yml & cd-prod.yml   # Gated dispatch deployments
│   └── terraform-deploy.yml
└── skills/                          # Local OpenSpec skills
    ├── openspec-propose/SKILL.md
    ├── openspec-apply-change/SKILL.md
    ├── openspec-sync-specs/SKILL.md
    ├── openspec-archive-change/SKILL.md
    └── openspec-explore/SKILL.md

infra/                              # All infrastructure-as-code artifacts
├── modules/                         # Reusable Terraform modules
│   ├── naming/                      # BC Gov ALZ naming, mandatory tags
│   ├── geoserver-service/           # Core service module (reused for all microservices)
│   └── [other shared modules]
├── stack/                           # Single shared Terraform stack (never modify networking RGs)
├── scripts/                         # Terraform wrapper + automation scripts
└── deployment-config/               # Spring YAML config published to ACA storage

geo-server-app-config/              # Catalog-as-code reconciliation
├── main.py                          # Reconciles YAML → GeoServer REST API
└── [Python service config structure]

AGENTS.md                           # This file — agent configuration
CLAUDE.md                           # User's private Claude Code instructions
```

---

## Questions & Troubleshooting

**Q: I'm not sure if I should propose a new change or implement an existing one.**  
A: Run `/opsx:explore` to see what's in flight. If it doesn't match, propose with `/opsx:propose`.

**Q: The Terraform plan fails with a naming error.**  
A: Consult `infra/modules/naming/` and ensure all resources follow BC Gov ALZ tagging. If adding a new resource type, update the naming module first.

**Q: What's the difference between proposal, design, and specs?**  
A: **Proposal** = what & why (business case). **Design** = how (architecture, data flow, module ownership). **Specs** = given/when/then scenarios with concrete resource types. All are enforced by openspec/config.yaml rules.

**Q: Should I commit task changes directly?**  
A: No. Use `/opsx:apply` to implement; it marks tasks complete as you go. Only commit the final code and the updated tasks.md file together.

**Q: How do I handle a change that spans multiple environments?**  
A: Propose one change with tasks for each layer: Terraform infra (dev/test/prod validation), Python catalog, GitHub Actions (if new secrets needed), docs. See openspec/config.yaml rules for structure.

---

## Version & Maintenance

**Last updated:** 2026-07-05  
**Maintained by:** GeoServer Cloud team  
**OpenSpec schema:** spec-driven (v1.5.0 compatible)  
**BC Gov alignment:** ALZ, OIDC, container security baselines

For updates or clarifications, file an issue or modify this file via spec-driven change proposal.
