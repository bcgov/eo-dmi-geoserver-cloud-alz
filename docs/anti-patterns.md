# Catalog and Deployment Anti-Patterns

This note explains the design constraints used by the catalog-as-code tool.

## Do Not Use String Templating for Catalog Values

Do not use Jinja, Helm-style interpolation, or unrestricted string replacement in
catalog YAML. Catalog values are parsed and validated by Pydantic before secret
resolution. Use explicit `kv://` and `tf://` references in environment files.

This prevents accidental substitutions in namespace URIs, layer names, styles,
and passwords.

## Do Not Put Secrets in Catalog Files

Use:

```text
kv://<vault-name>/<secret-name>
tf://<terraform-output-name>
```

Do not commit passwords, authkeys, OIDC secrets, session secrets, or Terraform
state. Secret values are resolved at apply time.

## Do Not Treat Reconciliation as a Transaction

`geoserver-apply` is idempotent at the resource operation level, but one apply
can update several resources before a later request fails. It does not provide a
rollback transaction. Validate, dry-run, apply, inspect the summary, and rerun
after fixing the failed resource.

## Do Not Use a Broad Read Rule Without Operation Scope

A broad `ROLE_AUTHENTICATED` read rule can match a WFS transaction unless a
narrow deny or allow rule is evaluated first. Use the priority and
`service`/`request` pattern in `docs/catalog-reference.md`.

## Do Not Use a Shared Machine-Client Role for Workspace Isolation

A shared role gives every holder the same ACL grant. Use one authkey identity per
machine client and a username-scoped ACL rule for each workspace or dataset.

## Do Not Remove Only One Machine-Client Record

Machine-client state exists in Key Vault, GeoServer user data, and ACL rules.
Remove or revoke all three records in the documented order.
