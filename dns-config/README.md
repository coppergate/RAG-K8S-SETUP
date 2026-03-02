# DNS Configuration for hierocracy.home

This directory contains BIND DNS configuration files for the hierocracy.home domain.

## Network Configuration

### Networks
- **192.168.1.0/24** - Primary network
  - Gateway: 192.168.1.1
  - DNS Server: 192.168.1.210 (diak

### Hosts
- **hegemon.hierocracy.home**
  - 192.168.1.100

- **hierophant.hierocracy.home**
  - 192.168.1.101
  - 
- **diakonia.hierocracy.home** (DNS server)
  - 192.168.1.210

## Files

- `named.conf` - Main BIND configuration file
- `db.hierocracy.home` - Forward zone file for hierocracy.home domain
- `db.192.168.1` - Reverse zone file for 192.168.1.0/24 network

## Installation

1. Copy zone files to `/etc/bind/zones/`:
   ```bash
   sudo mkdir -p /etc/bind/zones
   sudo cp db.* /etc/bind/zones/
   sudo chown bind:bind /etc/bind/zones/db.*
   ```

2. Include or merge `named.conf` settings into `/etc/bind/named.conf.home`:
   ```bash
   sudo cat named.conf >> /etc/bind/named.conf.home
   ```

3. Check configuration:
   ```bash
   sudo named-checkconf
   sudo named-checkzone hierocracy.home /etc/bind/zones/db.hierocracy.home
   sudo named-checkzone 1.168.192.in-addr.arpa /etc/bind/zones/db.192.168.1
   ```

4. Restart BIND:
   ```bash
   sudo systemctl restart bind9
   ```

## Testing

Test DNS resolution:
```bash
dig @192.168.1.210 hegemon.hierocracy.home
dig @192.168.1.210 -x 192.168.1.100
nslookup hegemon.hierocracy.home 192.168.1.210
```

## Upstream DNS
The DNS server forwards queries for external domains to:
- 8.8.8.8 (Google DNS)
- 8.8.4.4 (Google DNS)
