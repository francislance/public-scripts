# get node IPs and custom roles
kubectl get nodes -o go-template='{{"NAME\tINTERNAL-IP\tROLES\n"}}{{range .items}}{{.metadata.name}}{{"\t"}}{{range .status.addresses}}{{if eq .type "InternalIP"}}{{.address}}{{end}}{{end}}{{"\t"}}{{- $sep := "" -}}{{- if eq (index .metadata.labels "label/kube_control_plane") "true" -}}{{$sep}}control-plane{{- $sep = "," -}}{{- end -}}{{- if eq (index .metadata.labels "label/infra_node") "true" -}}{{$sep}}infra{{- $sep = "," -}}{{- end -}}{{- if eq (index .metadata.labels "label/kube_node") "true" -}}{{$sep}}worker{{- $sep = "," -}}{{- end -}}{{- if eq $sep "" -}}unknown{{- end -}}{{"\n"}}{{end}}' \
| column -t -s $'\t'

#with specs
kubectl get nodes -o go-template='{{"NAME\tINTERNAL-IP\tROLES\tCPU\tMEM(Ki)\n"}}{{range .items}}{{.metadata.name}}{{"\t"}}{{range .status.addresses}}{{if eq .type "InternalIP"}}{{.address}}{{end}}{{end}}{{"\t"}}{{- $sep := "" -}}{{- if eq (index .metadata.labels "label/kube_control_plane") "true" -}}{{$sep}}control-plane{{- $sep = "," -}}{{- end -}}{{- if eq (index .metadata.labels "label/infra_node") "true" -}}{{$sep}}infra{{- $sep = "," -}}{{- end -}}{{- if eq (index .metadata.labels "label/kube_node") "true" -}}{{$sep}}worker{{- $sep = "," -}}{{- end -}}{{- if eq $sep "" -}}unknown{{- end -}}{{"\t"}}{{.status.capacity.cpu}}{{"\t"}}{{.status.capacity.memory}}{{"\n"}}{{end}}' \
| awk 'BEGIN{OFS="\t"} NR==1{print $1,$2,$3,$4,"MEM(GiB)"} NR>1{mem=$5; gsub(/Ki/,"",mem); printf "%s\t%s\t%s\t%s\t%.2f\n",$1,$2,$3,$4,mem/1024/1024}' \
| column -t -s $'\t'

#GB
kubectl get nodes -o go-template='{{"NAME\tINTERNAL-IP\tROLES\tCPU\tMEM(Ki)\n"}}{{range .items}}{{.metadata.name}}{{"\t"}}{{range .status.addresses}}{{if eq .type "InternalIP"}}{{.address}}{{end}}{{end}}{{"\t"}}{{- $sep := "" -}}{{- if eq (index .metadata.labels "label/kube_control_plane") "true" -}}{{$sep}}control-plane{{- $sep = "," -}}{{- end -}}{{- if eq (index .metadata.labels "label/infra_node") "true" -}}{{$sep}}infra{{- $sep = "," -}}{{- end -}}{{- if eq (index .metadata.labels "label/kube_node") "true" -}}{{$sep}}worker{{- $sep = "," -}}{{- end -}}{{- if eq $sep "" -}}unknown{{- end -}}{{"\t"}}{{.status.capacity.cpu}}{{"\t"}}{{.status.capacity.memory}}{{"\n"}}{{end}}' \
| awk 'BEGIN{OFS="\t"} NR==1{print $1,$2,$3,$4,"MEM(GB)"} NR>1{mem=$5; gsub(/Ki/,"",mem); printf "%s\t%s\t%s\t%s\t%.2f\n",$1,$2,$3,$4,(mem*1024/1000000000)}' \
| column -t -s $'\t'




kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory,CPU-ALLOCATABLE:.status.allocatable.cpu,MEM-ALLOCATABLE:.status.allocatable.memory'


  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.capacity.cpu}{"\t"}{.status.capacity.memory}{"\n"}{end}' \
  | awk 'BEGIN{OFS="\t"; print "NAME","CPU","MEM(Gi)"} NR>1{memKi=$3; gsub(/Ki/,"",memKi); printf "%s\t%s\t%.2f\n",$1,$2,memKi/1024/1024}'





