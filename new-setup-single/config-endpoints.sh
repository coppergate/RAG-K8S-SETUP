
source ${SETUP_ROOT}/new-setup-single/config-env.sh 
source ${SETUP_ROOT}/new-setup-single/utils.sh

CP_VIP=10.0.0.15
export CP_VIP

# get the IP to use as the bootstrap node
CP_IP_0=$(getNodeIP "control-0")
export CP_IP_0
CP_IP_1=$(getNodeIP "control-1")
export CP_IP_1 
CP_IP_2=$(getNodeIP "control-2")
export CP_IP_2

# get the worker node ips for configuration  
WORKER_IP_0=$(getNodeIP "worker-0")
export WORKER_IP_0
WORKER_IP_1=$(getNodeIP "worker-1")
export WORKER_IP_1
WORKER_IP_2=$(getNodeIP "worker-2")
export WORKER_IP_2
WORKER_IP_3=$(getNodeIP "worker-3")
export WORKER_IP_3

INFERENCE_IP_0=$(getNodeIP "inference-0")
export INFERENCE_IP_0

echo "----|||||-------|||||----"
echo "CP_VIP : ${CP_VIP}"
echo "CP_IP_0 : ${CP_IP_0}"
echo "CP_IP_1 : ${CP_IP_1}"
echo "CP_IP_2 : ${CP_IP_2}"

echo "WORKER_IP_0 : ${WORKER_IP_0}"
echo "WORKER_IP_1 : ${WORKER_IP_1}"
echo "WORKER_IP_2 : ${WORKER_IP_2}"
echo "WORKER_IP_3 : ${WORKER_IP_3}"
echo "INFERENCE_IP_0 : ${INFERENCE_IP_0}"
echo "----|||||-------|||||----"
