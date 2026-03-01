{{- define "minecraft-server.name" -}}
{{- .Values.name | default .Release.Name -}}
{{- end -}}

{{- define "minecraft-server.labels" -}}
app.kubernetes.io/name: {{ include "minecraft-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: minecraft
{{- end -}}

{{- define "minecraft-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "minecraft-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
