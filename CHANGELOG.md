# Changelog

This file records notable repository and operational changes. It starts with the
current documentation baseline; earlier history is available in Git.

## Unreleased

### Documentation

- Added the documentation gap register and the security, operations, catalog,
  CI/CD, testing, troubleshooting, recovery, variable, and compatibility guides.
- Corrected the Node OIDC proxy contract to describe the deployed email principal,
  `sec-roles` header, XML security service, machine-auth passthrough, session
  behavior, and gateway trust boundary.

### Known Operational Follow-ups

- Integration tests are not yet called by GitHub Actions.
- Optional Terraform variables listed in workflow comments need explicit mapping
  before operators rely on them.
- RabbitMQ storage still has a proof-of-concept public-network configuration.
- Backup, restore, RTO, and RPO values require service-owner approval and testing.
