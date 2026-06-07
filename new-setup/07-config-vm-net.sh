# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source ${SETUP_ROOT}/new-setup/05-MAC-addresses.sh
source ${SETUP_ROOT}/new-setup/utils.sh

# talos-nat.xml:
# This is the 'first interface' for management and internet access.
# forward mode=nat causes libvirt/dnsmasq to advertise 10.0.0.1 as the default
# gateway via DHCP (option 3), which VMs need to reach the internet.
# DNS forwarders ensure VMs use the local DNS server (192.168.1.210).
cat > talos-nat.xml <<EOF
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
      <host mac="${data_0_mac}" name="worker-0" ip="10.0.0.110"/>      
      <host mac="${data_1_mac}" name="worker-1" ip="10.0.0.111"/>      
      <host mac="${data_2_mac}" name="worker-2" ip="10.0.0.112"/>      
      <host mac="${data_3_mac}" name="worker-3" ip="10.0.0.113"/>      
      <host mac="${inference_0_mac}" name="inference-0" ip="10.0.0.120"/>      
      <host mac="${inference_1_mac}" name="inference-1" ip="10.0.0.121"/>      
    </dhcp>
  </ip>
</network>
EOF

sudo virsh net-destroy talos-nat 2>/dev/null || true
sudo virsh net-undefine talos-nat 2>/dev/null || true
sudo virsh net-define talos-nat.xml
sudo virsh net-start talos-nat
sudo virsh net-autostart talos-nat

# lb-net.xml:
# This is the 'second interface' for direct L2 access to the local network.
# It allows VMs to have IPs directly on the 192.168.x.x LAN for application access.
cat > lb-net.xml <<EOF
<network>
  <name>lb-net</name>
  <forward mode='bridge'/>
  <bridge name='br-app'/>
</network>
EOF

sudo virsh net-destroy lb-net 2>/dev/null || true
sudo virsh net-undefine lb-net 2>/dev/null || true
sudo virsh net-define lb-net.xml
sudo virsh net-start lb-net
sudo virsh net-autostart lb-net
