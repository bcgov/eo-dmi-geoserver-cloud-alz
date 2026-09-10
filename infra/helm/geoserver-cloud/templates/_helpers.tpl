{{- define "geoserver-cloud.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "geoserver-cloud.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "geoserver-cloud.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "geoserver-cloud.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "geoserver-cloud.labels" -}}
helm.sh/chart: {{ include "geoserver-cloud.chart" . }}
app.kubernetes.io/name: {{ include "geoserver-cloud.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "geoserver-cloud.selectorLabels" -}}
app.kubernetes.io/name: {{ include "geoserver-cloud.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "geoserver-cloud.serviceLabels" -}}
{{ include "geoserver-cloud.labels" . }}
app.kubernetes.io/component: {{ .serviceName }}
{{- end -}}

{{- define "geoserver-cloud.databaseHost" -}}
{{- printf "%s-pgbouncer" .Values.database.crunchyReleaseName -}}
{{- end -}}

{{- define "geoserver-cloud.databaseSecretName" -}}
{{- printf "%s-pguser-%s" .Values.database.crunchyReleaseName .Values.database.crunchyUserName -}}
{{- end -}}

{{- define "geoserver-cloud.image" -}}
{{- $root := .root -}}
{{- $image := index $root.Values.images .name -}}
{{- $registry := required "global.artifactory.registry is required" $root.Values.global.artifactory.registry -}}
{{- $source := default "dockerHub" $image.repository -}}
{{- $repository := required "global.artifactory.dockerHubRepository is required" $root.Values.global.artifactory.dockerHubRepository -}}
{{- if eq $source "local" -}}
{{- $repository = required "global.artifactory.localRepository is required" $root.Values.global.artifactory.localRepository -}}
{{- else if ne $source "dockerHub" -}}
{{- fail (printf "images.%s.repository must be dockerHub or local" .name) -}}
{{- end -}}
{{- $path := required (printf "images.%s.path is required" .name) $image.path -}}
{{- $tag := required (printf "images.%s.tag is required" .name) $image.tag -}}
{{- if $image.digest -}}
{{- printf "%s/%s/%s@%s" $registry $repository $path $image.digest -}}
{{- else -}}
{{- printf "%s/%s/%s:%s" $registry $repository $path $tag -}}
{{- end -}}
{{- end -}}

{{- define "geoserver-cloud.validate" -}}
{{- $registry := required "global.artifactory.registry is required" .Values.global.artifactory.registry -}}
{{- if ne $registry "artifacts.developer.gov.bc.ca" -}}
{{- fail "global.artifactory.registry must be artifacts.developer.gov.bc.ca" -}}
{{- end -}}
{{- if and .Values.proxy.enabled (not .Values.proxy.oidc.issuer) -}}
{{- fail "proxy.oidc.issuer is required when proxy.enabled is true" -}}
{{- end -}}
{{- if and .Values.proxy.enabled (not .Values.proxy.oidc.clientId) -}}
{{- fail "proxy.oidc.clientId is required when proxy.enabled is true" -}}
{{- end -}}
{{- if not .Values.database.crunchyReleaseName -}}
{{- fail "database.crunchyReleaseName is required so database endpoints can be derived" -}}
{{- end -}}
{{- if not .Values.database.crunchyUserName -}}
{{- fail "database.crunchyUserName is required so the Crunchy Secret name can be derived" -}}
{{- end -}}
{{- if gt (int .Values.rabbitmq.replicas) 1 -}}
{{- fail "rabbitmq.replicas must remain 1 until RabbitMQ clustering and peer discovery are implemented" -}}
{{- end -}}
{{- range $name, $image := .Values.images -}}
{{- if or (contains "docker.io" $image.path) (contains "registry-1.docker.io" $image.path) -}}
{{- fail (printf "images.%s.path must not reference Docker Hub directly" $name) -}}
{{- end -}}
{{- if eq $image.tag "latest" -}}
{{- fail (printf "images.%s.tag must not be latest" $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "geoserver-cloud.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
{{ toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "geoserver-cloud.runtimeSecretValue" -}}
{{- $existing := lookup "v1" "Secret" .root.Release.Namespace .root.Values.secrets.runtime.name -}}
{{- if and $existing $existing.data (hasKey $existing.data .key) -}}
{{- index $existing.data .key | b64dec -}}
{{- else -}}
{{- .fallback -}}
{{- end -}}
{{- end -}}
