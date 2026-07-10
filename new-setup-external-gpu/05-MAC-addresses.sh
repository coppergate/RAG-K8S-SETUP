export mac_prefix="6A:69:11:AA:00"
export control_0_mac="${mac_prefix}:A1"
export control_1_mac="${mac_prefix}:A2"
export control_2_mac="${mac_prefix}:A3"
export data_0_mac="${mac_prefix}:A4"
export data_1_mac="${mac_prefix}:A5"
export data_2_mac="${mac_prefix}:A6"
export data_3_mac="${mac_prefix}:A7"

export extern_mac_prefix="6A:69:11:AA:10"
export control_0_extern_mac="${extern_mac_prefix}:A1"
export control_1_extern_mac="${extern_mac_prefix}:A2"
export control_2_extern_mac="${extern_mac_prefix}:A3"
export data_0_extern_mac="${extern_mac_prefix}:A4"
export data_1_extern_mac="${extern_mac_prefix}:A5"
export data_2_extern_mac="${extern_mac_prefix}:A6"
export data_3_extern_mac="${extern_mac_prefix}:A7"

# ===========================================================================
# External GPU inference node — physical machine on 172.20.x.x (lb-net)
# Set this to the actual NIC MAC address of the GPU node.
# Run 'ip link show' on the node or check BIOS/UEFI to find the MAC.
# Used for: DHCP static lease on br-app, and Talos interface matching.
# ===========================================================================
inference_0_mac="00:00:00:00:00:00"   # TODO: set before running setup
