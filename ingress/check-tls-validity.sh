kubectl get secret my-tls-secret -n <namespace> \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/tls.crt

openssl x509 -in /tmp/tls.crt -noout -text
