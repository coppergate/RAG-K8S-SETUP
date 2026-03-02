# DNS Configuration for hierocracy.local

This directory contains BIND DNS configuration files for the hierocracy.local domain.

## Network Configuration

### Networks
- **192.168.1.0/24** - Primary network
  - Gateway: 192.168.1.1
  - DNS Server: 192.168.1.210 (diakonia)

- **192.16.192.0/8** - Secondary network
  - Gateway: 192.168.1.1
  - DNS Server: 192.16.192.210 (diakonia)

### Hosts
- **hegemon.hierocracy.local**
  - 192.168.1.100
  - 192.16.192.100

- **hierophant.hierocracy.local**
  - 192.168.1.101
  - 192.16.192.101

- **diakonia.hierocracy.local** (DNS server)
  - 192.168.1.210
  - 192.16.192.210

## Files

- `named.conf` - Main BIND configuration file
- `db.hierocracy.local` - Forward zone file for hierocracy.local domain
- `db.192.168.1` - Reverse zone file for 192.168.1.0/24 network
- `db.192.16.192` - Reverse zone file for 192.16.192.0/8 network

## Installation

1. Copy zone files to `/etc/bind/zones/`:
   ```bash
   sudo mkdir -p /etc/bind/zones
   sudo cp db.* /etc/bind/zones/
   sudo chown bind:bind /etc/bind/zones/db.*
   ```

2. Include or merge `named.conf` settings into `/etc/bind/named.conf.local`:
   ```bash
   sudo cat named.conf >> /etc/bind/named.conf.local
   ```

3. Check configuration:
   ```bash
   sudo named-checkconf
   sudo named-checkzone hierocracy.local /etc/bind/zones/db.hierocracy.local
   sudo named-checkzone 1.168.192.in-addr.arpa /etc/bind/zones/db.192.168.1
   sudo named-checkzone 192.16.192.in-addr.arpa /etc/bind/zones/db.192.16.192
   ```

4. Restart BIND:
   ```bash
   sudo systemctl restart bind9
   ```

## Testing

Test DNS resolution:
```bash
dig @192.168.1.210 hegemon.hierocracy.local
dig @192.168.1.210 -x 192.168.1.100
nslookup hegemon.hierocracy.local 192.168.1.210
```

## Upstream DNS
The DNS server forwards queries for external domains to:
- 8.8.8.8 (Google DNS)
- 8.8.4.4 (Google DNS)
