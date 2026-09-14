param(
  [string]$ValuesFile = "",
  [string]$CrunchyReleaseName = "crunchy-postgres",
  [switch]$RequireProxy,
  [switch]$RequireRuntimeSecret
)

$ErrorActionPreference = "Stop"
$chartRoot = Split-Path -Parent $PSScriptRoot
$renderedPath = Join-Path $env:TEMP "geoserver-cloud-rendered.yaml"
$resolvedValuesFile = if ($ValuesFile) {
  Resolve-Path $ValuesFile
}
else {
  Join-Path $chartRoot "values\values-dev.yaml"
}

helm lint $chartRoot --strict -f $resolvedValuesFile
if ($LASTEXITCODE -ne 0) { throw "helm lint failed" }

$templateArgs = @(
  "template",
  "geoserver-cloud",
  $chartRoot,
  "--namespace",
  "geoserver-dev"
)
$templateArgs += @("-f", $resolvedValuesFile)
$templateArgs += @("--set-string", "database.crunchyReleaseName=$CrunchyReleaseName")
if ($RequireProxy) {
  $templateArgs += @("--set", "proxy.route.enabled=true")
}

& helm @templateArgs | Set-Content -Path $renderedPath -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw "helm template failed" }

$rendered = Get-Content -Raw -Path $renderedPath
$documents = @(
  $rendered -split '(?m)^---\s*(?:\r?\n|$)' |
  Where-Object { $_ -match '(?m)^apiVersion:\s*\S+' }
)
$resources = foreach ($document in $documents) {
  $kindMatch = [regex]::Match($document, '(?m)^kind:\s*(\S+)\s*$')
  $nameMatch = [regex]::Match($document, '(?ms)^metadata:\s*\r?\n.*?^\s+name:\s*(\S+)\s*$')
  if ($kindMatch.Success -and $nameMatch.Success) {
    [pscustomobject]@{
      Kind    = $kindMatch.Groups[1].Value
      Name    = $nameMatch.Groups[1].Value
      Content = $document
    }
  }
}
$workloadKinds = @("Deployment", "StatefulSet", "Job", "CronJob", "DaemonSet")
foreach ($workload in @($resources | Where-Object { $workloadKinds -contains $_.Kind })) {
  $lines = $workload.Content -split '\r?\n'
  for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
    if ($lines[$lineIndex] -match '^(\s+)env:\s*$') {
      $envIndent = $Matches[1].Length
      $envNames = @()
      for ($envLineIndex = $lineIndex + 1; $envLineIndex -lt $lines.Count; $envLineIndex++) {
        $envLine = $lines[$envLineIndex]
        if ($envLine -match '^\s*$') { continue }
        $indent = $envLine.Length - $envLine.TrimStart().Length
        if ($indent -le $envIndent) { break }
        if ($envLine -match '^\s+- name:\s+(\S+)\s*$') {
          $envNames += $Matches[1]
        }
      }
      foreach ($duplicate in @($envNames | Group-Object | Where-Object Count -gt 1)) {
        throw "Rendered workload $($workload.Kind)/$($workload.Name) has duplicate environment variable: $($duplicate.Name)"
      }
    }
  }
}
if ($rendered -match "docker\.io|registry-1\.docker\.io") {
  throw "Rendered manifests contain a direct Docker Hub image reference"
}
if ($rendered -match "crunchy-postgres-primary|jdbc:postgresql://geodatabase") {
  throw "Rendered manifests contain a database endpoint that bypasses pgBouncer"
}
if ($rendered -notmatch [regex]::Escape("$CrunchyReleaseName-pgbouncer")) {
  throw "Rendered manifests do not reference the Crunchy pgBouncer Service"
}
if ($rendered -match "(?m)^\s*image:\s+[^\r\n]*:latest\s*$") {
  throw "Rendered manifests contain a floating latest image tag"
}
if ($rendered -notmatch "artifacts\.developer\.gov\.bc\.ca/") {
  throw "Rendered manifests contain no Platform Artifactory image reference"
}
$imageLines = [regex]::Matches($rendered, "(?m)^\s+image:\s+(\S+)$")
foreach ($imageLine in $imageLines) {
  $image = $imageLine.Groups[1].Value
  $isApprovedArtifactoryImage = $image.StartsWith("artifacts.developer.gov.bc.ca/")
  if (-not $isApprovedArtifactoryImage) {
    throw "Rendered image is outside Platform Artifactory: $($imageLine.Groups[1].Value)"
  }
}
foreach ($workload in @($resources | Where-Object {
      $workloadKinds -contains $_.Kind -and $_.Content -match "(?m)^\s+image:\s+\S+$"
    })) {
  if ($workload.Content -notmatch "(?m)^\s+imagePullSecrets:\s*$") {
    throw "Rendered workload $($workload.Kind)/$($workload.Name) does not declare imagePullSecrets"
  }
}
foreach ($requiredName in @("gateway", "webui", "wms", "wfs", "wcs", "wps", "rest", "gwc", "acl", "rabbitmq")) {
  if (-not ($resources | Where-Object { $_.Name -eq $requiredName })) {
    throw "Rendered manifests do not contain the required resource: $requiredName"
  }
}
if ($RequireProxy) {
  $proxyWorkload = $resources | Where-Object { $_.Name -eq "oidc-proxy" -and $_.Kind -eq "Deployment" }
  $proxyService = $resources | Where-Object { $_.Name -eq "oidc-proxy" -and $_.Kind -eq "Service" }
  if (-not $proxyWorkload) { throw "Proxy validation requested but oidc-proxy Deployment is missing" }
  if (-not $proxyService) { throw "Proxy validation requested but oidc-proxy Service is missing" }
  if ($proxyWorkload.Content -notmatch "(?m)^\s+image:\s+artifacts\.developer\.gov\.bc\.ca/bcgov-docker-local/node-oidc-proxy:") {
    throw "Proxy Deployment does not use an approved proxy image path"
  }
  $routes = @($resources | Where-Object { $_.Kind -eq "Route" })
  if ($routes.Count -ne 1 -or $routes[0].Content -notmatch "(?m)^\s+name:\s+oidc-proxy\s*$") {
    throw "Proxy validation requested but exactly one oidc-proxy Route is required"
  }
  if ($routes[0].Content -notmatch "(?ms)^\s+to:\s*\r?\n\s+kind:\s+Service\s*\r?\n\s+name:\s+oidc-proxy\s*$") {
    throw "The rendered Route must target oidc-proxy"
  }
}
if (-not $RequireProxy -and $rendered -match "(?m)^kind:\s+Route\s*$") {
  throw "The default validation profile unexpectedly renders an OpenShift Route"
}
if ($rendered -match "(?m)^\s+type:\s+(NodePort|LoadBalancer)\s*$") {
  throw "Rendered manifests contain a NodePort or LoadBalancer Service"
}
foreach ($secretResource in @($resources | Where-Object { $_.Kind -eq "Secret" })) {
  if ($secretResource.Content -notmatch "app.kubernetes.io/component:\s*runtime-secret") {
    throw "Unexpected rendered Secret resource: $($secretResource.Name)"
  }
}
if ($RequireRuntimeSecret) {
  $crunchySecretPrefix = "^$([regex]::Escape($CrunchyReleaseName))-pguser-"
  $runtimeSecret = $resources | Where-Object {
    $_.Kind -eq "Secret" -and $_.Content -match "app.kubernetes.io/component:\s*runtime-secret"
  }
  if (-not $runtimeSecret) {
    throw "Runtime secret validation requested but the runtime Secret is missing"
  }
  foreach ($requiredKey in @("rabbitmq-password", "geoserver-admin-password", "oidc-client-secret", "session-cookie-secret")) {
    if ($runtimeSecret.Content -notmatch [regex]::Escape($requiredKey)) {
      throw "Runtime Secret is missing required key: $requiredKey"
    }
  }
  $applicationWorkloads = @($resources | Where-Object {
      $_.Kind -in @("Deployment", "StatefulSet", "Job") -and
      $_.Content -match "app.kubernetes.io/component:\s*(gateway|webui|wms|wfs|wcs|wps|rest|gwc|acl|oidc-proxy|rabbitmq|database-init)"
    })
  foreach ($workload in $applicationWorkloads) {
    $secretRefs = [regex]::Matches($workload.Content, '(?ms)secretKeyRef:\s*\r?\n\s+name:\s+(\S+)')
    foreach ($secretRef in $secretRefs) {
      $secretName = $secretRef.Groups[1].Value
      if ($secretName -ne $runtimeSecret.Name -and $secretName -notmatch $crunchySecretPrefix) {
        throw "Application workload $($workload.Kind)/$($workload.Name) references unexpected Secret: $secretName"
      }
    }
  }
}

Write-Output "Helm chart validation passed: $renderedPath"
