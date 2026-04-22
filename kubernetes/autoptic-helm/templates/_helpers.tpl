{{/*
Expand the name of the chart.
*/}}
{{- define "autoptic-server.name" -}}
{{- default .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "autoptic-server.fullname" -}}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "autoptic-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "autoptic-server.labels" -}}
helm.sh/chart: {{ include "autoptic-server.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end }}

{{/*
API selector labels
*/}}
{{- define "autoptic-server.api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "autoptic-server.name" . }}-api
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: api
{{- end }}

{{/*
API labels
*/}}
{{- define "autoptic-server.api.labels" -}}
{{ include "autoptic-server.labels" . }}
{{ include "autoptic-server.api.selectorLabels" . }}
{{- end }}

{{/*
Scheduler selector labels
*/}}
{{- define "autoptic-server.scheduler.selectorLabels" -}}
app.kubernetes.io/name: {{ include "autoptic-server.name" . }}-scheduler
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: scheduler
{{- end }}

{{/*
Scheduler labels
*/}}
{{- define "autoptic-server.scheduler.labels" -}}
{{ include "autoptic-server.labels" . }}
{{ include "autoptic-server.scheduler.selectorLabels" . }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "autoptic-server.serviceAccountName" -}}
{{- if .Values.serviceAccounts.s3DynamoDbAccess.create }}
{{- default (printf "%s-sa" (include "autoptic-server.fullname" .)) .Values.serviceAccounts.s3DynamoDbAccess.name }}
{{- else }}
{{- default "default" .Values.serviceAccounts.s3DynamoDbAccess.name }}
{{- end }}
{{- end }}

{{/*
ConfigMap name
*/}}
{{- define "autoptic-server.configMapName" -}}
{{- if .Values.config.name }}
{{- .Values.config.name }}
{{- else }}
{{- printf "%s-config" (include "autoptic-server.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Generate config.json content
Priority: configJsonString > configJson > default structure from env vars
*/}}
{{- define "autoptic-server.configJson" -}}
{{- if .Values.config.configJsonString }}
{{- .Values.config.configJsonString }}
{{- else }}
{{- $config := dict }}
{{- $_ := set $config "server" (dict "port" .Values.api.env.serverPort "host" "0.0.0.0" "ui" .Values.api.env.uiAddress "log_level" (default "info" .Values.api.env.logLevel)) }}
{{- $_ := set $config "aws" (dict "profile" "" "region" .Values.api.env.awsRegion) }}
{{- $_ := set $config "pql" (dict "command" .Values.api.env.pqlCommand) }}
{{- $_ := set $config "instance" (dict "id" .Values.api.env.instanceId "tenant_short_name" .Values.api.env.tenantShortName "default_endpoint" "default") }}
{{- $_ := set $config "scheduler" (dict "refresh_interval" .Values.scheduler.env.refreshInterval "api_endpoint" .Values.scheduler.env.apiEndpoint "api_token" .Values.scheduler.env.apiToken "timeout" .Values.scheduler.env.timeout) }}
{{- $_ := set $config "tasks" (dict "generate" "default" "analyze" "default") }}
{{- $_ := set $config "secrets" (dict "default" "default") }}
{{- $_ := set $config "vector" (dict "size" 1024 "model" "e5-large-v2" "embed_url" "http://vectors-service.autoptic.svc.cluster.local:8000" "qdrant_host" "metrics-service.autoptic.svc.cluster.local" "qdrant_port" 6334 "vector_search_timeout_sec" 30) }}
{{- $_ := set $config "retry" (dict "max_retries" 3 "initial_backoff_ms" 100 "max_backoff_ms" 5000) }}
{{- $_ := set $config "llm" (dict "max_chunks" 20 "chunk_overlap_tokens" 100 "token_estimation_ratio" 3 "rate_limit_delay_ms" 1000 "max_concurrent_requests" 3 "requests_per_minute" 60) }}
{{- if .Values.config.configJson }}
{{- $config = mergeOverwrite $config .Values.config.configJson }}
{{- end }}
{{- $config | toJson }}
{{- end }}
{{- end }}

{{/* ============================================
     AUTOPTIC-UI HELPERS
     ============================================ */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "autoptic-ui.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "autoptic-ui.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "autoptic-ui.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "autoptic-ui.labels" -}}
helm.sh/chart: {{ include "autoptic-ui.chart" . }}
{{ include "autoptic-ui.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "autoptic-ui.selectorLabels" -}}
app: myapp
component: ui
app.kubernetes.io/name: {{ include "autoptic-ui.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ============================================
     VECTORS-HELM HELPERS
     ============================================ */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "vectors-helm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "vectors-helm.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "vectors-helm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "vectors-helm.labels" -}}
helm.sh/chart: {{ include "vectors-helm.chart" . }}
{{ include "vectors-helm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "vectors-helm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vectors-helm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ============================================
     AWS Environment Block Helper
     ============================================ */}}

{{/*
Generate AWS environment variables for use in containers that need AWS access.
Includes: AWS_REGION, AWS credentials (if awsSecret.enabled).
*/}}
{{- define "autoptic-server.awsEnvBlock" -}}
- name: AWS_REGION
  value: {{ .Values.api.env.awsRegion | quote }}
{{- if .Values.awsSecret.enabled }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ .Values.awsSecret.name }}
      key: AWS_ACCESS_KEY_ID
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.awsSecret.name }}
      key: AWS_SECRET_ACCESS_KEY
{{- end }}
{{- end }}

{{/*
Generate instance/tenant environment variables.
*/}}
{{- define "autoptic-server.instanceEnvBlock" -}}
- name: AUTOPTIC_INSTANCE_ID
  valueFrom:
    configMapKeyRef:
      name: {{ include "autoptic-server.configMapName" . }}
      key: AUTOPTIC_INSTANCE_ID
- name: AUTOPTIC_TENANT_SHORT_NAME
  valueFrom:
    configMapKeyRef:
      name: {{ include "autoptic-server.configMapName" . }}
      key: AUTOPTIC_TENANT_SHORT_NAME
{{- end }}
