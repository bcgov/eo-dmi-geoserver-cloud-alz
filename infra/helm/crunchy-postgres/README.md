# Crunchy Postgres OpenShift Helm Chart

This chart vendors the Crunchy Postgres Operator templates from the
`bcgov/action-crunchy` repository at commit
`ab3db55f4d26e14f79fa89884f3ac2460109bd76` and owns the `PostgresCluster` used
by the separate GeoServer Cloud chart.

Install it first. The default release and database cluster name is
`crunchy-postgres`. The chart uses the Helm release name as the database cluster
name. Set `crunchy.fullnameOverride` only when the cluster name must differ from
the release name:

```powershell
helm upgrade --install crunchy-postgres infra/helm/crunchy-postgres `
  --namespace geoserver-dev `
  --create-namespace=false `
  -f infra/helm/crunchy-postgres/values/values-dev.yaml `
  --wait --timeout 20m
```

Custom release example:

```powershell
$env:CRUNCHY_RELEASE_NAME = "crunchy-test"
helm upgrade --install $env:CRUNCHY_RELEASE_NAME infra/helm/crunchy-postgres `
  --namespace geoserver-dev `
  --set-string crunchy.fullnameOverride="$env:CRUNCHY_RELEASE_NAME" `
  --wait --timeout 20m
```

The chart renders the operator resource from the release name. For release
`crunchy-postgres` and user `postgres`, the operator creates:

- pgBouncer Service: `crunchy-postgres-pgbouncer`
- user Secret: `crunchy-postgres-pguser-postgres`
- Secret keys: `dbname`, `port`, `user`, and `password`

The GeoServer chart receives the release name explicitly:

```powershell
helm upgrade --install geoserver-cloud infra/helm/geoserver-cloud `
  --namespace geoserver-dev `
  -f infra/helm/geoserver-cloud/values/values-dev.yaml `
  --set-string database.crunchyReleaseName=crunchy-postgres `
  --set-string secrets.runtime.oidcClientSecret="$env:OIDC_CLIENT_SECRET" `
  --wait --timeout 20m
```

Do not install this chart and the GeoServer chart as one Helm release. The
GeoServer release waits for the operator-created Secret and pgBouncer Service
before application containers start.

The Crunchy Operator and its CRDs must already exist in the target cluster.
The chart uses PostgreSQL 18 with PostGIS 3.6 and the approved BC Government
Artifactory image by default. Environment overlays adjust instance count and
backup retention without changing the imported template contract.
