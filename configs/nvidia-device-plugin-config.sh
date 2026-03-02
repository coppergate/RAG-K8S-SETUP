#!/bin/bash
export KUBECONFIG=/home/k8s/kube/config/kubeconfig
/home/k8s/kube/kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-device-plugin-config
  namespace: gpu-operator
data:
  config.yaml: |
    version: v1
    flags:
      failOnInitError: true
      nvidiaDriverRoot: /
      nvidiaDevRoot: /
      deviceDiscoveryStrategy: nvml
    sharing:
      timeSlicing: {}
EOF
