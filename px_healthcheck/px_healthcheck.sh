#!/bin/bash

# Portworx Health Check Script
# Author - Upinder Sujlana
# version - 1.5



set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # this is for no color

# Global variables
CLI_TOOL=""
KUBECONFIG_PATH=""
PX_NAMESPACE=""
SELECTED_POD=""
PX_SECURITY_ENABLED=""
PX_AUTH_TOKEN=""
PX_CLUSTER_VERSION=""

# log file with timestamp
LOG_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="/tmp/px-healthcheck_${LOG_TIMESTAMP}.log"

# arrays to store warnings and errors for summary eventually
declare -a WARNINGS=()
declare -a ERRORS=()

strip_colors() {
    sed 's/\x1b\[[0-9;]*m//g'
}

exec > >(tee >(strip_colors >> "$LOG_FILE")) 2>&1

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    # Store warning message without color codes for summary
    WARNINGS+=("$msg")
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg"
    # Store error message without color codes for summary
    ERRORS+=("$msg")
}

# ensure user inputs y, Y, n, N only 
validate_yes_no_input() {
    local prompt="$1"
    local response
    while true; do
        read -p "$prompt" response
        if [[ "$response" == "y" ]] || [[ "$response" == "Y" ]]; then
            echo "y"
            return 0
        elif [[ "$response" == "n" ]] || [[ "$response" == "N" ]]; then
            echo "n"
            return 0
        else
            echo -e "${RED}[ERROR]${NC} Invalid input. Please enter 'y' or 'n'." >&2
        fi
    done
}

# prompt for CLI tool selection
select_cli_tool() {
    echo ""
    echo "========================================="
    echo "  Portworx Health Check Script"
    echo "========================================="
    echo ""

    while true; do
        read -p "Are you using 'kubectl' or 'oc'? (kubectl/oc): " cli_input
        cli_input=$(echo "$cli_input" | tr '[:upper:]' '[:lower:]')

        if [[ "$cli_input" == "kubectl" ]] || [[ "$cli_input" == "oc" ]]; then
            CLI_TOOL="$cli_input"
            print_info "Using CLI tool: $CLI_TOOL"
            break
        else
            print_error "Invalid input. Please enter 'kubectl' or 'oc'."
        fi
    done
}

# Get the kubeconfig from user
select_kubeconfig() {
    echo ""
    while true; do
        read -p "Enter the path to your kubeconfig file (or press Enter to use default): " kubeconfig_input

        if [[ -z "$kubeconfig_input" ]]; then
            print_info "Using default kubeconfig"
            KUBECONFIG_PATH=""
            break
        else
            # Expand and resolve relative paths
            kubeconfig_input="${kubeconfig_input/#\~/$HOME}"
            kubeconfig_input="$(cd "$(dirname "$kubeconfig_input")" 2>/dev/null && pwd)/$(basename "$kubeconfig_input")" 2>/dev/null || kubeconfig_input="$kubeconfig_input"

            if [[ -f "$kubeconfig_input" ]]; then
                KUBECONFIG_PATH="$kubeconfig_input"
                print_info "Using kubeconfig: $KUBECONFIG_PATH"

                # Validate kubeconfig file
                echo ""
                print_info "Validating kubeconfig file..."
                local validation_output
                validation_output=$($CLI_TOOL --kubeconfig="$KUBECONFIG_PATH" config view 2>&1)
                local validation_exit_code=$?

                if [[ $validation_exit_code -ne 0 ]]; then
                    print_error "Invalid kubeconfig file. Error details:"
                    echo "$validation_output" | head -5
                    echo ""
                    print_error "Please fix the kubeconfig file and try again."
                    print_info "Common issues:"
                    echo "  - Invalid base64 encoded certificates"
                    echo "  - Malformed YAML syntax"
                    echo "  - Missing required fields (clusters, users, contexts)"
                    echo ""
                    continue
                fi
                print_info "Kubeconfig file is valid."

                # Show current context and available contexts
                echo ""
                local current_context
                current_context=$($CLI_TOOL --kubeconfig="$KUBECONFIG_PATH" config current-context 2>/dev/null) || current_context=""

                if [[ -n "$current_context" ]]; then
                    print_info "Current context: $current_context"
                else
                    print_warning "Could not determine current context. The kubeconfig may not have a current-context set."
                fi

                # Get list of available contexts
                echo ""
                print_info "Available contexts in this kubeconfig:"
                echo "----------------------------------------"
                $CLI_TOOL --kubeconfig="$KUBECONFIG_PATH" config get-contexts --no-headers 2>/dev/null | awk '{if ($1 == "*") print NR") " $2; else print NR") " $1}' || print_warning "Could not list contexts"
                echo "----------------------------------------"
                echo ""

                local confirm
                confirm=$(validate_yes_no_input "Do you want to use the current context '$current_context'? (y/n): ")
                if [[ "$confirm" == "y" ]]; then
                    break
                else
                    # if user wants to switch context
                    echo ""
                    local context_list
                    context_list=$($CLI_TOOL --kubeconfig="$KUBECONFIG_PATH" config get-contexts --no-headers 2>/dev/null | awk '{if ($1 == "*") print $2; else print $1}')
                    local context_count
                    context_count=$(echo "$context_list" | wc -l | tr -d ' ')

                    if [[ "$context_count" -le 1 ]]; then
                        print_warning "Only one context available. Using: $current_context"
                        break
                    fi

                    read -p "Enter the number of the context you want to use: " context_num
                    local selected_context
                    selected_context=$(echo "$context_list" | sed -n "${context_num}p")

                    if [[ -n "$selected_context" ]]; then
                        print_info "Switching to context: $selected_context"
                        $CLI_TOOL --kubeconfig="$KUBECONFIG_PATH" config use-context "$selected_context" 2>/dev/null
                        if [[ $? -eq 0 ]]; then
                            print_info "Successfully switched to context: $selected_context"
                            break
                        else
                            print_error "Failed to switch context. Please try again."
                        fi
                    else
                        print_error "Invalid selection. Please try again."
                    fi
                fi
            else
                print_error "File not found: $kubeconfig_input"
                print_error "Please enter a valid path to the kubeconfig file."
            fi
        fi
    done

    # Test cluster connectivity to ensure kubeconfig works
    # using command kubectl/oc --kubeconfig=/path/to/kubeconfig cluster-info
    echo ""
    print_info "Testing cluster connectivity..."
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    local connectivity_output
    connectivity_output=$($cmd cluster-info 2>&1) || true

    if echo "$connectivity_output" | grep -q "Kubernetes control plane\|Kubernetes master"; then
        print_info "Successfully connected to cluster."
        # Show cluster info summary
        echo "$connectivity_output" | head -2
    else
        print_error "Failed to connect to cluster. Error:"
        echo "$connectivity_output" | head -5
        echo ""
        print_error "Please check:"
        echo "  - Network connectivity to the cluster"
        echo "  - VPN connection (if required)"
        echo "  - Cluster API server is running"
        echo "  - Authentication credentials are valid"
        echo ""
        local continue_anyway
        continue_anyway=$(validate_yes_no_input "Do you want to continue anyway? (y/n): ")
        if [[ "$continue_anyway" != "y" ]]; then
            print_error "Exiting. Please fix connectivity issues and try again."
            exit 1
        fi
    fi
}

# Function to confirm Portworx namespace
confirm_namespace() {
    echo ""
    while true; do
        read -p "Enter the namespace where Portworx is installed (default: portworx): " ns_input
        
        if [[ -z "$ns_input" ]]; then
            PX_NAMESPACE="portworx"
        else
            PX_NAMESPACE="$ns_input"
        fi
        
        print_info "Portworx namespace set to: $PX_NAMESPACE"
        local confirm
        confirm=$(validate_yes_no_input "Is this correct? (y/n): ")

        if [[ "$confirm" == "y" ]]; then
            break
        fi
    done
}

# Function to get and select Portworx pod, providing option to customer to select a PX pod
select_portworx_pod() {
    echo ""
    print_info "Fetching Portworx pods from namespace '$PX_NAMESPACE'..."

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    # Get pods with label name=portworx
    local exit_code
    pods_output=$($cmd -n "$PX_NAMESPACE" get pods -l name=portworx --no-headers 2>&1) || exit_code=$?

    if [[ ${exit_code:-0} -ne 0 ]]; then
        print_error "Failed to get Portworx pods. Please check your namespace and permissions."
        echo "$pods_output"
        exit 1
    fi
    
    if [[ -z "$pods_output" ]]; then
        print_error "No Portworx pods found in namespace '$PX_NAMESPACE' with label 'name=portworx'."
        exit 1
    fi
    
    # Display the pods
    echo ""
    echo "Available Portworx pods:"
    echo "------------------------"
    $cmd -n "$PX_NAMESPACE" get pods -l name=portworx
    echo ""
    
    # Get a random pod name from the list 
    local pod_list
    # Filter for pods that are in 1/1 state
    pod_list=$(echo "$pods_output" | grep "1/1" | awk '{print $1}')

    if [[ -z "$pod_list" ]]; then
        print_error "No Portworx pods found in 1/1 state in namespace '$PX_NAMESPACE'."
        print_error "Please ensure at least one Portworx pod is fully ready (1/1) before running this health check."
        exit 1
    fi

    local pod_count
    pod_count=$(echo "$pod_list" | wc -l | tr -d ' ')

    if command -v shuf &> /dev/null; then
        # Use shuf if available (Linux)
        random_pod=$(echo "$pod_list" | shuf -n 1)
    elif sort --random-sort /dev/null 2>/dev/null; then
        # Use sort -R if available (macOS, GNU coreutils)
        random_pod=$(echo "$pod_list" | sort -R | head -n 1)
    else
        # Fallback: use awk with a random seed
        random_pod=$(echo "$pod_list" | awk -v seed="$RANDOM" 'BEGIN{srand(seed)} {a[NR]=$0} END{print a[int(rand()*NR)+1]}')
    fi

    print_info "Randomly selected pod: $random_pod"
    echo ""

    local use_random
    use_random=$(validate_yes_no_input "Use this pod for running pxctl commands? (y/n): ")

    if [[ "$use_random" == "y" ]]; then
        SELECTED_POD="$random_pod"
        echo ""
        print_info "Using pod: $SELECTED_POD"
    else
        read -p "Enter the pod name you want to use: " custom_pod
        SELECTED_POD="$custom_pod"
        echo ""
        print_info "Using pod: $SELECTED_POD"
    fi
}

# Function to detect and setup PX-Security token
detect_px_security() {
    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    # Check if PX-Security is enabled by querying the StorageCluster
    PX_SECURITY_ENABLED=$($cmd -n "$PX_NAMESPACE" get stc -o=jsonpath='{.items[*].spec.security.enabled}' 2>/dev/null) || true

    if [[ "$PX_SECURITY_ENABLED" == "true" ]]; then
        # Get the auth token from px-admin-token secret
        PX_AUTH_TOKEN=$($cmd -n "$PX_NAMESPACE" get secret px-admin-token --template='{{index .data "auth-token" | base64decode}}' 2>/dev/null) || true

        if [[ -n "$PX_AUTH_TOKEN" ]]; then
            echo ""
            print_info "PX-Security is enabled. Token setup successful."
        else
            echo ""
            print_error "PX-Security is enabled but failed to setup token."
            print_error "Please ensure the 'px-admin-token' secret exists in namespace '$PX_NAMESPACE'."
            exit 1
        fi
    else
        PX_SECURITY_ENABLED="false"
    fi
}

# Function to display customer recommendations
customer_recommendations() {
    cat << 'EOF'

=========================================
  Customer Recommendations
=========================================

1. Upgrade Order:
   Please upgrade Portworx (Operator and Portworx Enterprise) before OS/Kubernetes upgrade.
   Please upgrade Operator before Portworx Enterprise upgrade.

2. Supported Kernels:
   Please review the supported kernels in the target Portworx release.
   Please ensure to only upgrade to supported kernel(s) e.g. :
   https://docs.portworx.com/portworx-enterprise/support-matrix/supported-kernels

3. Air-Gapped Environments:
   For air-gapped installations, please ensure all required images are pushed to your private registry:
   https://docs.portworx.com/portworx-enterprise/platform/upgrade/airgap-upgrade

=========================================

EOF
}

# Function to run pxctl status
pxctl_status() {
    echo ""
    echo "========================================="
    echo "               pxctl status"
    echo "========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    # Capture the output - use security token if PX-Security is enabled
    local output
    local exit_code
    if [[ "$PX_SECURITY_ENABLED" == "true" ]] && [[ -n "$PX_AUTH_TOKEN" ]]; then
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- bash -c "export PXCTL_AUTH_TOKEN=$PX_AUTH_TOKEN && /opt/pwx/bin/pxctl status" 2>&1) || exit_code=$?
    else
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- /opt/pwx/bin/pxctl status 2>&1) || exit_code=$?
    fi
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]]; then
        print_error "pxctl status command failed."
        echo "$output"
        exit 1
    fi

    # Check if output contains expected strings
    # The token should be all set by this point but if common strings are not showing up than there is a issue
    # if so, exiting the script
    if ! echo "$output" | grep -q "Cluster UUID" || ! echo "$output" | grep -q "Total Nodes"; then
        echo ""
        echo "The output 'pxctl status' does not contain expected information (Cluster UUID or Total Nodes)."
        echo "This may indicate that PX-Security is enabled and authentication is required."
        echo "If PX-Security is enabled, you need to configure a token on the Portworx pod."
        echo "Please refer to the documentation:"
        echo "  https://docs.portworx.com/portworx-enterprise/platform/secure/px-security"
        echo ""
        echo "Exiting script. Please configure authentication token if required."
        exit 1
    fi

    print_info "pxctl status command completed successfully."

    # Extract and display cluster version
    # Version appears in the node listing, typically after "Up" or "Up (This node)"
    # Format: ... Online  Up  3.5.2.0-86e5708  6.5.0-27-generic ...
    # Node lines may have leading whitespace
    PX_CLUSTER_VERSION=$(echo "$output" | grep -E "^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]+" | head -1)
    if [[ -n "$PX_CLUSTER_VERSION" ]]; then
        print_info "Cluster Version: $PX_CLUSTER_VERSION"
    fi
    echo ""

    # Check for duplicate IP addresses
    local duplicate_ips
    duplicate_ips=$(echo "$output" | awk 'NF > 5 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1}' | sort | uniq -d)

    if [[ -n "$duplicate_ips" ]]; then
        echo ""
        print_warning "Found duplicate IP addresses (possible ghost entries):"
        echo "========================================="
        while IFS= read -r ip; do
            echo "IP: $ip"
            echo "$output" | awk -v ip="$ip" '$1 == ip {
                status = "Unknown"
                for (i=1; i<=NF; i++) {
                    if ($i ~ /Online/ || $i ~ /Offline/) {
                        status = $i
                        break
                    }
                }
                print "  UUID: " $2 "  Hostname: " $3 "  Status: " status
            }'
        done <<< "$duplicate_ips"
        echo "========================================="
        echo ""
    fi

    # Check for nodes that are not Online
    local offline_nodes
    offline_nodes=$(echo "$output" | awk 'NF > 5 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $0 !~ /Online/ {print $0}')

    if [[ -n "$offline_nodes" ]]; then
        echo ""
        print_warning "Found node(s) that are NOT Online:"
        while IFS= read -r node_line; do
            print_warning "  $node_line"
        done <<< "$offline_nodes"
        echo ""
    else
        echo ""
        print_info "All nodes are Online"
    fi

    # Check for PX-StoreV2
    if echo "$output" | grep -q "PX-StoreV2"; then
        print_info "PX-StoreV2 is enabled on this cluster."
    else
        print_info "This is a PX-StoreV1 cluster."
    fi

    # Check for nodes with StorageDown status
    local storagedown_nodes
    storagedown_nodes=$(echo "$output" | grep -i "StorageDown") || true

    if [[ -n "$storagedown_nodes" ]]; then
        echo ""
        print_warning "Found node(s) with StorageDown status:"
        while IFS= read -r storagedown_line; do
            print_warning "  $storagedown_line"
        done <<< "$storagedown_nodes"
        echo ""
    fi

    # Summary
    if [[ -z "$duplicate_ips" ]] && [[ -z "$offline_nodes" ]] && [[ -z "$storagedown_nodes" ]]; then
        echo ""
        print_info "pxctl status. All checks passed! No issues found."
    fi
}

# Global variable for px_gather_logs script path
PX_GATHER_LOGS_SCRIPT="/tmp/px_gather_logs.sh"
PX_GATHER_LOGS_URL="https://raw.githubusercontent.com/portworx/support-external-scripts/refs/heads/main/px_gather_logs/px_gather_logs.sh"

# Function to download px_gather_logs.sh script
download_px_gather_logs_script() {
    echo ""
    echo "========================================="
    echo "  Checking for px_gather_logs.sh script"
    echo "========================================="
    echo ""

    # Check if script already exists in /tmp
    if [[ -f "$PX_GATHER_LOGS_SCRIPT" ]]; then
        print_info "px_gather_logs.sh script already exists at $PX_GATHER_LOGS_SCRIPT"
        return 0
    fi

    print_info "px_gather_logs.sh script not found in /tmp. Attempting to download..."
    echo ""

    # Check if curl is available
    if ! command -v curl &> /dev/null; then
        # Try wget as fallback
        if command -v wget &> /dev/null; then
            print_info "Using wget to download the script..."
            if wget -q "$PX_GATHER_LOGS_URL" -O "$PX_GATHER_LOGS_SCRIPT" 2>/dev/null; then
                chmod +x "$PX_GATHER_LOGS_SCRIPT"
                print_info "Successfully downloaded px_gather_logs.sh to $PX_GATHER_LOGS_SCRIPT"
                return 0
            fi
        fi

        print_error "Neither curl nor wget is available for download."
        echo ""
        print_warning "This appears to be an air-gapped environment or download tools are not installed."
        echo ""
        echo "Please manually download the script and place it in /tmp:"
        echo ""
        echo "  1. Download from: $PX_GATHER_LOGS_URL"
        echo "  2. Save as: $PX_GATHER_LOGS_SCRIPT"
        echo "  3. Run this health check script again"
        echo ""
        print_error "Exiting. Please download the script manually and retry."
        exit 1
    fi

    # Try to download using curl
    print_info "Using curl to download the script..."
    if curl -sfL "$PX_GATHER_LOGS_URL" -o "$PX_GATHER_LOGS_SCRIPT" --connect-timeout 10 --max-time 30 2>/dev/null; then
        chmod +x "$PX_GATHER_LOGS_SCRIPT"
        print_info "Successfully downloaded px_gather_logs.sh to $PX_GATHER_LOGS_SCRIPT"
        return 0
    fi

    # Download failed - likely air-gapped environment
    print_error "Failed to download px_gather_logs.sh script."
    echo ""
    print_warning "This may be an air-gapped environment or there is no internet connectivity."
    echo ""
    echo "Please manually download the script and place it in /tmp:"
    echo ""
    echo "  1. Download from: $PX_GATHER_LOGS_URL"
    echo "  2. Save as: $PX_GATHER_LOGS_SCRIPT"
    echo "  3. Run this health check script again"
    echo ""
    print_error "Exiting. Please download the script manually and retry."
    exit 1
}

# Function to create cluster data bundle backup
cluster_data_bundle_backup() {
    echo ""
    echo "========================================="
    echo "  Cluster Data Bundle Backup"
    echo "========================================="
    echo ""

    print_info "Creating a cluster data bundle backup..."
    print_info "Reference: https://github.com/portworx/support-external-scripts/tree/main/px_gather_logs"
    echo ""

    # Verify script exists (should have been downloaded at script start)
    if [[ ! -f "$PX_GATHER_LOGS_SCRIPT" ]]; then
        print_error "px_gather_logs.sh script not found at $PX_GATHER_LOGS_SCRIPT"
        print_error "This should not happen. Please run the health check script again."
        return
    fi

    print_info "Using px_gather_logs.sh from: $PX_GATHER_LOGS_SCRIPT"
    echo ""

    # Set kubeconfig if specified
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        print_info "Setting KUBECONFIG environment variable to: $KUBECONFIG_PATH"
        export KUBECONFIG="$KUBECONFIG_PATH"
    fi

    print_info "Executing cluster data bundle collection..."
    print_info "Command: bash $PX_GATHER_LOGS_SCRIPT -n $PX_NAMESPACE -c $CLI_TOOL -o PX"
    echo ""
    echo "========================================="

    # Execute the script
    bash "$PX_GATHER_LOGS_SCRIPT" -n "$PX_NAMESPACE" -c "$CLI_TOOL" -o PX
    local exit_code=$?

    echo "========================================="
    echo ""

    if [[ $exit_code -eq 0 ]]; then
        print_info "Cluster data bundle backup completed successfully!"
        print_info "The bundle is saved in /tmp/ folder. Please keep it safe for reference."
    else
        print_warning "Cluster data bundle backup may have encountered issues."
        print_warning "Please check the output above for details."
    fi
}

kvdb_members_status() {
    echo ""
    echo "========================================="
    echo "      pxctl sv kvdb members"
    echo "========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    # Capture the output - use security token if PX-Security is enabled
    local output
    local exit_code
    if [[ "$PX_SECURITY_ENABLED" == "true" ]] && [[ -n "$PX_AUTH_TOKEN" ]]; then
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- bash -c "export PXCTL_AUTH_TOKEN=$PX_AUTH_TOKEN && /opt/pwx/bin/pxctl sv kvdb members" 2>&1) || exit_code=$?
    else
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- /opt/pwx/bin/pxctl sv kvdb members 2>&1) || exit_code=$?
    fi
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]]; then
        print_error "pxctl sv kvdb members command failed."
        echo "$output"
        return
    fi

    print_info "pxctl sv kvdb members command completed successfully."
    echo ""

    # Display the output
    echo "$output"
    echo ""

    # Count KVDB members (lines with URLs, excluding header)
    # Use https?:// to match both http:// and https://
    local member_count
    member_count=$(echo "$output" | grep -cE "https?://" || true)

    if [[ "$member_count" -eq 3 ]]; then
        print_info "KVDB member count: $member_count (OK - expected 3 members)"
    else
        print_warning "KVDB member count: $member_count (Expected 3 members)"
    fi

    # Count leaders
    local leader_count
    leader_count=$(echo "$output" | grep -E "https?://" | awk '{
        for(i=1; i<=NF; i++) {
            if ($i == "true" || $i == "false") {
                print $i
                break
            }
        }
    }' | grep -c "true" || true)

    if [[ "$leader_count" -eq 1 ]]; then
        print_info "KVDB leader count: $leader_count (OK - expected 1 leader)"
    elif [[ "$leader_count" -eq 0 ]]; then
        print_error "KVDB leader count: $leader_count (No leader found - this is a critical issue!)"
    else
        print_warning "KVDB leader count: $leader_count (Expected only 1 leader)"
    fi

    # Check for unhealthy members
    local unhealthy_count
    unhealthy_count=$(echo "$output" | grep -E "https?://" | awk '{
        count = 0
        for(i=1; i<=NF; i++) {
            if ($i == "true" || $i == "false") {
                count++
                if (count == 2) {
                    print $i
                    break
                }
            }
        }
    }' | grep -c "false" || true)

    if [[ "$unhealthy_count" -gt 0 ]]; then
        print_error "Found $unhealthy_count unhealthy KVDB member(s):"
        local unhealthy_members
        unhealthy_members=$(echo "$output" | grep -E "https?://" | awk '{
            count = 0
            for(i=1; i<=NF; i++) {
                if ($i == "true" || $i == "false") {
                    count++
                    if (count == 2 && $i == "false") {
                        print $0
                        break
                    }
                }
            }
        }')
        while IFS= read -r member_line; do
            print_error "  $member_line"
        done <<< "$unhealthy_members"
    else
        print_info "All KVDB members are healthy."
    fi
}

repl_one_volumes() {
    echo ""
    echo "========================================="
    echo "  pxctl volume list (HA 1 volumes check) "
    echo "========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    # Inner script to be executed inside the pod
    # This script lists volumes, checks for HA=1, and then inspects them to verify backend labels
    local inner_script='
    # Get volumes with HA=1 (5th column)
    # columns: ID, NAME, SIZE, HA, SHARED, ...
    # We grep specifically for HA=1
    for vol_id in $(/opt/pwx/bin/pxctl volume list 2>/dev/null | awk "NR>1 && NF>=5 && \$5==\"1\" {print \$1}"); do
        inspect=$(/opt/pwx/bin/pxctl volume inspect "$vol_id" 2>/dev/null)
        
        # Check if the volume is FlashArray or FlashBlade
        if echo "$inspect" | grep -q "Labels.*backend=FlashArray"; then
            continue
        fi
        if echo "$inspect" | grep -q "Labels.*backend=FlashBlade"; then
            continue
        fi

        # If we are here, it is a standard HA=1 volume that should be flagged
        # Extract name - format is "        Name                     :  ha1-generic-1"
        # We need to get everything after the colon
        name=$(echo "$inspect" | awk -F: "/^[[:space:]]*Name[[:space:]]*:/{gsub(/^[[:space:]]+/,\"\",\$2);print \$2;exit}")
        echo "WARN_HA1|${vol_id}|${name}"
    done
    '

    # Capture the output - use security token if PX-Security is enabled
    local output
    local exit_code
    if [[ "$PX_SECURITY_ENABLED" == "true" ]] && [[ -n "$PX_AUTH_TOKEN" ]]; then
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- bash -c "export PXCTL_AUTH_TOKEN=$PX_AUTH_TOKEN; $inner_script" 2>&1) || exit_code=$?
    else
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- bash -c "$inner_script" 2>&1) || exit_code=$?
    fi
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]]; then
        print_error "pxctl volume list/inspect command failed."
        echo "$output"
        return
    fi
    
    print_info "pxctl volume list command completed successfully."
    echo ""

    # Parse output
    local ha_one_volumes
    ha_one_volumes=$(echo "$output" | grep "^WARN_HA1|" || true)

    if [[ -n "$ha_one_volumes" ]]; then
        print_warning "Found volumes with Replication Factor (HA) = 1:"
        while IFS='|' read -r prefix vol_id vol_name; do
            print_warning "  - Volume: $vol_name (ID: $vol_id)"
        done <<< "$ha_one_volumes"
        echo ""
        print_warning "RECOMMENDATION: Consider increasing the replication factor to at least 2 before performing an upgrade."
        print_warning "Use 'pxctl volume ha-update --repl 2 <volume_id>' to increase replication."
    else
        print_info "No problematic Replication 1 volumes found (FlashArray/FlashBlade volumes are excluded)."
    fi
}

volume_not_up() {
    echo ""
    echo "=========================================="
    echo "  pxctl volume list (volumes NOT up check)"
    echo "=========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    # Capture the output - use security token if PX-Security is enabled
    local output
    local exit_code
    if [[ "$PX_SECURITY_ENABLED" == "true" ]] && [[ -n "$PX_AUTH_TOKEN" ]]; then
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- bash -c "export PXCTL_AUTH_TOKEN=$PX_AUTH_TOKEN && /opt/pwx/bin/pxctl volume list" 2>&1) || exit_code=$?
    else
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- /opt/pwx/bin/pxctl volume list 2>&1) || exit_code=$?
    fi
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]]; then
        print_error "pxctl volume list command failed."
        echo "$output"
        return
    fi

    local not_up_volumes
    not_up_volumes=$(echo "$output" | awk '
        NR == 1 { next }  # skip header
        NF >= 11 {
            id = $1
            name = $2

            # Reconstruct STATUS field from column 10 to the penultimate column
            status = ""
            for (i = 10; i <= NF-1; i++) {
                if (status == "") {
                    status = $i
                } else {
                    status = status " " $i
                }
            }

            # Normalize to lowercase for comparison
            status_lc = tolower(status)

            # If STATUS does not contain the standalone word "up", treat volume as NOT up
            if (status_lc !~ /(^|[[:space:]])up($|[[:space:]])/) {
                printf "NOT_UP|%s|%s|%s\n", id, name, status
            }
        }
    ')

    if [[ -n "$not_up_volumes" ]]; then
        print_error "Found volumes that are NOT in 'up' state:"
        echo ""
        while IFS='|' read -r prefix vol_id vol_name vol_status; do
            print_error "CRITICAL: Volume ${vol_name} (ID: ${vol_id}) is NOT up. Status: ${vol_status}"
        done <<< "$not_up_volumes"
        echo ""
        print_error "RECOMMENDATION: Investigate these volumes and ensure they are up before performing an upgrade."
        echo "========================================="
    else
        print_info "All volumes are in an 'up' state."
    fi
}

volume_resync_status_check() {
    echo ""
    echo "========================================="
    echo "    PX Volume Resync Status Check.       "
    echo "========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    print_info "Checking volumes for Resync status..."

    local inner_script='
for vol_id in $(/opt/pwx/bin/pxctl volume list 2>/dev/null | awk "NR>1 && NF>0 {print \$1}"); do
    inspect=$(/opt/pwx/bin/pxctl volume inspect "$vol_id" 2>/dev/null)
    if echo "$inspect" | grep -q "Replication Status.*:.*Resync"; then
        # Extract name and status - format is "        Name                     :  volume-name"
        name=$(echo "$inspect" | awk -F: "/^[[:space:]]*Name[[:space:]]*:/{gsub(/^[[:space:]]+/,\"\",\$2);print \$2;exit}")
        status=$(echo "$inspect" | awk -F: "/^[[:space:]]*Status[[:space:]]*:/{gsub(/^[[:space:]]+/,\"\",\$2);print \$2;exit}")
        echo "RESYNC|${vol_id}|${name}|${status}"
    fi
done
'

    local output
    if [[ "$PX_SECURITY_ENABLED" == "true" ]] && [[ -n "$PX_AUTH_TOKEN" ]]; then
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- bash -c "export PXCTL_AUTH_TOKEN=$PX_AUTH_TOKEN; $inner_script" 2>&1)
    else
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- bash -c "$inner_script" 2>&1)
    fi

    if [[ $? -ne 0 ]]; then
        print_error "Failed to check volume resync status."
        echo "$output"
        return
    fi

    # Check if any RESYNC lines were found
    local resync_lines
    resync_lines=$(echo "$output" | grep "^RESYNC|" || true)

    if [[ -n "$resync_lines" ]]; then
        print_warning "Found volumes with Replication Status: Resync"
        while IFS='|' read -r prefix vol_id vol_name vol_status; do
            print_warning "  Volume: ${vol_name} (ID: ${vol_id}) | Status: ${vol_status}"
        done <<< "$resync_lines"
        echo ""
        print_warning "RECOMMENDATION: Wait for resync to complete before performing an upgrade."
    else
        print_info "No volumes in Resync state."
    fi
}

px_alerts_show() {
    echo ""
    echo "================================================"
    echo "  pxctl alerts show (WARNING/ALARM alerts check)"
    echo "================================================"
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    # Capture the output - use security token if PX-Security is enabled
    local output
    if [[ "$PX_SECURITY_ENABLED" == "true" ]] && [[ -n "$PX_AUTH_TOKEN" ]]; then
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- bash -c "export PXCTL_AUTH_TOKEN=$PX_AUTH_TOKEN && /opt/pwx/bin/pxctl alerts show" 2>&1)
    else
        output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- /opt/pwx/bin/pxctl alerts show 2>&1)
    fi
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        print_error "pxctl alerts show command failed."
        echo "$output"
        return
    fi

    print_info "pxctl alerts show command completed successfully."
    echo ""

    # Filter alerts to exclude NOTIFY severity
    local critical_alerts
    critical_alerts=$(echo "$output" | awk '
        NR == 1 { next }  # Skip header line
        NF >= 4 {
            severity = $4
            if (severity == "ALARM" || severity == "WARNING") {
                print $0
            }
        }
    ')

    if [[ -n "$critical_alerts" ]]; then
        # Count alarms and warnings
        local alarm_count warning_count
        alarm_count=$(echo "$critical_alerts" | grep -c "ALARM" || true)
        warning_count=$(echo "$critical_alerts" | grep -c "WARNING" || true)

        print_warning "Found $alarm_count ALARM(s) and $warning_count WARNING(s) on the cluster:"
        # Print filtered alerts with key columns, prefixed with [WARNING]
        local formatted_alerts
        formatted_alerts=$(echo "$critical_alerts" | awk '{
            type = $1
            id = $2
            resource = $3
            severity = $4
            # Description starts from field 8 onwards (after Count, LastSeen, FirstSeen)
            desc = ""
            for (i = 8; i <= NF; i++) {
                desc = desc " " $i
            }
            printf "  %s | %s | %s | %s\n", type, resource, severity, desc
        }')
        while IFS= read -r alert_line; do
            print_warning "$alert_line"
        done <<< "$formatted_alerts"
        echo ""
        print_warning "RECOMMENDATION: Review and address these alerts before performing an upgrade."
        print_warning "Use 'pxctl alerts purge' to clear all alerts after resolving the issues."
        echo "========================================="
    else
        print_info "No WARNING or ALARM alerts found on the cluster."
    fi
}

check_portworx_pdbs() {
    echo ""
    echo "=========================================="
    echo "  Checking Portworx PodDisruptionBudgets"
    echo "=========================================="
    echo ""

    local pdbs=("px-kvdb" "px-storage")
    local failed=0
    local found_any=false

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    for pdb in "${pdbs[@]}"; do
        # check if pdb exists
        if $cmd get pdb "$pdb" -n "$PX_NAMESPACE" &> /dev/null; then
            found_any=true
            disruptions=$($cmd get pdb "$pdb" -n "$PX_NAMESPACE" \
              -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)

            if [[ -z "$disruptions" ]]; then
              print_error "PDB $pdb found but status.disruptionsAllowed unavailable"
              failed=1
            elif [[ "$disruptions" -lt 1 ]]; then
              print_error "PDB $pdb allows no disruptions (disruptionsAllowed=$disruptions)"
              print_error "      Pod eviction/restart may be blocked by PDB"
              failed=1
            else
              print_info "PDB $pdb allows $disruptions disruption(s)"
            fi
        fi
    done

    if [[ "$found_any" == "false" ]]; then
        print_info "No Portworx PDBs (px-kvdb, px-storage) found. Skipping check."
    fi
}

check_update_strategy() {
    echo ""
    echo "=========================================="
    echo "  Checking StorageCluster Update Strategy"
    echo "=========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    # Check update strategy
    print_info "Checking StorageCluster update strategy..."
    
    # We use jsonpath to get the updateStrategy type
    local strategy_type
    strategy_type=$($cmd get stc -n "$PX_NAMESPACE" -o jsonpath='{.items[*].spec.updateStrategy.type}' 2>/dev/null)

    if [[ -z "$strategy_type" ]]; then
        print_warning "Could not determine StorageCluster update strategy or no StorageCluster found."
        print_warning "Please ensure a StorageCluster resource exists in namespace '$PX_NAMESPACE'."
    elif [[ "$strategy_type" == "RollingUpdate" ]]; then
        print_info "StorageCluster update strategy is: $strategy_type (OK)"
    else
        print_warning "StorageCluster update strategy is: '$strategy_type'"
        print_warning "Expected: 'RollingUpdate'"
        print_warning "Please check your StorageCluster configuration."
    fi
}

operator_managed_pods() {
    echo ""
    echo "=========================================="
    echo "  Checking Operator Managed Pods"
    echo "=========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    print_info "Checking status of pods managed by Portworx operator..."

    local unhealthy_pods
    unhealthy_pods=$($cmd -n "$PX_NAMESPACE" get pods \
        -l operator.libopenstorage.org/managed-by=portworx \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .status.containerStatuses[*]}{.ready}{" "}{end}{"\n"}{end}' 2>/dev/null \
        | awk -F'|' '$2 != "Running" || $3 ~ /false/ { print $1 }' \
        | sort -u)

    if [[ -n "$unhealthy_pods" ]]; then
        print_error "Found Portworx operator managed pods that are not healthy (Not Running or Containers not Ready):"
        echo "$unhealthy_pods" | while IFS= read -r pod; do
            print_error "  $pod"
        done
        echo ""
    else
        print_info "All operator managed pods are in Running state and ready."
    fi
}

manual_image_check() {
    echo ""
    echo "=========================================="
    echo "  Checking Manual Image References"
    echo "=========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    # Query for images
    print_info "Checking StorageCluster for manually specified Stork/Autopilot images..."
    
    local stork_image
    stork_image=$($cmd get stc -n "$PX_NAMESPACE" -o jsonpath='{.items[*].spec.stork.image}' 2>/dev/null)
    
    local autopilot_image
    autopilot_image=$($cmd get stc -n "$PX_NAMESPACE" -o jsonpath='{.items[*].spec.autopilot.image}' 2>/dev/null)

    if [[ -n "$stork_image" ]] || [[ -n "$autopilot_image" ]]; then
        echo ""
        print_warning "The StorageCluster (STC) contains manually specified Stork and/or Autopilot image references that require updating during the upgrade process. Please ensure these images are modified accordingly. If you're utilizing the px-versions ConfigMap, verify and update the image versions there as well."
        echo ""
        echo "For additional guidance, please refer to the following documentation:"
        echo ""
        echo "https://docs.portworx.com/portworx-enterprise/operations/scale-portworx-cluster/autopilot#customize-autopilot"
        echo "https://docs.portworx.com/portworx-enterprise/reference/crd/storage-cluster"
        echo "https://docs.portworx.com/portworx-enterprise/platform/upgrade/airgap-upgrade"
        echo ""
        
        if [[ -n "$stork_image" ]]; then
            echo "  Found Stork image: $stork_image"
        fi
        if [[ -n "$autopilot_image" ]]; then
            echo "  Found Autopilot image: $autopilot_image"
        fi
    else
        print_info "No manually specified Stork or Autopilot images found in StorageCluster."
    fi

    # Check for px-versions ConfigMap
    if $cmd get cm px-versions -n "$PX_NAMESPACE" &> /dev/null; then
        echo ""
        print_info "Found 'px-versions' ConfigMap in namespace '$PX_NAMESPACE'."
    fi
}

check_flasharray() {
    echo ""
    echo "=========================================="
    echo "  Checking FlashArray Connectivity"
    echo "=========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    # Step 1: Check if px-pure-secret exists
    print_info "Checking for px-pure-secret..."
    if ! $cmd get secret px-pure-secret -n "$PX_NAMESPACE" &> /dev/null; then
        print_info "px-pure-secret not found in namespace '$PX_NAMESPACE'. Skipping FlashArray check."
        return
    fi
    print_info "px-pure-secret found."

    # Step 2: Check if PURE_FLASHARRAY_SAN_TYPE is configured in StorageCluster
    print_info "Checking for PURE_FLASHARRAY_SAN_TYPE in StorageCluster..."
    local fa_san_type
    fa_san_type=$($cmd -n "$PX_NAMESPACE" get stc -o yaml 2>/dev/null | grep "name: PURE_FLASHARRAY_SAN_TYPE" || true)
    if [[ -z "$fa_san_type" ]]; then
        print_info "PURE_FLASHARRAY_SAN_TYPE not found in StorageCluster. Skipping FlashArray check."
        return
    fi
    print_info "PURE_FLASHARRAY_SAN_TYPE is configured in StorageCluster."

    # Step 3: Get and decode the px-pure-secret
    print_info "Retrieving and decoding px-pure-secret..."
    local pure_json_b64
    pure_json_b64=$($cmd get secret px-pure-secret -n "$PX_NAMESPACE" -o jsonpath='{.data.pure\.json}' 2>/dev/null)
    if [[ -z "$pure_json_b64" ]]; then
        print_error "Failed to retrieve pure.json from px-pure-secret."
        return
    fi

    local pure_json
    pure_json=$(echo "$pure_json_b64" | base64 -d 2>/dev/null)
    if [[ -z "$pure_json" ]]; then
        print_error "Failed to decode pure.json from px-pure-secret."
        return
    fi

    # Step 4: Parse FlashArrays from the JSON

    local fa_count=0
    local fa_endpoints=()
    local fa_tokens=()


    local fa_section
    fa_section=$(echo "$pure_json" | tr -d '\n' | sed -n 's/.*"FlashArrays"[[:space:]]*:[[:space:]]*\(\[[^]]*\]\).*/\1/p')

    if [[ -z "$fa_section" ]]; then
        print_info "No FlashArrays section found in px-pure-secret. Skipping FlashArray check."
        return
    fi

    # Parse the FlashArrays section - extract all MgmtEndPoint and APIToken values
    while IFS= read -r line; do
        [[ -n "$line" ]] && fa_endpoints+=("$line")
    done < <(echo "$fa_section" | grep -o '"MgmtEndPoint"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:.*"\([^"]*\)"/\1/')

    while IFS= read -r line; do
        [[ -n "$line" ]] && fa_tokens+=("$line")
    done < <(echo "$fa_section" | grep -o '"APIToken"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:.*"\([^"]*\)"/\1/')

    fa_count=${#fa_endpoints[@]}

    if [[ $fa_count -eq 0 ]]; then
        print_info "No FlashArrays found in px-pure-secret."
        return
    fi

    print_info "Found $fa_count FlashArray(s) in px-pure-secret."

    # Check if FlashBlades are also configured
    local fb_section
    fb_section=$(echo "$pure_json" | tr -d '\n' | sed -n 's/.*"FlashBlades"[[:space:]]*:[[:space:]]*\(\[[^]]*\]\).*/\1/p')
    if [[ -n "$fb_section" ]]; then
        local fb_count
        fb_count=$(echo "$fb_section" | grep -o '"MgmtEndPoint"' | wc -l | tr -d ' ')
        if [[ "$fb_count" -gt 0 ]]; then
            print_info "Detected $fb_count FlashBlade(s) in px-pure-secret."
            print_info "Please check FlashBlade space and performance manually."
        fi
    fi
    echo ""

    # Step 5: Test connectivity to each FlashArray
    for i in "${!fa_endpoints[@]}"; do
        local endpoint="${fa_endpoints[$i]}"
        local api_token="${fa_tokens[$i]}"

        echo "  FlashArray $((i+1)): $endpoint"
        echo "  ----------------------------------------"

        if [[ -z "$endpoint" ]] || [[ -z "$api_token" ]]; then
            print_error "  Missing endpoint or API token for FlashArray $((i+1))"
            continue
        fi

        # Step 5a: Login to get x-auth-token
        local login_response
        local http_code
        local x_auth_token
        local curl_exit_code

        # Use curl to login and capture both response and headers
        # --connect-timeout 30: Wait up to 30 seconds for connection
        # --max-time 60: Total operation timeout of 60 seconds
        login_response=$(curl -s -k --connect-timeout 30 --max-time 60 -w "\n%{http_code}" -X POST \
            "https://${endpoint}/api/2.2/login" \
            -H "api-token: ${api_token}" 2>/dev/null)
        curl_exit_code=$?

        # Check if curl itself failed (network error, timeout, etc.)
        if [[ $curl_exit_code -ne 0 ]]; then
            print_error "  Unable to connect to FlashArray $endpoint (curl exit code: $curl_exit_code)"
            print_error "  Please check FlashArray connectivity and health manually."
            continue
        fi

        http_code=$(echo "$login_response" | tail -n1)
        local login_body
        login_body=$(echo "$login_response" | sed '$d')

        if [[ -z "$http_code" ]] || [[ "$http_code" == "000" ]]; then
            print_error "  Connection to FlashArray $endpoint failed - no response received."
            print_error "  Please check FlashArray connectivity and health manually."
            continue
        fi

        if [[ "$http_code" != "200" ]]; then
            print_error "  Login failed to FlashArray $endpoint (HTTP $http_code)"
            print_error "  Please verify the API token is valid and the FlashArray is reachable."
            continue
        fi

        # Get x-auth-token from a separate curl call with headers
        x_auth_token=$(curl -s -k --connect-timeout 30 --max-time 60 -D - -X POST \
            "https://${endpoint}/api/2.2/login" \
            -H "api-token: ${api_token}" 2>/dev/null | grep -i "x-auth-token:" | awk '{print $2}' | tr -d '\r')

        if [[ -z "$x_auth_token" ]]; then
            print_error "  Failed to obtain x-auth-token from FlashArray $endpoint"
            print_error "  Please check FlashArray connectivity and health manually."
            continue
        fi

        print_info "  Successfully authenticated to FlashArray $endpoint"

        #API calls for FA is here:
        #  https://code.purestorage.com/swagger/redoc/fa2.35-api-reference.html#tag/Arrays/paths/~1api~12.35~1arrays~1ntp-test/get
        
        # Step 5b: Get space/capacity information
        local space_response
        space_response=$(curl -s -k --connect-timeout 30 --max-time 60 \
            -H "x-auth-token: ${x_auth_token}" \
            "https://${endpoint}/api/2.35/arrays/space" 2>/dev/null)
        curl_exit_code=$?

        if [[ $curl_exit_code -ne 0 ]] || [[ -z "$space_response" ]]; then
            print_error "  Failed to retrieve space information from FlashArray $endpoint"
            print_error "  Please check FlashArray connectivity and health manually."
            continue
        fi

        # Parse the space response using awk
        # JSON format: {"items":[{"name":"array-name","space":{"data_reduction":X,"total_used":Y},"capacity":Z}]}
        local fa_name
        local fa_capacity
        local fa_total_used
        local fa_data_reduction

        # Extract array name - it's the first "name" after "items"
        # Format: "items":[{"name":"ph531-f41"
        fa_name=$(echo "$space_response" | sed 's/.*"items":\[{"name":"\([^"]*\)".*/\1/')

        # Extract capacity - it's at the top level of the items object
        # Format: "capacity":272239349989376
        fa_capacity=$(echo "$space_response" | sed 's/.*"capacity":\([0-9]*\).*/\1/')

        # Extract total_used from the space object
        # Format: "total_used":21608808058034
        fa_total_used=$(echo "$space_response" | sed 's/.*"total_used":\([0-9]*\).*/\1/')

        # Extract data_reduction from the space object
        # Format: "data_reduction":3.650336341288404
        fa_data_reduction=$(echo "$space_response" | sed 's/.*"data_reduction":\([0-9.]*\).*/\1/')

        # Convert bytes to human readable format
        local capacity_tb=""
        local used_tb=""
        local used_percent=""

        if [[ -n "$fa_capacity" ]] && [[ "$fa_capacity" -gt 0 ]]; then
            capacity_tb=$(awk "BEGIN {printf \"%.2f\", $fa_capacity / 1099511627776}")
        fi

        if [[ -n "$fa_total_used" ]] && [[ "$fa_total_used" -gt 0 ]]; then
            used_tb=$(awk "BEGIN {printf \"%.2f\", $fa_total_used / 1099511627776}")
        fi

        if [[ -n "$fa_capacity" ]] && [[ -n "$fa_total_used" ]] && [[ "$fa_capacity" -gt 0 ]]; then
            used_percent=$(awk "BEGIN {printf \"%.1f\", ($fa_total_used / $fa_capacity) * 100}")
        fi

        # Display the information
        echo ""
        print_info "  Array Name: ${fa_name:-N/A}"
        print_info "  Capacity: ${capacity_tb:-N/A} TB"
        print_info "  Used: ${used_tb:-N/A} TB (${used_percent:-N/A}%)"
        print_info "  Data Reduction: ${fa_data_reduction:-N/A}x"

        # Check if usage is above 80% and warn
        if [[ -n "$used_percent" ]]; then
            local usage_int
            usage_int=$(echo "$used_percent" | awk '{printf "%d", $1}')
            if [[ "$usage_int" -ge 90 ]]; then
                print_error "  FlashArray $fa_name is at ${used_percent}% capacity - CRITICAL!"
            elif [[ "$usage_int" -ge 80 ]]; then
                print_warning "  FlashArray $fa_name is at ${used_percent}% capacity - Consider expanding storage."
            fi
        fi

        # Step 5c: Get performance information
        echo ""
        print_info "  Retrieving performance metrics..."
        local perf_response
        perf_response=$(curl -s -k --connect-timeout 30 --max-time 60 \
            -H "x-auth-token: ${x_auth_token}" \
            "https://${endpoint}/api/2.35/arrays/performance" 2>/dev/null)
        curl_exit_code=$?

        if [[ $curl_exit_code -ne 0 ]] || [[ -z "$perf_response" ]]; then
            print_warning "  Failed to retrieve performance information from FlashArray $endpoint"
            print_warning "  Please check FlashArray connectivity and health manually."
        else
            # Parse the performance response using sed
            local reads_per_sec
            local writes_per_sec
            local read_bytes_per_sec
            local write_bytes_per_sec
            local usec_per_read_op
            local usec_per_write_op

            # Extract performance metrics
            reads_per_sec=$(echo "$perf_response" | sed 's/.*"reads_per_sec":\([0-9]*\).*/\1/')
            writes_per_sec=$(echo "$perf_response" | sed 's/.*"writes_per_sec":\([0-9]*\).*/\1/')
            read_bytes_per_sec=$(echo "$perf_response" | sed 's/.*"read_bytes_per_sec":\([0-9]*\).*/\1/')
            write_bytes_per_sec=$(echo "$perf_response" | sed 's/.*"write_bytes_per_sec":\([0-9]*\).*/\1/')
            usec_per_read_op=$(echo "$perf_response" | sed 's/.*"usec_per_read_op":\([0-9]*\).*/\1/')
            usec_per_write_op=$(echo "$perf_response" | sed 's/.*"usec_per_write_op":\([0-9]*\).*/\1/')

            # Calculate total IOPS
            local total_iops=0
            if [[ -n "$reads_per_sec" ]] && [[ -n "$writes_per_sec" ]]; then
                total_iops=$((reads_per_sec + writes_per_sec))
            fi

            # Convert bandwidth to human readable (MB/s or GB/s)
            local read_bw_human=""
            local write_bw_human=""
            local total_bw_human=""

            if [[ -n "$read_bytes_per_sec" ]] && [[ "$read_bytes_per_sec" =~ ^[0-9]+$ ]]; then
                if [[ "$read_bytes_per_sec" -ge 1073741824 ]]; then
                    read_bw_human=$(awk "BEGIN {printf \"%.2f GB/s\", $read_bytes_per_sec / 1073741824}")
                else
                    read_bw_human=$(awk "BEGIN {printf \"%.2f MB/s\", $read_bytes_per_sec / 1048576}")
                fi
            fi

            if [[ -n "$write_bytes_per_sec" ]] && [[ "$write_bytes_per_sec" =~ ^[0-9]+$ ]]; then
                if [[ "$write_bytes_per_sec" -ge 1073741824 ]]; then
                    write_bw_human=$(awk "BEGIN {printf \"%.2f GB/s\", $write_bytes_per_sec / 1073741824}")
                else
                    write_bw_human=$(awk "BEGIN {printf \"%.2f MB/s\", $write_bytes_per_sec / 1048576}")
                fi
            fi

            if [[ -n "$read_bytes_per_sec" ]] && [[ -n "$write_bytes_per_sec" ]] && \
               [[ "$read_bytes_per_sec" =~ ^[0-9]+$ ]] && [[ "$write_bytes_per_sec" =~ ^[0-9]+$ ]]; then
                local total_bw=$((read_bytes_per_sec + write_bytes_per_sec))
                if [[ "$total_bw" -ge 1073741824 ]]; then
                    total_bw_human=$(awk "BEGIN {printf \"%.2f GB/s\", $total_bw / 1073741824}")
                else
                    total_bw_human=$(awk "BEGIN {printf \"%.2f MB/s\", $total_bw / 1048576}")
                fi
            fi

            # Convert latency to human readable (µs or ms)
            local read_latency_human=""
            local write_latency_human=""

            if [[ -n "$usec_per_read_op" ]] && [[ "$usec_per_read_op" =~ ^[0-9]+$ ]]; then
                if [[ "$usec_per_read_op" -ge 1000 ]]; then
                    read_latency_human=$(awk "BEGIN {printf \"%.2f ms\", $usec_per_read_op / 1000}")
                else
                    read_latency_human="${usec_per_read_op} µs"
                fi
            fi

            if [[ -n "$usec_per_write_op" ]] && [[ "$usec_per_write_op" =~ ^[0-9]+$ ]]; then
                if [[ "$usec_per_write_op" -ge 1000 ]]; then
                    write_latency_human=$(awk "BEGIN {printf \"%.2f ms\", $usec_per_write_op / 1000}")
                else
                    write_latency_human="${usec_per_write_op} µs"
                fi
            fi

            # Display performance metrics
            echo ""
            echo "  --- Performance Metrics ---"
            print_info "  IOPS (Read/Write/Total): ${reads_per_sec:-N/A} / ${writes_per_sec:-N/A} / ${total_iops:-N/A}"
            print_info "  Bandwidth (Read/Write/Total): ${read_bw_human:-N/A} / ${write_bw_human:-N/A} / ${total_bw_human:-N/A}"
            print_info "  Latency (Read/Write): ${read_latency_human:-N/A} / ${write_latency_human:-N/A}"

            # Check for high latency and warn
            if [[ -n "$usec_per_read_op" ]] && [[ "$usec_per_read_op" =~ ^[0-9]+$ ]]; then
                if [[ "$usec_per_read_op" -ge 5000 ]]; then
                    print_error "  Read latency is very high (${read_latency_human}) - Performance degradation detected!"
                elif [[ "$usec_per_read_op" -ge 1000 ]]; then
                    print_warning "  Read latency is elevated (${read_latency_human}) - Monitor closely."
                fi
            fi

            if [[ -n "$usec_per_write_op" ]] && [[ "$usec_per_write_op" =~ ^[0-9]+$ ]]; then
                if [[ "$usec_per_write_op" -ge 5000 ]]; then
                    print_error "  Write latency is very high (${write_latency_human}) - Performance degradation detected!"
                elif [[ "$usec_per_write_op" -ge 1000 ]]; then
                    print_warning "  Write latency is elevated (${write_latency_human}) - Monitor closely."
                fi
            fi
        fi

        echo ""
    done
}

check_nbdd() {
    echo ""
    echo "=========================================="
    echo "  Checking NBDD (Non-Blocking Device Delete)"
    echo "=========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    local found_in_stc=false
    local found_in_pxctl=false
    local stc_delete_after_discard=""
    local stc_delete_max_concurrent=""
    local pxctl_delete_after_discard=""
    local pxctl_delete_max_concurrent=""

    # Check StorageCluster for NBDD variables
    print_info "Checking StorageCluster for NBDD variables..."
    local stc_output
    stc_output=$($cmd -n "$PX_NAMESPACE" get stc -o yaml 2>/dev/null | grep "device_delete" || true)

    if [[ -n "$stc_output" ]]; then
        stc_delete_after_discard=$(echo "$stc_output" | grep "device_delete_after_discard" | sed 's/.*device_delete_after_discard:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' ')
        stc_delete_max_concurrent=$(echo "$stc_output" | grep "device_delete_max_concurrent" | sed 's/.*device_delete_max_concurrent:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' ')

        if [[ -n "$stc_delete_after_discard" ]] && [[ -n "$stc_delete_max_concurrent" ]]; then
            found_in_stc=true
            print_info "Found in StorageCluster:"
            print_info "  device_delete_after_discard: $stc_delete_after_discard"
            print_info "  device_delete_max_concurrent: $stc_delete_max_concurrent"
        fi
    fi

    # Check pxctl cluster options for NBDD variables
    print_info "Checking pxctl cluster options for NBDD variables..."
    local pxctl_output
    if [[ "$PX_SECURITY_ENABLED" == "true" ]] && [[ -n "$PX_AUTH_TOKEN" ]]; then
        pxctl_output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- bash -c "export PXCTL_AUTH_TOKEN=$PX_AUTH_TOKEN && /opt/pwx/bin/pxctl cluster options list" 2>/dev/null | grep -i "device_delete" || true)
    else
        pxctl_output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- /opt/pwx/bin/pxctl cluster options list 2>/dev/null | grep -i "device_delete" || true)
    fi

    if [[ -n "$pxctl_output" ]]; then
        # Parse from format: Runtime options: selector: -, options: device_delete_after_discard=1,device_delete_max_concurrent=1
        pxctl_delete_after_discard=$(echo "$pxctl_output" | grep -oE "device_delete_after_discard=[0-9]+" | cut -d'=' -f2)
        pxctl_delete_max_concurrent=$(echo "$pxctl_output" | grep -oE "device_delete_max_concurrent=[0-9]+" | cut -d'=' -f2)

        if [[ -n "$pxctl_delete_after_discard" ]] && [[ -n "$pxctl_delete_max_concurrent" ]]; then
            found_in_pxctl=true
            print_info "Found in pxctl cluster options:"
            print_info "  device_delete_after_discard: $pxctl_delete_after_discard"
            print_info "  device_delete_max_concurrent: $pxctl_delete_max_concurrent"
        fi
    fi

    # If neither location has the variables, print warning
    if [[ "$found_in_stc" == "false" ]] && [[ "$found_in_pxctl" == "false" ]]; then
        echo ""
        print_info "Cluster running version $PX_CLUSTER_VERSION."
        print_warning "Starting PXE 3.5 NBDD variables should be set on cluster, please set device_delete_after_discard and device_delete_max_concurrent."
        print_warning "More details here: https://docs.portworx.com/portworx-enterprise/reference/cli/non-blocking-device-delete"
    else
        echo ""
        print_info "NBDD variables are configured on the cluster."
    fi
}

fix_vps_frequency() {
    echo ""
    echo "=========================================="
    echo "  Checking Fix VPS Frequency"
    echo "=========================================="
    echo ""

    # Build the command with optional kubeconfig
    local cmd="$CLI_TOOL"
    if [[ -n "$KUBECONFIG_PATH" ]]; then
        cmd="$cmd --kubeconfig=$KUBECONFIG_PATH"
    fi

    print_info "Checking pxctl cluster options for VPS frequency..."

    local vps_output
    if [[ "$PX_SECURITY_ENABLED" == "true" ]] && [[ -n "$PX_AUTH_TOKEN" ]]; then
        vps_output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- bash -c "export PXCTL_AUTH_TOKEN=$PX_AUTH_TOKEN && /opt/pwx/bin/pxctl cluster options list" 2>/dev/null | grep -i "Fix VPS frequency" || true)
    else
        vps_output=$($cmd -n "$PX_NAMESPACE" exec "$SELECTED_POD" -- /opt/pwx/bin/pxctl cluster options list 2>/dev/null | grep -i "Fix VPS frequency" || true)
    fi

    if [[ -n "$vps_output" ]]; then
        # Extract the value - format: "Fix VPS frequency in minutes                            : 15"
        local vps_value
        vps_value=$(echo "$vps_output" | sed 's/.*:[[:space:]]*//' | tr -d ' ')

        if [[ -n "$vps_value" ]] && [[ "$vps_value" != "0" ]]; then
            print_info "Fix VPS frequency in minutes: $vps_value"
        else
            print_warning "Fix VPS frequency is not set or set to 0."
            print_warning "Consider setting a VPS frequency value using: pxctl cluster options update --fix-vps-frequency-in-minutes <value>"
        fi
    else
        print_warning "Could not retrieve VPS frequency setting from pxctl cluster options."
    fi
}

main() {
    echo ""
    echo "=========================================="
    echo "  Portworx Pre-Upgrade Health Check"
    echo "=========================================="
    echo ""
    echo "This script will do a general health check of the Portworx."
    echo "It does not make any changes to the Portworx cluster or settings."
    echo ""

    local continue_check
    continue_check=$(validate_yes_no_input "Do you want to continue? (y/n): ")
    if [[ "$continue_check" != "y" ]]; then
        echo ""
        print_info "Exiting health check script."
        exit 0
    fi

    echo ""

    # Download px_gather_logs.sh script at the start (required for cluster data bundle backup)
    download_px_gather_logs_script

    select_cli_tool
    select_kubeconfig
    confirm_namespace
    select_portworx_pod
    detect_px_security #Check if a px-security enabled on the cluster.
    customer_recommendations
    
    #Begin healthcheck functions here.
    pxctl_status #Always has to be the first one to run.
    kvdb_members_status
    repl_one_volumes
    volume_resync_status_check
    volume_not_up
    check_portworx_pdbs
    check_update_strategy
    operator_managed_pods
    manual_image_check
    check_flasharray
    px_alerts_show
    check_nbdd
    fix_vps_frequency

    # Run cluster data bundle backup at the end
    cluster_data_bundle_backup

    echo ""
    print_info "Health check completed!"
    print_info "Output saved to: $LOG_FILE"

    # Summary of WARNING and ERROR messages
    echo ""
    echo "========================================="
    echo "  SUMMARY: Warnings and Errors"
    echo "========================================="
    echo ""

    # Use the arrays we've been building throughout the script
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo -e "${RED}=== ERRORS ===${NC}"
        for error_msg in "${ERRORS[@]}"; do
            echo -e "${RED}[ERROR]${NC} $error_msg"
        done
        echo ""
    fi

    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}=== WARNINGS ===${NC}"
        for warning_msg in "${WARNINGS[@]}"; do
            echo -e "${YELLOW}[WARNING]${NC} $warning_msg"
        done
        echo ""
    fi

    if [[ ${#ERRORS[@]} -eq 0 ]] && [[ ${#WARNINGS[@]} -eq 0 ]]; then
        print_info "No warnings or errors found. Cluster appears healthy!"
    else
        echo -e "Total: ${RED}${#ERRORS[@]} error(s)${NC}, ${YELLOW}${#WARNINGS[@]} warning(s)${NC}"
    fi
    echo "========================================="
}

# Run main function
main
