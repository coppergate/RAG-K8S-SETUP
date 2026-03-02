
# as an alternate to the K8s based registry (see the ./app-build/docker-registry directory) we can spin up a podman container 
# using a Quadlet configuration on hierophant:
# /home/junie/.config/containers/systemd/registry.container

# To restart the registry after configuration changes:
# systemctl --user daemon-reload
# systemctl --user restart registry.service

# Talos v1.12.4 Installer Images (Local Mirror)
# These are pushed to the local registry on hierophant to be used during cluster installation.

# Mirror Talos control-worker installer for v1.12.4
podman pull factory.talos.dev/metal-installer/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846:v1.12.4
podman tag  factory.talos.dev/metal-installer/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846:v1.12.4 \
            hierophant.hierocracy.home:5000/siderolabs/installer-control-worker:v1.12.4
podman push --tls-verify=false hierophant.hierocracy.home:5000/siderolabs/installer-control-worker:v1.12.4

# Mirror Talos inference installer for v1.12.4
podman pull factory.talos.dev/metal-installer/f0248d1e8abaffdec12ddc54bae270982f3ab5a70e3c7b0b11c11ca0fb1708d9:v1.12.4
podman tag  factory.talos.dev/metal-installer/f0248d1e8abaffdec12ddc54bae270982f3ab5a70e3c7b0b11c11ca0fb1708d9:v1.12.4 \
            hierophant.hierocracy.home:5000/siderolabs/installer-inference:v1.12.4
podman push --tls-verify=false hierophant.hierocracy.home:5000/siderolabs/installer-inference:v1.12.4

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
