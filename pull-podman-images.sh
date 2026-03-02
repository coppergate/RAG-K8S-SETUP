
# as an alternate to the K8s based registry (see the ./app-build/docker-registry directory) we can spin up a podman container 
# without cert
podman run --privileged -d -p 5000:5000 \
--name registry \
-v /mnt/hegemon-share/virtual-machines/registry:/var/lib/registry \
-v /etc/containers:/auth \
-e REGISTRY_AUTH=htpasswd \
-e REGISTRY_AUTH_HTPASSWD_PATH=/auth/.htpasswd \
-e REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm" \
registry:2

# with cert
podman run --privileged -d -p 5000:5000 \
--name registry \
-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/hegemon.hierocracy+3.pem \
-e REGISTRY_HTTP_TLS_KEY=/certs/hegemon.hierocracy+3-key.pem \
-v /home/k8s/certs:/certs \
-v /mnt/hegemon-share/virtual-machines/registry:/var/lib/registry \
registry:2

# test
podman login hierophant.hierocracy.home:5000 

# Mirror Talos Factory images for v1.12.4 into local registry
podman pull factory.talos.dev/metal-installer/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846:v1.12.4
podman tag  factory.talos.dev/metal-installer/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846:v1.12.4 \
            hierophant.hierocracy.home:5000/siderolabs/installer-control-worker:v1.12.4
podman push hierophant.hierocracy.home:5000/siderolabs/installer-control-worker:v1.12.4

podman pull factory.talos.dev/metal-installer/f0248d1e8abaffdec12ddc54bae270982f3ab5a70e3c7b0b11c11ca0fb1708d9:v1.12.4
podman tag  factory.talos.dev/metal-installer/f0248d1e8abaffdec12ddc54bae270982f3ab5a70e3c7b0b11c11ca0fb1708d9:v1.12.4 \
            hierophant.hierocracy.home:5000/siderolabs/installer-inference:v1.12.4
podman push hierophant.hierocracy.home:5000/siderolabs/installer-inference:v1.12.4

----
Created a new certificate valid for the following names 📜
 - "hegemon.hierocracy"
 - "hegemon.hierocracy.home"
 - "hierophant.hierocracy"
 - "hierophant.hierocracy.home"

The certificate is at "./hegemon.hierocracy+3.pem" and the key at "./hegemon.hierocracy+3-key.pem" ✅



kubectl delete -n postgres -f ./manifests/UI/manifests/
kubectl delete -n postgres service/postgres-operator-ui
kubectl delete -n postgres service/postgres-operator-ui-lb
kubectl delete -n postgres -f ./manifests/api-service.yaml  
kubectl delete -n postgres -f ./manifests/operator-service-account-rbac.yaml  
kubectl delete -n postgres -f ./manifests/postgres-operator.yaml  
kubectl delete -n postgres -f ./manifests/configmap.yaml  





kubectl expose service postgres-operator-ui \
    --name=postgres-operator-ui-lb \
    --port=8081 \
    --target-port=80 \
    --type=LoadBalancer \
    -n postgres
