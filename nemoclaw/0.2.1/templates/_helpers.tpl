{{- define "nemoclaw.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nemoclaw.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "nemoclaw.serviceName" -}}
{{- include "nemoclaw.fullname" . }}
{{- end }}

{{- define "nemoclaw.releaseName" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nemoclaw.labels" -}}
app.kubernetes.io/name: {{ include "nemoclaw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: nemoclaw
hpe-ezua/created-by: ezua
{{- end }}

{{- define "nemoclaw.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nemoclaw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "nemoclaw.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end }}

{{- /*
  isPlaceholder: true when a value is empty or still a "<...>" placeholder
  (i.e. not filled in by the deployer). Used to trigger cluster auto-detect.
*/ -}}
{{- define "nemoclaw.isPlaceholder" -}}
{{- $v := trim . -}}
{{- if or (not $v) (hasPrefix "<" $v) (hasSuffix ">" $v) -}}true{{- else -}}false{{- end -}}
{{- end }}

{{- /*
  litellmNamespace: namespace holding the LiteLLM proxy + its master-key secret.
  Resolution order:
    1. explicit .Values.litellm.keyRef.namespace (if not a placeholder)
    2. cluster auto-detect: the namespace that owns the "litellm-helm-masterkey"
       secret (lookup — only populated during a real install/upgrade)
    3. fallback .Values.litellm.namespace
  Returns "" if nothing resolves (renderers should guard on that).
*/ -}}
{{- define "nemoclaw.litellmNamespace" -}}
{{- /*
  Resolution order:
    1. explicit .Values.litellm.keyRef.namespace (if not empty/placeholder)
    2. best-effort cross-namespace lookup of the "litellm-helm-masterkey"
       secret (works only when the install RBAC can list secrets cluster-wide;
       on many PCAI platforms it returns nil)
    3. fallback: the release namespace (litellm often co-located in the
       deploying user's namespace)
  Set keyRef.namespace explicitly for a guaranteed result.
*/ -}}
{{- $explicit := .Values.litellm.keyRef.namespace -}}
{{- if and $explicit (eq (trim (include "nemoclaw.isPlaceholder" (printf "%s" $explicit))) "false") }}
{{- $explicit -}}
{{- else -}}
{{- $detected := "" -}}
{{- $secrets := lookup "v1" "Secret" "" "litellm-helm-masterkey" -}}
{{- if $secrets }}
{{- range $s := $secrets.items }}
{{- if and (not $detected) $s.metadata.namespace }}
{{- $detected = $s.metadata.namespace }}
{{- end }}
{{- end }}
{{- end }}
{{- if $detected }}
{{- $detected -}}
{{- else }}
{{- .Release.Namespace -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- /*
  litellmBaseUrl: the internal LiteLLM OpenAI-compatible endpoint.
  Resolution order:
    1. explicit .Values.litellm.baseUrl (if not a placeholder)
    2. auto-constructed from the resolved litellm namespace
  Returns "" if neither resolves.
*/ -}}
{{- define "nemoclaw.litellmBaseUrl" -}}
{{- $explicit := .Values.litellm.baseUrl -}}
{{- if and $explicit (eq (trim (include "nemoclaw.isPlaceholder" (printf "%s" $explicit))) "false") }}
{{- $explicit -}}
{{- else -}}
{{- $ns := include "nemoclaw.litellmNamespace" . -}}
{{- if $ns -}}
{{- printf "http://litellm-helm.%s.svc.cluster.local:4000/v1" $ns -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- /*
  baseDomain: the PCAI base domain (e.g. aie.cs1.ctc.sg.lab).
  Resolution order:
    1. explicit .Values.domain.base (if not a placeholder)
    2. cluster auto-detect: the most common host suffix across the Istio
       VirtualServices (each host is "<app>.<base>"; strip the first label and
       take the majority). Only populated during a real install/upgrade.
  Returns "" if nothing resolves.
*/ -}}
{{- define "nemoclaw.baseDomain" -}}
{{- $explicit := .Values.domain.base -}}
{{- if and $explicit (eq (trim (include "nemoclaw.isPlaceholder" (printf "%s" $explicit))) "false") }}
{{- $explicit -}}
{{- else -}}
{{- $suffixCount := dict -}}
{{- $vss := lookup "networking.istio.io/v1beta1" "VirtualService" "" "" -}}
{{- if $vss }}
{{- range $vs := $vss.items }}
{{- range $h := $vs.spec.hosts }}
{{- if and (contains "." $h) (not (hasSuffix "svc.cluster.local" $h)) }}
{{- $labels := splitList "." $h }}
{{- if gt (len $labels) 1 }}
{{- $suffix := join "." (slice $labels 1 (len $labels)) }}
{{- $cur := get $suffixCount $suffix | default 0 }}
{{- $suffixCount = set $suffixCount $suffix (add $cur 1) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- $best := "" }}
{{- $bestCount := 0 }}
{{- range $suffix, $count := $suffixCount }}
{{- if gt $count $bestCount }}
{{- $best = $suffix }}
{{- $bestCount = $count }}
{{- end }}
{{- end }}
{{- if $best }}
{{- $best -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- /*
  storageClass: the PVC storage class.
  Resolution order:
    1. explicit .Values.persistence.storageClassName (if not a placeholder)
    2. cluster auto-detect: the StorageClass flagged
       "storageclass.kubernetes.io/is-default-class=true"
    3. fallback "" (use the cluster default — safe when the class is the
       platform default)
*/ -}}
{{- define "nemoclaw.storageClass" -}}
{{- $explicit := .Values.persistence.storageClassName -}}
{{- if and $explicit (eq (trim (include "nemoclaw.isPlaceholder" (printf "%s" $explicit))) "false") }}
{{- $explicit -}}
{{- else -}}
{{- $detected := "" -}}
{{- $scs := lookup "storage.k8s.io/v1" "StorageClass" "" "" -}}
{{- if $scs }}
{{- range $sc := $scs.items }}
{{- if and (not $detected) (eq (get $sc.metadata.annotations "storageclass.kubernetes.io/is-default-class") "true") }}
{{- $detected = $sc.metadata.name }}
{{- end }}
{{- end }}
{{- end }}
{{- if $detected }}
{{- $detected -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "nemoclaw.domain" -}}
{{ .Values.domain.appPrefix | default "nemoclaw" }}.{{ include "nemoclaw.baseDomain" . }}
{{- end }}

{{- define "nemoclaw.dashboardUrl" -}}
https://{{ include "nemoclaw.domain" . }}
{{- end }}

{{- define "hermes.image" -}}
{{- if .Values.hermes.image.digest -}}
{{ .Values.hermes.image.repository }}@{{ .Values.hermes.image.digest }}
{{- else -}}
{{ .Values.hermes.image.repository }}:{{ .Values.hermes.image.tag }}
{{- end -}}
{{- end }}
