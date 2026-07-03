#!/bin/bash

# Countdown timer with optional status check
# Usage: countdown_with_check <seconds> [check_command]
countdown_with_check() {
    local seconds=$1
    local check_func=$2
    local start_time=$(date +%s)
    local end_time=$((start_time + seconds))

    while true; do
        local current_time=$(date +%s)
        local remaining=$((end_time - current_time))

        if [ "$remaining" -le 0 ]; then
            break
        fi
            # Update the display
            if [ -n "$check_func" ]; then
                printf "\rTime remaining: %02d:%02d | Checking status...                 " $((remaining/60)) $((remaining%60))
            
                # 1. Handle special "port:<ip>:<port>" check with a pre-ping
                if [[ "$check_func" =~ ^port:([0-9\.]+):([0-9]+)$ ]]; then
                    local check_ip="${BASH_REMATCH[1]}"
                    local check_port="${BASH_REMATCH[2]}"
                    
                    # First check if the host is even pingable to clear 'no route to host'
                    if ping -c 1 -W 1 "$check_ip" >/dev/null 2>&1; then
                        if timeout 1 bash -c "</dev/tcp/$check_ip/$check_port" >/dev/null 2>&1; then
                            printf "\r[✓] $check_ip:$check_port is REACHABLE! (after %d seconds)          \n" $((current_time - start_time))
                            return 0
                        fi
                    fi
                # 2. Otherwise execute as a command
                elif eval "$check_func" >/dev/null 2>&1; then
                printf "\r[✓] Success detected! (after %d seconds)          \n" $((current_time - start_time))
                return 0
            fi
        else
            printf "\rWaiting: %02d:%02d remaining...                             " $((remaining/60)) $((remaining%60))
        fi

        sleep 1
    done

    printf "\r[!] Timeout/Wait complete.                               \n"
    return 1
}


getNodeIP(){
  local nodeName=$1
  result=$(sudo virsh domifaddr "${nodeName}" | grep -E '/' | awk '{print $4}' | cut -d/ -f1 | head -n 1)
  echo "$result"
}


# Robust check for Talos API readiness
# Usage: wait_for_talos <ip> <timeout_seconds>
wait_for_talos() {
    local node_ip=$1
    local timeout=$2
    local end=$(( $(date +%s) + timeout ))
    local last_error=""

    if [ -z "$node_ip" ]; then
        echo "[!] Error: wait_for_talos called with empty IP"
        return 1
    fi

    echo "Waiting for Talos API at $node_ip (timeout ${timeout}s)..."
    while [ $(date +%s) -lt $end ]; do
        # 1. Check if the host is pingable;
        if ! ping -c 1 -W 1 "$node_ip" >/dev/null 2>&1; then
            printf "p" # p for ping failure (no route or host down)
            sleep 2
            continue
        fi

        # 2. Check Talos API
        # We use 'talosctl version' because it requires a successful rpc handshake.
        # We use --insecure because at early stages (maintenance mode) certs might not be set.
        # In maintenance mode, 'version' might return "Unimplemented", but this still confirms the API is reachable.
        last_error=$(sudo -E "${TALOS_ROOT}/talosctl" version --nodes "$node_ip" --talosconfig "${TALOSCONFIG}" --short --insecure 2>&1)
        if [ $? -eq 0 ] || [[ "$last_error" == *"API is not implemented in maintenance mode"* ]]; then
            echo -e "\n[✓] Talos API is ready at $node_ip"
            return 0
        fi
        
        printf "a" # a for API failure (host up but service not ready)
        sleep 2
    done
    echo -e "\n[!] Timeout waiting for Talos API at $node_ip"
    echo "Last error: $last_error"
    return 1
}

# Wait for Talos services to be healthy
# Usage: wait_for_talos_health <nodes> <timeout_seconds>
wait_for_talos_health() {
    local nodes=$1
    local timeout=$2
    local end=$(( $(date +%s) + timeout ))

    echo "Waiting for Talos health on nodes: $nodes..."
    while [ $(date +%s) -lt $end ]; do
        if sudo -E "${TALOS_ROOT}/talosctl" health --nodes "$nodes" --talosconfig "${TALOSCONFIG}" --wait-timeout 5s >/dev/null 2>&1; then
            echo "[✓] Talos health check passed for $nodes"
            return 0
        fi
        printf "."
        sleep 5
    done
    echo -e "\n[!] Timeout waiting for Talos health on $nodes"
    return 1
}

# Wait for a specific Talos resource to appear
# Usage: wait_for_talos_resource <node> <resource_type> <timeout_seconds>
wait_for_talos_resource() {
    local node=$1
    local resource=$2
    local timeout=$3
    local end=$(( $(date +%s) + timeout ))

    echo "Waiting for Talos resource $resource on $node..."
    while [ $(date +%s) -lt $end ]; do
        if sudo -E "${TALOS_ROOT}/talosctl" get "$resource" --nodes "$node" --talosconfig "${TALOSCONFIG}" >/dev/null 2>&1; then
            echo "[✓] Resource $resource is available on $node"
            return 0
        fi
        sleep 2
    done
    echo "[!] Timeout waiting for resource $resource on $node"
    return 1
}

# Preflight: best-effort check of node Talos version; NEVER block apply
# Usage: preflight_check_version <node_ip>
preflight_check_version() {
    local node_ip="$1"
    if [ -z "${node_ip}" ]; then
        echo "WARN: preflight_check_version called with empty IP; proceeding" >&2
        return 0
    fi
    echo "Preflight: checking Talos server version on ${node_ip}"
    local out ver maj min status
    # Try to fetch version quickly; DO NOT block apply on any outcome.
    # Use talosctl built-in timeout to avoid external `timeout` dependency.
    # Also guard against `set -e` aborting on non-zero by temporarily disabling errexit.
    set +e
    out=$(sudo -E "${TALOS_ROOT}/talosctl" --timeout 5s version --nodes "${node_ip}" --insecure --talosconfig "${TALOSCONFIG}" 2>&1)
    status=$?
    set -e
    # Maintenance mode or unreachable: proceed
    if printf '%s\n' "${out}" | grep -qi 'API is not implemented in maintenance mode'; then
        echo "OK: Node ${node_ip} Talos in maintenance mode; proceeding"
        return 0
    fi
    if [ ${status} -ne 0 ]; then
        echo "WARN: Talos API not reachable or version unavailable on ${node_ip}; proceeding"
        return 0
    fi
    # If we have a version, parse and log; never block
    ver="$(printf '%s\n' "${out}" | awk -F': ' '/^Server:/ {print $2; exit}')"
    if [ -n "${ver}" ]; then
        maj="$(printf '%s' "${ver}" | sed -E 's/^v([0-9]+)\..*/\1/')"
        min="$(printf '%s' "${ver}" | sed -E 's/^v[0-9]+\.([0-9]+).*/\1/')"
        if [ -n "${maj}" ] && [ -n "${min}" ] && { [ "${maj}" -gt 1 ] || { [ "${maj}" -eq 1 ] && [ "${min}" -ge 12 ]; }; }; then
            echo "OK: Node ${node_ip} is running Talos ${ver} (>= 1.12)"
        else
            echo "WARN: Node ${node_ip} reported Talos ${ver} (< 1.12); proceeding for fresh install"
        fi
    else
        echo "WARN: Could not parse Talos server version on ${node_ip}; proceeding"
    fi
    return 0
}