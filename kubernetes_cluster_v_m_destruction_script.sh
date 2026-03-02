#!/bin/bash

# Script to destroy and remove VMs created by kubernetes_v_ms_setup.sh
# This will completely remove the VMs and their storage volumes
# Optionally removes storage pools as well

set -e

# Default configuration file
DEFAULT_CONFIG_FILE="K8sNodeConfiguration.json"
CONFIG_FILE=""
REMOVE_POOLS=false
REMOVE_NETWORK=false

# Storage pool configuration (fallback if no config file)
STORAGE_POOL="default"
STORAGE_POOL_DIR="/var/lib/libvirt/storage"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --config FILE       JSON configuration file (default: $DEFAULT_CONFIG_FILE)"
    echo "  --remove-pools      Also remove storage pools (default: keep pools)"
    echo "  --remove-network    Also remove virtual network (default: keep network)"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Use default config, keep pools and network"
    echo "  $0 --config my-config.json            # Use custom config, keep pools and network"
    echo "  $0 --remove-pools --remove-network    # Remove VMs, pools, and network"
    echo "  $0 --config my-config.json --remove-pools --remove-network"
    exit 0
}

# Function to destroy and remove a single VM
destroy_vm() {
    local vm_name="$1"
    local vm_index="$2"

    print_status $YELLOW "Processing VM: $vm_name"

    # Check if VM exists
    if ! sudo virsh dominfo "$vm_name" >/dev/null 2>&1; then
        print_status $YELLOW "  VM $vm_name does not exist, skipping..."
    else      
      # Get VM state
      local vm_state=$(sudo virsh domstate "$vm_name" 2>/dev/null || echo "undefined")
      print_status $YELLOW "  Current state: $vm_state"
  
      # Force shutdown if running
      if [ "$vm_state" = "running" ]; then
          print_status $YELLOW "  Forcing shutdown of $vm_name..."
          sudo virsh destroy "$vm_name" 2>/dev/null || true
          sleep 2
      fi
  
      # Undefine the VM (remove configuration)
      # Note: We manually remove storage volumes, so we don't use --remove-all-storage
      # This prevents accidentally deleting .raw boot images that are shared between VMs
      print_status $YELLOW "  Undefining VM $vm_name..."
      sudo virsh undefine "$vm_name" --snapshots-metadata --checkpoints-metadata 2>/dev/null || {
          # Fallback: try without extra options
          print_status $YELLOW "  Trying fallback undefine method..."
          sudo virsh undefine "$vm_name" 2>/dev/null || true
      }
  
      # Remove storage volumes manually if they still exist
      remove_storage_volumes "$vm_name" "$vm_index"
  
      print_status $GREEN "  ✓ Successfully removed $vm_name"
    fi

    print_status $YELLOW "Processed VM: $vm_name"
}

# Function to remove storage volumes for a specific VM
remove_storage_volumes() {
    local vm_name="$1"
    local vm_index="$2"

    # Get storage configuration for this VM from JSON
    if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
        local vm_storage_class=$(jq -r ".vms[$vm_index].vm_storage_class // \"$STORAGE_POOL\"" "$CONFIG_FILE" 2>/dev/null)
        local vm_data_storage_class=$(jq -r ".vms[$vm_index].vm_data_storage_class // null" "$CONFIG_FILE" 2>/dev/null)
        local vm_storage_device=$(jq -r ".vms[$vm_index].vm_storage_device // null" "$CONFIG_FILE" 2>/dev/null)
        local vm_data_storage_device=$(jq -r ".vms[$vm_index].vm_data_storage_device // null" "$CONFIG_FILE" 2>/dev/null)
    else
        local vm_storage_class="$STORAGE_POOL"
        local vm_data_storage_class="null"
        local vm_storage_device="null"
        local vm_data_storage_device="null"
    fi

    # Remove main system volume (only if not using raw device)
    if [ "$vm_storage_device" = "null" ] || [ -z "$vm_storage_device" ]; then
        if sudo virsh vol-info --pool "$vm_storage_class" "$vm_name.qcow2" >/dev/null 2>&1; then
            print_status $YELLOW "  Removing system volume from pool '$vm_storage_class': $vm_name.qcow2"
            sudo virsh vol-delete --pool "$vm_storage_class" "$vm_name.qcow2" 2>/dev/null || true
        fi
    else
        print_status $BLUE "  System storage uses raw device $vm_storage_device (not removing)"
    fi

    # Remove persistent data volume if it exists (only if not using raw device)
    if [ "$vm_data_storage_class" != "null" ] && [ -n "$vm_data_storage_class" ]; then
        if [ "$vm_data_storage_device" = "null" ] || [ -z "$vm_data_storage_device" ]; then
            if sudo virsh vol-info --pool "$vm_data_storage_class" "$vm_name-data.img" >/dev/null 2>&1; then
                print_status $YELLOW "  Removing data volume from pool '$vm_data_storage_class': $vm_name-data.img"
                sudo virsh vol-delete --pool "$vm_data_storage_class" "$vm_name-data.img" 2>/dev/null || true
            fi
        else
            print_status $BLUE "  Data storage uses raw device $vm_data_storage_device (not removing)"
        fi
    fi

    # Clean up any remaining VM-specific files manually in all possible storage pool directories
    # Only remove qcow2 and img files, preserve .raw, .iso, and other source images
    local base_dir="/var/lib/libvirt/storage-pools"
    if [ -d "$base_dir" ]; then
        for pool_dir in "$base_dir"/*; do
            if [ -d "$pool_dir" ]; then
                for file_pattern in "$pool_dir/$vm_name.qcow2" "$pool_dir/$vm_name-data.img"; do
                    if [ -f "$file_pattern" ]; then
                        print_status $YELLOW "  Removing file: $file_pattern"
                        sudo rm -f "$file_pattern" 2>/dev/null || true
                    fi
                done
            fi
        done
    fi

    # Also check default libvirt images directory
    if [ -d "$STORAGE_POOL_DIR" ]; then
        for file_pattern in "$STORAGE_POOL_DIR/$vm_name.qcow2" "$STORAGE_POOL_DIR/$vm_name-data.img"; do
            if [ -f "$file_pattern" ]; then
                print_status $YELLOW "  Removing file: $file_pattern"
                sudo rm -f "$file_pattern" 2>/dev/null || true
            fi
        done
    fi

    # Clean up any temporary XML files
    for xml_file in "./work-build-vm-$vm_name"*.xml; do
        if [ -f "$xml_file" ]; then
            print_status $YELLOW "  Removing temporary file: $xml_file"
            rm -f "$xml_file" 2>/dev/null || true
        fi
    done
}

# Function to load VM names from config
load_vms_from_config() {
    local config="$1"

    if [ ! -f "$config" ]; then
        print_status $YELLOW "Warning: Configuration file '$config' not found"
        print_status $YELLOW "Using hardcoded VM list..."
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        print_status $YELLOW "Warning: 'jq' not available"
        print_status $YELLOW "Using hardcoded VM list..."
        return 1
    fi

    # Extract VM names from config
    mapfile -t ALL_VMS < <(jq -r '.vms[].name' "$config" 2>/dev/null)

    if [ ${#ALL_VMS[@]} -eq 0 ]; then
        print_status $YELLOW "Warning: No VMs found in configuration"
        print_status $YELLOW "Using hardcoded VM list..."
        return 1
    fi

    print_status $GREEN "✓ Loaded ${#ALL_VMS[@]} VM(s) from configuration"
    return 0
}

# Function to show confirmation prompt
confirm_destruction() {
    print_status $RED "=========================================="
    print_status $RED "WARNING: VM DESTRUCTION"
    print_status $RED "=========================================="
    print_status $RED "This will PERMANENTLY DESTROY the following VMs:"
    echo ""

    for vm in "${ALL_VMS[@]}"; do
        print_status $YELLOW "  - $vm"
    done

    echo ""
    print_status $RED "Actions that will be performed:"
    print_status $RED "  1. Force shutdown running VMs"
    print_status $RED "  2. Remove VM configurations"
    print_status $RED "  3. Delete all storage volumes"
    print_status $RED "  4. Clean up temporary files"
    local step=5
    if [ "$REMOVE_POOLS" = true ]; then
        print_status $RED "  $step. Remove storage pools (directories preserved)"
        ((step++))
    fi
    if [ "$REMOVE_NETWORK" = true ]; then
        print_status $RED "  $step. Remove virtual network"
    fi
    echo ""
    print_status $RED "THIS ACTION CANNOT BE UNDONE!"
    echo ""

    read -p "Are you sure you want to proceed? (yes/no): " confirmation

    if [ "$confirmation" != "yes" ]; then
        print_status $YELLOW "Operation cancelled by user."
        exit 0
    fi
}

# Main execution
main() {
    print_status $YELLOW "Kubernetes Cluster VM Destruction Script"
    print_status $YELLOW "=========================================="
    echo ""

    # Show confirmation prompt
    confirm_destruction

    echo ""
    print_status $YELLOW "Starting VM destruction process..."
    echo ""

    # Destroy all VMs
    print_status $YELLOW "Destroying VMs..."
    print_status $YELLOW "================="
    local index=0
    
    for vm in "${ALL_VMS[@]}"; do
        print_status $YELLOW "  - $vm"
        destroy_vm "$vm" "$index"
        (( index+=1 ))
    done

    # Final cleanup and verification
    print_status $YELLOW "Performing final cleanup..."
    cleanup_remaining_files

    print_status $GREEN "=========================================="
    print_status $GREEN "VM Destruction Complete!"
    print_status $GREEN "=========================================="

    # Show final status
    show_final_status
}

# Function to clean up any remaining files
cleanup_remaining_files() {
    # Clean up any remaining XML files
    for xml_file in ./work-build-vm-*.xml ./vol_store_*.xml ./network-setup.xml ./pool-create.xml; do
        if [ -f "$xml_file" ]; then
            print_status $YELLOW "  Removing leftover file: $xml_file"
            rm -f "$xml_file" 2>/dev/null || true
        fi
    done
}

# Function to show final status
show_final_status() {
    print_status $YELLOW "Final VM Status Check:"
    print_status $YELLOW "====================="
    
    local remaining_vms=0
    for vm in "${ALL_VMS[@]}"; do
        if sudo virsh dominfo "$vm" >/dev/null 2>&1; then
            print_status $RED "  ✗ $vm: Still exists (manual cleanup required)"
            ((remaining_vms++))
        else
            print_status $GREEN "  ✓ $vm: Successfully removed"
        fi
    done
    
    echo ""
    if [ $remaining_vms -eq 0 ]; then
        print_status $GREEN "All VMs have been successfully destroyed and removed!"
    else
        print_status $RED "Warning: $remaining_vms VM(s) may require manual cleanup."
        print_status $YELLOW "Try running: sudo virsh undefine <vm-name> --remove-all-storage"
    fi
    
    print_status $YELLOW ""
    print_status $YELLOW "Useful commands for manual cleanup if needed:"
    print_status $YELLOW "  sudo virsh list --all                    # List all VMs"
    print_status $YELLOW "  sudo virsh vol-list --pool $STORAGE_POOL # List storage volumes"
    print_status $YELLOW "  sudo virsh pool-refresh $STORAGE_POOL    # Refresh storage pool"

    # Remove storage pools if requested
    if [ "$REMOVE_POOLS" = true ]; then
        echo ""
        print_status $YELLOW "=========================================="
        print_status $YELLOW "Removing Storage Pools"
        print_status $YELLOW "=========================================="

        STORAGE_POOL_SCRIPT="./setup_storage_pools.sh"
        if [ -f "$STORAGE_POOL_SCRIPT" ] && [ -n "$CONFIG_FILE" ]; then
            print_status $YELLOW "Running storage pool cleanup..."
            sudo "$STORAGE_POOL_SCRIPT" --config "$CONFIG_FILE" --cleanup || {
                print_status $YELLOW "Warning: Storage pool cleanup encountered issues"
            }
        else
            if [ ! -f "$STORAGE_POOL_SCRIPT" ]; then
                print_status $YELLOW "Warning: setup_storage_pools.sh not found"
            fi
            if [ -z "$CONFIG_FILE" ]; then
                print_status $YELLOW "Warning: No configuration file specified for pool cleanup"
            fi
            print_status $YELLOW "Skipping automatic storage pool cleanup"
            print_status $YELLOW "To remove pools manually:"
            print_status $YELLOW "  sudo virsh pool-destroy <pool-name>"
            print_status $YELLOW "  sudo virsh pool-undefine <pool-name>"
        fi
    fi

    # Remove virtual network if requested
    if [ "$REMOVE_NETWORK" = true ]; then
        echo ""
        print_status $YELLOW "=========================================="
        print_status $YELLOW "Removing Virtual Network"
        print_status $YELLOW "=========================================="

        NETWORK_SETUP_SCRIPT="./setup_virtual_network.sh"
        if [ -f "$NETWORK_SETUP_SCRIPT" ] && [ -n "$CONFIG_FILE" ]; then
            print_status $YELLOW "Running virtual network cleanup..."
            sudo "$NETWORK_SETUP_SCRIPT" --config "$CONFIG_FILE" --cleanup || {
                print_status $YELLOW "Warning: Virtual network cleanup encountered issues"
            }
        else
            if [ ! -f "$NETWORK_SETUP_SCRIPT" ]; then
                print_status $YELLOW "Warning: setup_virtual_network.sh not found"
            fi
            if [ -z "$CONFIG_FILE" ]; then
                print_status $YELLOW "Warning: No configuration file specified for network cleanup"
            fi
            print_status $YELLOW "Skipping automatic network cleanup"
            print_status $YELLOW "To remove network manually:"
            print_status $YELLOW "  sudo virsh net-destroy <network-name>"
            print_status $YELLOW "  sudo virsh net-undefine <network-name>"
        fi
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --remove-pools)
            REMOVE_POOLS=true
            shift
            ;;
        --remove-network)
            REMOVE_NETWORK=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            print_status $RED "Unknown option: $1"
            usage
            ;;
    esac
done

# Use default config if none specified
if [ -z "$CONFIG_FILE" ] && [ -f "$DEFAULT_CONFIG_FILE" ]; then
    CONFIG_FILE="$DEFAULT_CONFIG_FILE"
    print_status $BLUE "Using default configuration: $CONFIG_FILE"
fi

# Load VM list from config
if ! load_vms_from_config "$CONFIG_FILE"; then
    print_status $RED "Error: Could not load VM list from configuration"
    print_status $RED "Please specify a valid configuration file with --config"
    exit 1
fi

# Handle script interruption
trap 'print_status $RED "\nScript interrupted. Some VMs may be partially destroyed."; exit 1' INT TERM

# Execute main function
main

print_status $GREEN "Script completed successfully!"
