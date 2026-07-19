# ===========================================================================
# MAC addresses — new-setup-external-gpu (flat LAN design)
#
# Every node has a SINGLE NIC on the flat LAN bridge (libvirt network 'lan',
# host bridge br-lan). VMs are pinned to these MACs by virt-install; the GPU
# node uses its physical NIC MAC. There is no longer a second (external) NIC.
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
# Set this to the actual NIC MAC address of the GPU node.
# Run 'ip link show' on the node or check BIOS/UEFI to find the MAC.
# Used for Talos interface matching (configs/patch-inference-0.yaml) and for
# ARP-based maintenance-mode discovery during enrollment.
# ===========================================================================
export inference_0_mac="00:00:00:00:00:00"   # TODO: set before enrolling the GPU node
