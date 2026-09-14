param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
)

$ErrorActionPreference = "Stop"
$chartRoot = Join-Path $RepoRoot "infra\helm\geoserver-cloud"
$crunchyRoot = Join-Path $RepoRoot "infra\helm\crunchy-postgres"
$devValues = Join-Path $chartRoot "values\values-dev.yaml"
$renderedPath = Join-Path $env:TEMP "geoserver-cloud-review-rendered.yaml"
$crunchyRenderedPath = Join-Path $env:TEMP "crunchy-postgres-review-rendered.yaml"

function Assert-Contains {
  param([string]$Content, [string]$Expected, [string]$Message)
  if ($Content -notmatch [regex]::Escape($Expected)) {
    throw "${Message}: expected to find '$Expected'"
  }
}

function Assert-NotContains {
  param([string]$Content, [string]$Unexpected, [string]$Message)
  if ($Content -match [regex]::Escape($Unexpected)) {
    throw "${Message}: did not expect to find '$Unexpected'"
  }
}

function Assert-Matches {
  param([string]$Content, [string]$Pattern, [string]$Message)
  if ($Content -notmatch $Pattern) {
    throw "${Message}: pattern '$Pattern' did not match"
  }
}

function Assert-NotMatches {
  param([string]$Content, [string]$Pattern, [string]$Message)
  if ($Content -match $Pattern) {
    throw "${Message}: pattern '$Pattern' unexpectedly matched"
  }
}

function Assert-StorageAtMostOneGi {
  param([string]$Content, [string]$Message)
  $storageMatches = [regex]::Matches($Content, '(?m)^\s+storage:\s+([0-9]+)(Ki|Mi|Gi|Ti)\s*$')
  foreach ($storageMatch in $storageMatches) {
    $amount = [int64]$storageMatch.Groups[1].Value
    $unit = $storageMatch.Groups[2].Value
    $mebibytes = switch ($unit) {
      "Ki" { $amount / 1024 }
      "Mi" { $amount }
      "Gi" { $amount * 1024 }
      "Ti" { $amount * 1024 * 1024 }
    }
    if ($mebibytes -gt 1024) {
      throw "${Message}: found $($storageMatch.Groups[1].Value)$unit"
    }
  }
}

$helmArgs = @(
  "template",
  "geoserver-cloud",
  $chartRoot,
  "--namespace",
  "geoserver-dev",
  "-f",
  $devValues,
  "--set-string",
  "database.crunchyReleaseName=crunchy-postgres",
  "--set",
  "serviceDefaults.port=9090",
  "--set",
  "serviceDefaults.autoscaling.enabled=true",
  "--set",
  "services.gateway.port=9191",
  "--set",
  "services.wms.replicas=1"
)
$rendered = (& helm @helmArgs 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
  throw "GeoServer chart render failed: $rendered"
}
$rendered | Set-Content -Path $renderedPath -Encoding utf8

$customReleaseArgs = @(
  "template",
  "geoserver-test",
  $chartRoot,
  "--namespace",
  "geoserver-dev",
  "-f",
  $devValues,
  "--set-string",
  "database.crunchyReleaseName=crunchy-postgres"
)
$customRendered = (& helm @customReleaseArgs 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
  throw "GeoServer custom release render failed: $customRendered"
}
Assert-Contains $customRendered "name: geoserver-test-runtime" "Non-default GeoServer releases must derive the runtime Secret name"

Assert-Contains $rendered "artifacts.developer.gov.bc.ca/bcgov-docker-local/node-oidc-proxy:" "Proxy image must use the Artifactory local repository"
Assert-NotContains $rendered "ghcr.io/bcgov/eo-dmi-geoserver-cloud-alz/node-oidc-proxy" "Proxy image must not bypass Artifactory"
Assert-Contains $rendered '"helm.sh/hook": pre-install,pre-upgrade' "Database initialization must run before application workloads"
Assert-NotContains $rendered '"helm.sh/hook": post-install,post-upgrade' "Database initialization must not run after application readiness"
Assert-Contains $rendered "eo-dmi-geoserver-dev.apps.silver.devops.gov.bc.ca" "Development values must provide the development hostname"
Assert-NotContains $rendered "eo-dmi-geoserver-test.apps.silver.devops.gov.bc.ca" "Development render must not use the test hostname"
Assert-Contains $rendered "checksum/config:" "Service pods must roll when the shared ConfigMap changes"
Assert-Contains $rendered "value: http://acl:9090" "ACL target must use the configured service port"
Assert-Contains $rendered "value: http://rest:9090" "REST target must use the configured service port"
Assert-NotContains $rendered "http://acl:8080" "Rendered configuration must not retain a hardcoded ACL port"
Assert-Contains $rendered 'value: "http://gateway:9191"' "Proxy origin must use the configured gateway service port"
Assert-Contains $rendered "cpu: 500m" "GeoServer JVM requests must include a realistic CPU baseline"
Assert-Contains $rendered "memory: 1Gi" "GeoServer JVM requests must include a realistic memory baseline"
Assert-NotMatches $rendered '(?m)^\s+limits:\s*$' "GeoServer workloads must not render CPU or memory limits"
Assert-Matches $rendered '(?ms)kind: Deployment\s+metadata:\s+name: webui\b.*?\n\s+replicas: 1\b' "The stateful web UI must stay at one replica"
Assert-NotMatches $rendered '(?ms)kind: HorizontalPodAutoscaler\s+metadata:\s+name: webui\b' "The stateful web UI must not be autoscaled"
Assert-Matches $rendered '(?ms)kind: PodDisruptionBudget\s+metadata:\s+name: wms\b' "PDBs must use the effective autoscaling minimum"
Assert-NotMatches $rendered '(?ms)kind: PodDisruptionBudget\s+metadata:\s+name: rabbitmq\b' "RabbitMQ cannot render an unreachable multi-replica PDB branch"
Assert-StorageAtMostOneGi $rendered "GeoServer PVC requests must not exceed 1Gi"

$secretTemplate = Get-Content -Raw -Path (Join-Path $chartRoot "templates\secret-runtime.yaml")
Assert-Contains $secretTemplate 'trimPrefix "{noop}"' "ACL admin upgrades must remove the stored encoding before re-encoding"

$securityScript = Get-Content -Raw -Path (Join-Path $RepoRoot "infra\helm\configure-geoserver-security.sh")
Assert-Contains $securityScript "curl -s -K -" "Security REST calls must read credentials from stdin"
Assert-NotContains $securityScript 'curl -s -u ' "Security REST calls must not put credentials in oc exec argv"

$crunchyBaseArgs = @(
  "template",
  "crunchy-postgres",
  $crunchyRoot,
  "--namespace",
  "geoserver-dev"
)
$crunchyBaseRendered = (& helm @crunchyBaseArgs 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
  throw "Crunchy chart base values must render when optional S3 backups are disabled: $crunchyBaseRendered"
}
Assert-NotContains $crunchyBaseRendered "name: crunchy-postgres-s3-secret" "S3 Secret must not render when S3 backups are disabled"
Assert-NotContains $crunchyBaseRendered "name: repo2" "S3 backup repository must not render when S3 backups are disabled"

$crunchyS3Args = $crunchyBaseArgs + @("--set", "crunchy.pgBackRest.s3.enabled=true")
$crunchyS3Output = (& helm @crunchyS3Args 2>&1 | Out-String)
if ($LASTEXITCODE -eq 0) {
  throw "Crunchy chart must reject explicitly enabled S3 backups without repository configuration"
}
if ($crunchyS3Output -notmatch "accessKey is required") {
  throw "Unexpected S3 validation output: $crunchyS3Output"
}

$crunchyConfiguredS3Args = $crunchyBaseArgs + @(
  "--set", "crunchy.pgBackRest.s3.enabled=true",
  "--set", "crunchy.pgBackRest.s3.accessKey=test-access-key",
  "--set", "crunchy.pgBackRest.s3.secretKey=test-secret-key",
  "--set", "crunchy.pgBackRest.s3.bucket=approved-bucket",
  "--set", "crunchy.pgBackRest.s3.endpoint=https://s3.example.test"
)
$crunchyConfiguredS3 = (& helm @crunchyConfiguredS3Args 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
  throw "Crunchy chart must render when S3 is fully configured: $crunchyConfiguredS3"
}
Assert-Contains $crunchyConfiguredS3 "name: crunchy-postgres-s3-secret" "S3 configuration Secret must be chart-managed"
Assert-Contains $crunchyConfiguredS3 "repo2-s3-key=test-access-key" "S3 access key must be written to the generated configuration"

$crunchyArgs = @(
  "template",
  "crunchy-postgres",
  $crunchyRoot,
  "--namespace",
  "geoserver-dev",
  "-f",
  (Join-Path $crunchyRoot "values\values-dev.yaml")
)
$crunchyRendered = (& helm @crunchyArgs 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
  throw "Crunchy chart render failed: $crunchyRendered"
}
$crunchyRendered | Set-Content -Path $crunchyRenderedPath -Encoding utf8

Assert-Contains $crunchyRendered "storage: 1Gi" "PostgreSQL data storage must remain within the 1Gi PVC ceiling"
Assert-StorageAtMostOneGi $crunchyRendered "Crunchy PVC requests must not exceed 1Gi"
Assert-Contains $crunchyRendered "memory: 2Gi" "PostgreSQL memory must cover shared_buffers"
Assert-NotMatches $crunchyRendered '(?m)^\s+limits:\s*$' "Crunchy workloads must not render CPU or memory limits"
Assert-Contains $crunchyRendered "host all all 10.0.0.0/8 scram-sha-256" "PostgreSQL host authentication must use the private cluster range and SCRAM"
Assert-NotContains $crunchyRendered "host all all 0.0.0.0/0" "PostgreSQL host authentication must not allow every IPv4 source"
Assert-NotContains $crunchyRendered "SUPERUSER CREATEDB CREATEROLE" "The application database role must not be a superuser"

Write-Output "Helm review regression checks passed: $renderedPath"
