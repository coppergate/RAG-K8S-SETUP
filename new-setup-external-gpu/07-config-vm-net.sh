#!/bin/bash
# ==============================================================================
# VM NETWORK CONFIGURATION — new-setup-external-gpu
#
# Sets up two libvirt networks:
#   talos-nat  (10.0.0.0/24)   — NAT'd network for bootstrap registry access
#                                 and initial maintenance-mode config apply.
#                                 DHCP provides boot-time IPs to VMs.
#   lb-net     (172.20.0.0/16) — Bridged to br-app (eno1 VLAN 20).
#                                 VMs use static IPs on this network.
#                                 This is the PRIMARY management network for
#                                 ongoing cluster operations and talosctl.
#
# Additionally starts a dedicated dnsmasq instance on br-app to provide a
# static DHCP lease for the external GPU inference node during Talos enrollment.
# The inference node is a physical machine on the 172.20.x.x network — it has
# no talos-nat interface.
#
# BEFORE RUNNING: Set inference_0_mac in 05-MAC-addresses.sh to the actual
# MAC address of the GPU node's NIC.
# ==============================================================================
set -e

if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source ${SETUP_ROOT}/new-setup-external-gpu/05-MAC-addresses.sh
source ${SETUP_ROOT}/new-setup-external-gpu/utils.sh

# ---------------------------------------------------------------------------
# talos-nat: Internal NAT network for bootstrap registry and initial config
# ---------------------------------------------------------------------------
# forward mode=nat causes libvirt/dnsmasq to advertise 10.0.0.1 as the default
# gateway via DHCP (option 3), which VMs need to reach the bootstrap registry
# at 10.0.0.1:5000 during initial install.
cat > /tmp/talos-nat.xml <<EOF
<network>
  <name>talos-nat</name>
  <bridge name="talos-bridge" stp="on" delay="0"/>
  <forward mode="nat" dev="enp5s0">
    <nat/>
  </forward>
  <dns>
    <forwarder addr="192.168.1.210"/>
    <forwarder addr="8.8.8.8"/>
    <forwarder addr="1.1.1.1"/>
  </dns>
  <ip address="10.0.0.1" netmask="255.255.255.0">
    <dhcp>
      <range start="10.0.0.20" end="10.0.0.30"/>
      <host mac="${control_0_mac}" name="control-0" ip="10.0.0.200"/>
      <host mac="${control_1_mac}" name="control-1" ip="10.0.0.201"/>
      <host mac="${control_2_mac}" name="control-2" ip="10.0.0.202"/>
      <host mac="${data_0_mac}"    name="worker-0"  ip="10.0.0.110"/>
      <host mac="${data_1_mac}"    name="worker-1"  ip="10.0.0.111"/>
      <host mac="${data_2_mac}"    name="worker-2"  ip="10.0.0.112"/>
      <host mac="${data_3_mac}"    name="worker-3"  ip="10.0.0.113"/>
    </dhcp>
  </ip>
</network>
EOF

sudo virsh net-destroy talos-nat 2>/dev/null || true
sudo virsh net-undefine talos-nat 2>/dev/null || true
sudo virsh net-define /tmp/talos-nat.xml
sudo virsh net-start talos-nat
sudo virsh net-autostart talos-nat

# ---------------------------------------------------------------------------
# lb-net: Bridge to br-app (eno1 VLAN 20) — primary management network
# ---------------------------------------------------------------------------
# Pure bridge passthrough — no libvirt DHCP. VMs have static IPs (172.20.0.x)
# assigned in their Talos machine config patches.
# The external GPU node gets its DHCP lease from the dnsmasq instance below.
cat > /tmp/lb-net.xml <<EOF
<network>
  <name>lb-net</name>
  <forward mode='bridge'/>
  <bridge name='br-app'/>
</network>
EOF

sudo virsh net-destroy lb-net 2>/dev/null || true
sudo virsh net-undefine lb-net 2>/dev/null || true
sudo virsh net-define /tmp/lb-net.xml
sudo virsh net-start lb-net
sudo virsh net-autostart lb-net

# ---------------------------------------------------------------------------
# dnsmasq on br-app: DHCP for external GPU node enrollment
# ---------------------------------------------------------------------------
# Provides a static DHCP lease so the GPU node gets 172.20.1.120 when it
# boots the Talos USB installer and enters maintenance mode.
# DNS is disabled (--port=0) — this is a DHCP-only server.
# Only the static lease for the known MAC is served; all other MACs get
# addresses from the enrollment fallback range 172.20.1.100–172.20.1.200.
#
# NOTE: inference_0_mac must be updated in 05-MAC-addresses.sh before running.
# ---------------------------------------------------------------------------

if [ "${inference_0_mac}" = "00:00:00:00:00:00" ]; then
    echo ""
    echo "WARNING: inference_0_mac is not set in 05-MAC-addresses.sh."
    echo "         The GPU node will get a dynamic lease from 172.20.1.100-200"
    echo "         instead of the static 172.20.1.120 assignment."
    echo "         Update the MAC and re-run this script before enrolling the node."
    echo ""
fi

# Stop any existing br-app dnsmasq instance
sudo pkill -f "dnsmasq.*br-app-enrollment" 2>/dev/null || true
sleep 1

sudo dnsmasq \
    --conf-file=/dev/null \
    --interface=br-app \
    --bind-interfaces \
    --port=0 \
    --dhcp-range=172.20.1.100,172.20.1.200,1h \
    --dhcp-host="${inference_0_mac},172.20.1.120,inference-0" \
    --pid-file=/var/run/dnsmasq-br-app-enrollment.pid \
    --log-facility=/var/log/dnsmasq-br-app-enrollment.log \
    --no-resolv

echo ""
echo "br-app dnsmasq started (PID: $(cat /var/run/dnsmasq-br-app-enrollment.pid 2>/dev/null || echo 'unknown'))"
echo "  Static lease: ${inference_0_mac} -> 172.20.1.120 (inference-0)"
echo "  Fallback range: 172.20.1.100-172.20.1.200"
echo ""
echo "Networks configured:"
sudo virsh net-list
