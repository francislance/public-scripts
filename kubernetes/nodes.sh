# get node IPs and custom roles
kubectl get nodes -o go-template='{{"NAME\tINTERNAL-IP\tROLES\n"}}{{range .items}}{{.metadata.name}}{{"\t"}}{{range .status.addresses}}{{if eq .type "InternalIP"}}{{.address}}{{end}}{{end}}{{"\t"}}{{- $sep := "" -}}{{- if eq (index .metadata.labels "label/kube_control_plane") "true" -}}{{$sep}}control-plane{{- $sep = "," -}}{{- end -}}{{- if eq (index .metadata.labels "label/infra_node") "true" -}}{{$sep}}infra{{- $sep = "," -}}{{- end -}}{{- if eq (index .metadata.labels "label/kube_node") "true" -}}{{$sep}}worker{{- $sep = "," -}}{{- end -}}{{- if eq $sep "" -}}unknown{{- end -}}{{"\n"}}{{end}}' \
| column -t -s $'\t'



kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory,CPU-ALLOCATABLE:.status.allocatable.cpu,MEM-ALLOCATABLE:.status.allocatable.memory'


