# Check if we are running on the target host 'hierophant'
echo "Verifying host environment..."
if ! ip link show enp5s0 &>/dev/null || ! ip link show eno1 &>/dev/null; then
    echo "WARNING: This script is intended to run on the target host (hierophant)."
    if [ -z "$FRESH_INSTALL" ]; then
        read -p "Do you want to continue anyway? (yes/no): " host_resp
        if [[ ! "$host_resp" =~ ^[Yy][Ee][Ss]|[Yy]$ ]]; then
            exit 1
        fi
    fi
fi

# Clean up existing connections
echo "Cleaning up existing network connections..."
# Delete bridge and slave connections first
# We now avoid bridging enp5s0 to ensure host stability
# Note: eno1 is handled separately to ensure it is always managed
for con in br-mgmt br-app enp5s0-slave eno1-slave eno1 br-master br-lb veth-mgmt-master veth-mgmt-slave veth-lb-master veth-lb-slave eno0-slave eno1.20 eno1.20-slave; do
    sudo nmcli connection delete "$con" 2>/dev/null || true
done

# Ensure eno1 is up and managed but has no IP
# We use a dedicated profile for the physical interface to ensure the VLAN sub-interface can bind to it.
echo "Ensuring eno1 is managed with no IP..."
sudo nmcli connection add type ethernet con-name eno1 ifname eno1 ipv4.method disabled ipv6.method disabled
sudo nmcli connection up eno1

echo "1) Configure 'enp5s0' as a standalone management interface"
# Ensure enp5s0 has the required static IP and is NOT bridged.
# This provides maximum stability for host management and NAT uplink.
if ! nmcli connection show enp5s0 &>/dev/null; then
    sudo nmcli connection add type ethernet con-name enp5s0 ifname enp5s0 ipv4.method manual ipv4.addresses 192.168.1.101/24 ipv4.gateway 192.168.1.1 ipv4.dns "192.168.1.210,1.1.1.1,8.8.8.8" ipv4.dns-search "hierocracy,hierocracy.home"
else
    sudo nmcli connection modify enp5s0 ipv4.method manual ipv4.addresses 192.168.1.101/24 ipv4.gateway 192.168.1.1 ipv4.dns "192.168.1.210,1.1.1.1,8.8.8.8" ipv4.dns-search "hierocracy,hierocracy.home"
fi
sudo nmcli connection up enp5s0 || true

echo "2) Create the 'application' bridge with VLAN 20 isolation"
# We use VLAN 20 to isolate 'external' traffic and address 'dual home' adapter issues.
# This ensures that traffic on the 172.20.0.0/16 subnet is tagged on the physical wire
# if it leaves via eno1, while hierophant can still route between enp5s0 and br-app.

# 1. Create the bridge first
sudo nmcli connection add type bridge con-name br-app ifname br-app bridge.stp no

# 2. Configure IP on the bridge
sudo nmcli connection modify br-app ipv4.method manual ipv4.addresses 172.20.0.1/16 ipv6.method disabled

# 3. Create the VLAN sub-interface on eno1 and associate it with the bridge
# We specify master and slave-type during creation to avoid the "Cannot set 'controller' without 'port-type'" error.
sudo nmcli connection add type vlan con-name eno1.20 dev eno1 id 20 master br-app slave-type bridge

# 4. Bring them up
sudo nmcli connection up br-app
sudo nmcli connection up eno1.20

echo "3) The 'talos' bridge for the K8s control subnet will be managed by Libvirt"
# This bridge is used for the talos-nat virsh network (10.0.0.0/24)
# We don't create it here with nmcli to avoid conflicts with libvirt.

echo "4) Configure static routes for inter-VM and inter-host connectivity"
# Route to 'hegemon' host's internal VM network (for vscode-fedora-41 connectivity)
# This ensures that return traffic from the cluster to the dev VM can find its way back.
sudo ip route add 172.16.0.0/16 via 192.168.1.100 dev enp5s0 2>/dev/null || \
sudo ip route change 172.16.0.0/16 via 192.168.1.100 dev enp5s0

# Optimize ARP behavior and routing for multi-homed host on the same subnet
# 1. ARP optimization: ensures the host only responds to ARP requests on the correct interface.
# 2. RP Filter: Disabled (0) to allow asymmetric routing/multi-homing, which is required
#    because Talos nodes may receive traffic on br-app but reply via talos-bridge.
# 3. ARP Filter: Added to force the kernel to use the specific interface matching the route.
for iface in all default enp5s0 br-app talos-bridge; do
    sudo sysctl -w net.ipv4.conf.${iface}.arp_ignore=1 2>/dev/null || true
    sudo sysctl -w net.ipv4.conf.${iface}.arp_announce=2 2>/dev/null || true
    sudo sysctl -w net.ipv4.conf.${iface}.rp_filter=0 2>/dev/null || true
done

# Make network settings persistent
cat <<EOF | sudo tee /etc/sysctl.d/98-network-optimization.conf > /dev/null
net.ipv4.conf.all.arp_ignore=1
net.ipv4.conf.all.arp_announce=2
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.arp_ignore=1
net.ipv4.conf.default.arp_announce=2
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.enp5s0.arp_ignore=1
net.ipv4.conf.enp5s0.arp_announce=2
net.ipv4.conf.enp5s0.rp_filter=0
net.ipv4.conf.br-app.arp_ignore=1
net.ipv4.conf.br-app.arp_announce=2
net.ipv4.conf.br-app.rp_filter=0
net.ipv4.conf.talos-bridge.arp_ignore=1
net.ipv4.conf.talos-bridge.arp_announce=2
net.ipv4.conf.talos-bridge.rp_filter=0
EOF

echo "Enabling IP forwarding and NAT for VM traffic"
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-k8s-routing.conf > /dev/null

# Ensure NAT rule for the internal VM networks via enp5s0
# We NAT the Talos management network (10.0.0.0/24) for internet access.
# We also NAT the 172.20.0.0/16 network to resolve asymmetric routing issues with Talos.
# This forces Talos nodes to reply via the interface they received the request on.
for subnet in 10.0.0.0/24 172.20.0.0/16; do
    sudo iptables -t nat -D POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null || true
    sudo iptables -t nat -A POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE
done

# Force traffic from the LAN to the Application bridge to look like it comes from Hierophant
# This ensures return traffic from VMs (which might have wrong default gateways) goes back to Hierophant.
sudo iptables -t nat -D POSTROUTING -o br-app -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -o br-app -j MASQUERADE

# Ensure FORWARD chain allows traffic for the VM networks
# Note: We use -I to insert at the top, ensuring these are checked first.
for subnet in 10.0.0.0/24 172.20.0.0/16; do
    sudo iptables -D FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || true
    sudo iptables -I FORWARD -s "$subnet" -j ACCEPT
    sudo iptables -I FORWARD -d "$subnet" -j ACCEPT
done

# Configure IP Tables to allow forwarding between physical network and K8s bridge
# Allow all traffic from the cluster to the outside world
sudo iptables -D FORWARD -i br-app -o enp5s0 -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -i br-app -o enp5s0 -j ACCEPT
# Allow return traffic and specific incoming traffic from the physical network
sudo iptables -D FORWARD -i enp5s0 -o br-app -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -i enp5s0 -o br-app -m state --state RELATED,ESTABLISHED -j ACCEPT
# Allow new connections from the physical LAN to the LB network
sudo iptables -D FORWARD -i enp5s0 -o br-app -s 192.168.0.0/16 -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -i enp5s0 -o br-app -s 192.168.0.0/16 -j ACCEPT

# Allow new connections from the physical LAN to the Talos control-plane fabric
sudo iptables -D FORWARD -i enp5s0 -o talos-bridge -d 10.0.0.0/24 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -i enp5s0 -o talos-bridge -d 10.0.0.0/24 -m conntrack --ctstate NEW,RELATED,ESTABLISHED -j ACCEPT

# Allow forwarding between Talos bridge and LAN uplink
sudo iptables -D FORWARD -i talos-bridge -o enp5s0 -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -i talos-bridge -o enp5s0 -j ACCEPT
sudo iptables -D FORWARD -i enp5s0 -o talos-bridge -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -i enp5s0 -o talos-bridge -m state --state RELATED,ESTABLISHED -j ACCEPT


# Disable bridge-nf-call-iptables to prevent host iptables from interfering with bridged VM traffic
# and disable arptables/ebtables to ensure bridge performance.
if [ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=0
    sudo sysctl -w net.bridge.bridge-nf-call-arptables=0
    cat <<EOF | sudo tee /etc/sysctl.d/99-bridge-nf.conf > /dev/null
net.bridge.bridge-nf-call-iptables=0
net.bridge.bridge-nf-call-arptables=0
EOF
fi

echo "Network setup complete."
echo "Management Interface: enp5s0 - Host IP: 192.168.1.101/24"
echo "Application Bridge (VLAN 20): br-app - Host IP: 172.20.0.1/16"
echo "  Note: Traffic leaving via eno1 is tagged with VLAN 20."
echo "  Note: Hierophant will route between enp5s0 and br-app for local hosts."
echo "Talos Control Bridge: talos-bridge - Host IP: 10.0.0.1/24"
echo "Host NAT and forwarding enabled for 10.0.0.0/24 via enp5s0"
echo "172.20.0.0/16 is NATed via br-app and enp5s0 to resolve asymmetric routing issues."
