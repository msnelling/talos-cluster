{{- define "media-app.name" -}}
{{- .Values.name | default .Release.Name -}}
{{- end -}}

{{- define "media-app.labels" -}}
app.kubernetes.io/name: {{ include "media-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: db3000
{{- end -}}

{{- define "media-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "media-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
