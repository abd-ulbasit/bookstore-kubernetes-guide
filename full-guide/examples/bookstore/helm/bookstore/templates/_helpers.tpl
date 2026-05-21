{{/* ===========================================================================
  Bookstore chart — named template helpers
  ---------------------------------------------------------------------------
  The single place that keeps the chart's restricted securityContext, the
  scheduling layer, the labels, and the catalog/orders DB_DSN BYTE-CONSISTENT
  with examples/bookstore/raw-manifests/. Workload templates `include` these
  rather than repeating YAML, so the equivalence with the raw manifests cannot
  silently drift.
  =========================================================================== */}}

{{/* ----------------------------------------------------------------------- */}}
{{/* Names                                                                    */}}
{{/* ----------------------------------------------------------------------- */}}

{{/*
bookstore.name — the chart name (override: nameOverride).
*/}}
{{- define "bookstore.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
bookstore.fullname — DELIBERATELY the chart name, NOT "<release>-<chart>".
The Bookstore Services/DNS/DB_DSN are wired by FIXED names across Parts 02–06
(e.g. postgres.bookstore.svc.cluster.local is baked into DB_DSN and AMQP_URL),
so the chart preserves the raw-manifests object names exactly. Per-object names
are the literal raw-manifests names (catalog, orders, postgres, ...).
Override with fullnameOverride only if you must run two parallel copies.
*/}}
{{- define "bookstore.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "bookstore.name" . -}}
{{- end -}}
{{- end -}}

{{/*
bookstore.namespace — the target namespace for every namespaced object.
*/}}
{{- define "bookstore.namespace" -}}
{{- .Values.namespace.name | default "bookstore" -}}
{{- end -}}

{{- define "bookstore.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* ----------------------------------------------------------------------- */}}
{{/* Labels                                                                   */}}
{{/* ----------------------------------------------------------------------- */}}

{{/*
bookstore.commonLabels — chart-management labels added to EVERY object
(alongside the raw-manifests app.kubernetes.io/part-of: bookstore which the
per-object labels keep). Helm's managed-by/instance/version make the release
auditable; the raw manifests' app/component/track labels are preserved by each
template explicitly so Service selectors keep matching.
*/}}
{{- define "bookstore.commonLabels" -}}
app.kubernetes.io/part-of: bookstore
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ include "bookstore.chart" . }}
{{- end -}}

{{/*
bookstore.labels — commonLabels + the per-workload app label.
Usage: include "bookstore.labels" (dict "ctx" $ "app" "catalog")
Optionally pass "component" and "extra" (a map) for component/track labels.
*/}}
{{- define "bookstore.labels" -}}
{{- $ctx := .ctx -}}
{{ include "bookstore.commonLabels" $ctx }}
{{- if .app }}
app: {{ .app }}
{{- end }}
{{- if .component }}
component: {{ .component }}
{{- end }}
{{- with .extra }}
{{- range $k, $v := . }}
{{ $k }}: {{ $v }}
{{- end }}
{{- end }}
{{- end -}}

{{/* ----------------------------------------------------------------------- */}}
{{/* Restricted securityContext (Part 05 ch.02 — verbatim per image)          */}}
{{/* ----------------------------------------------------------------------- */}}

{{/*
bookstore.podSecurityContext — pod-level SC for a named securityProfile.
Usage: include "bookstore.podSecurityContext" (dict "ctx" $ "profile" "goService")
*/}}
{{- define "bookstore.podSecurityContext" -}}
{{- $p := index .ctx.Values.securityProfiles .profile -}}
{{- toYaml $p.pod -}}
{{- end -}}

{{/*
bookstore.containerSecurityContext — container-level SC for a named profile.
Usage: include "bookstore.containerSecurityContext" (dict "ctx" $ "profile" "goService")
*/}}
{{- define "bookstore.containerSecurityContext" -}}
{{- $p := index .ctx.Values.securityProfiles .profile -}}
{{- toYaml $p.container -}}
{{- end -}}

{{/* ----------------------------------------------------------------------- */}}
{{/* DB_DSN — the SINGLE source of the catalog/orders Postgres DSN            */}}
{{/* ----------------------------------------------------------------------- */}}

{{/*
bookstore.dbDsn — the libpq keyword/value DSN, IDENTICAL for catalog (10-) and
orders (14-). It uses $(VAR) interpolation against the POSTGRES_* env the
container pulls from the db-credentials Secret EARLIER in its env list, exactly
like the raw manifests (so the kubelet substitutes them in order). Rendering it
from one helper guarantees the two workloads stay byte-identical.
*/}}
{{- define "bookstore.dbDsn" -}}
{{- $d := .Values.database -}}
{{- printf "host=%s port=%v user=$(POSTGRES_USER) password=$(POSTGRES_PASSWORD) dbname=$(POSTGRES_DB) sslmode=%s" $d.host $d.port $d.sslmode -}}
{{- end -}}

{{/*
bookstore.dbEnv — the four env entries (POSTGRES_USER/PASSWORD/DB then DB_DSN)
shared verbatim by catalog and orders. $(VAR) requires the three secret refs to
appear BEFORE DB_DSN in the same container's env list — this helper emits them
in that exact order.
*/}}
{{- define "bookstore.dbEnv" -}}
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.dbCredentials.secretName }}
      key: POSTGRES_USER
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.dbCredentials.secretName }}
      key: POSTGRES_PASSWORD
- name: POSTGRES_DB
  valueFrom:
    secretKeyRef:
      name: {{ .Values.dbCredentials.secretName }}
      key: POSTGRES_DB
- name: DB_DSN
  value: "{{ include "bookstore.dbDsn" . }}"
{{- end -}}

{{/* ----------------------------------------------------------------------- */}}
{{/* Scheduling fragments (Part 04)                                           */}}
{{/* ----------------------------------------------------------------------- */}}

{{/*
bookstore.topologySpread — render a topologySpreadConstraints block for a
workload whose .topologySpread.enabled is true. Pass the per-workload values
map as "w" and the app label as "app".
Usage: include "bookstore.topologySpread" (dict "w" .Values.catalog "app" "catalog")
*/}}
{{- define "bookstore.topologySpread" -}}
{{- $ts := .w.topologySpread -}}
{{- if and $ts $ts.enabled }}
topologySpreadConstraints:
  - maxSkew: {{ $ts.maxSkew }}
    topologyKey: {{ $ts.topologyKey }}
    whenUnsatisfiable: {{ $ts.whenUnsatisfiable }}
    labelSelector:
      matchLabels:
        app: {{ .app }}
{{- end -}}
{{- end -}}

{{/*
bookstore.affinity — build the affinity block: generated podAntiAffinity
(if enabled) and/or generated nodeAffinity (postgres), then deep-merge any
user-supplied .affinity override on top (override wins).
Usage: include "bookstore.affinity" (dict "w" .Values.catalog "app" "catalog")
*/}}
{{- define "bookstore.affinity" -}}
{{- $w := .w -}}
{{- $generated := dict -}}
{{- if and $w.podAntiAffinity $w.podAntiAffinity.enabled -}}
{{- $_ := set $generated "podAntiAffinity" (dict "preferredDuringSchedulingIgnoredDuringExecution" (list (dict "weight" $w.podAntiAffinity.weight "podAffinityTerm" (dict "topologyKey" $w.podAntiAffinity.topologyKey "labelSelector" (dict "matchLabels" (dict "app" .app)))))) -}}
{{- end -}}
{{- if and $w.nodeAffinity $w.nodeAffinity.enabled -}}
{{- $_ := set $generated "nodeAffinity" (dict "preferredDuringSchedulingIgnoredDuringExecution" (list (dict "weight" $w.nodeAffinity.weight "preference" (dict "matchExpressions" (list (dict "key" $w.nodeAffinity.key "operator" "In" "values" $w.nodeAffinity.values)))))) -}}
{{- end -}}
{{- $merged := $generated -}}
{{- with $w.affinity -}}
{{- $merged = mergeOverwrite (deepCopy $generated) . -}}
{{- end -}}
{{- if $merged -}}
affinity:
{{ toYaml $merged | indent 2 -}}
{{- end -}}
{{- end -}}

{{/* ----------------------------------------------------------------------- */}}
{{/* Edge validation: Ingress XOR Gateway                                     */}}
{{/* ----------------------------------------------------------------------- */}}

{{/*
bookstore.validateEdge — fail the render if BOTH ingress.enabled and
gateway.enabled are true (they would bind the same hostname/paths via two data
planes — see raw-manifests 50-/51-), or if catalog.enabled and canary.enabled
are both on. Called from NOTES.txt, 50-ingress.yaml and 51-gateway.yaml;
idempotent (the guards are pure value checks, so calling it from several
templates is safe and harmless). Uses `fail` so a misconfiguration is caught
at `helm template`/`helm install` time, not at runtime.
*/}}
{{- define "bookstore.validateEdge" -}}
{{- if and .Values.ingress.enabled .Values.gateway.enabled -}}
{{- fail "values error: ingress.enabled and gateway.enabled are mutually exclusive (50-ingress.yaml XOR 51-gateway.yaml) — enable exactly one edge stack." -}}
{{- end -}}
{{- if and .Values.catalog.enabled .Values.canary.enabled -}}
{{- fail "values error: catalog.enabled and canary.enabled are mutually exclusive (both define app:catalog Pods and a 'catalog' Service — see raw-manifests 30-catalog-canary.yaml) — enable exactly one." -}}
{{- end -}}
{{- end -}}
