# module: keyvault

RBAC-authorized Key Vault with a private endpoint. Holds the Postgres admin
password, ACR admin password, and RabbitMQ credentials.

- `reader_principal_ids` → `Key Vault Secrets User` (the ACA managed identity).
- `admin_principal_ids` → `Key Vault Secrets Officer` (the Terraform deploy identity).
- `private_dns_zone_ids` empty → rely on BC Gov platform DNS policy for the PE record.

**Bootstrap vs hardened:** defaults leave public access enabled (AzureServices
bypass) so a hosted runner can write secrets on first apply. For production set
`public_network_access_enabled = false`, `network_default_action = "Deny"`, and
run Terraform from inside the VNet. Protected with `prevent_destroy`.
