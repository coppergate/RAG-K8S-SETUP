# ===========================================================================
# MAC addresses — new-setup-external-gpu (flat LAN design)
#
# Every node has a SINGLE NIC on the flat LAN bridge (libvirt network 'lan',
# host bridge br-lan). VMs are pinned to these MACs by virt-install; the GPU
# node uses its physical NIC MAC. There is no second (external) NIC and no
# lb-net in this variant.
# ===========================================================================
export mac_prefix="6A:69:11:AA:00"
export control_0_mac="${mac_prefix}:A1"
export control_1_mac="${mac_prefix}:A2"
export control_2_mac="${mac_prefix}:A3"
export data_0_mac="${mac_prefix}:A4"
export data_1_mac="${mac_prefix}:A5"
export data_2_mac="${mac_prefix}:A6"
export data_3_mac="${mac_prefix}:A7"

# ===========================================================================
# External GPU inference node — physical machine on the flat LAN.
# Final static address is INFERENCE_IP_0 (192.168.5.31), assigned by Talos
# from configs/patch-inference-0.yaml.
#
# inference_0_mac is the NIC Talos matches on (deviceSelector.hardwareAddr in
# configs/patch-inference-0.yaml) and the MAC used for ARP-based
# maintenance-mode discovery in 45-enroll-external-node.sh. It MUST stay in
# sync with that patch file.
#
# To re-read these: run 'ip link show' on the node console, or check BIOS/UEFI.
# ===========================================================================
export inference_0_mac="00:25:90:fb:71:21"

# Second onboard NIC on the GPU node. Recorded so it does not have to be read
# off the console again; the flat-LAN design does not currently use it, and no
# script or Talos patch references it.
export inference_0_mac_1="00:25:90:fb:71:23"
