#!/bin/bash
# ================================================================
# Script: px_gather_logs.sh
# Description: Collects logs and other information related to portworx/PX Backup.
# Usage:
# - Mandatory arguments:
#   -o <option>    : Operation option (PX for Portworx, PXB for PX Backup)
#
# - Optional arguments:
#   -n <namespace> : K8s namespace. If not provided, the script automatically determines the namespace. Specify this option only if automatic detection encounters inconsistencies or if you want to explicitly set the namespace.
#   -c <cli>       : CLI tool to use (oc/kubectl).If not provided, the script automatically determines the CLI. 
#   -u <pure ftps username>  : Pure Storage FTPS username for uploading logs
#   -p <pure ftps password>  : Pure Storage FTPS password for uploading logs
#   -d <output_dir>: Custom output directory for storing diags
#
# Examples:
#   For Portworx:
#       px_gather_logs.sh -o PX
#   For PX Backup:
#       px_gather_logs.sh -o PXB
#
# - If no parameters are passed, the script will prompt for mandatory arguments input.
#
# ================================================================

SCRIPT_VERSION="26.5.6"


# Function to display usage
usage() {
  echo "Usage: $0 [-n <namespace>] [-c <cli>] [-o <option>]"
  echo "  -n <namespace> : Kubernetes namespace"
  echo "  -c <cli>       : CLI tool to use (oc/kubectl)"
  echo "  -o <option>    : Operation option (PX/PXB)"
  echo "  -d <output_dir>: Output directory for files (optional)"
  exit 1
}
# Function to print info in summary file

log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> $summary_file
}

# Function to print console log

print_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*"
}
# Function to print progress

print_progress() {
    local current_stage=$1
    local total_stages="12"
    local action=$2
    if [[ "$action" == "skip" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Skipping $current_stage/$total_stages..." | tee -a "$summary_file"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Extracting $current_stage/$total_stages..." | tee -a "$summary_file"
    fi
}
# Helper: returns 0 (true) if the pod is in ContainerCreating state
# Usage: is_container_creating <namespace> <pod_name>
is_container_creating() {
    local ns=$1
    local pod=$2
    local pod_status
    pod_status=$($cli get pod -n "$ns" "$pod" --no-headers 2>/dev/null | awk '{print $3}')
    [[ "$pod_status" == "ContainerCreating" ]]
}

# Resolve coordinator node name from pxctl_status.json (lowest StorageSpecs[*].NID).
# Uses jq when available; otherwise falls back to awk.
get_coordinator_node() {
    local status_file=$1
    [[ -s "$status_file" ]] || return 1

    if command -v jq >/dev/null 2>&1; then
        jq -r '
            (.daemoninfo.StorageSpecs | to_entries | min_by(.value.NID) | .key) as $uid |
            .cluster.Nodes[] | select(.Id == $uid) | .SchedulerNodeName
        ' "$status_file" 2>/dev/null
        return 0
    fi

    local uid
    uid=$(awk '
        /"StorageSpecs":[[:space:]]*\{/ { in_specs=1; next }
        in_specs && /^  "[^"]+":[[:space:]]*[\{\[]/ { in_specs=0 }
        in_specs && /^   "[0-9a-fA-F-]{36}":[[:space:]]*\{/ {
            match($0, /"[0-9a-fA-F-]{36}"/)
            cur_uuid = substr($0, RSTART+1, RLENGTH-2)
            next
        }
        in_specs && cur_uuid != "" && /^    "NID":[[:space:]]*[0-9]+/ {
            match($0, /[0-9]+/)
            nid = substr($0, RSTART, RLENGTH) + 0
            if (best_uuid == "" || nid < best_nid) { best_nid = nid; best_uuid = cur_uuid }
            cur_uuid = ""
        }
        END { print best_uuid }
    ' "$status_file")
    [[ -n "$uid" ]] || return 1

    awk -v uid="$uid" '
        /"Nodes":[[:space:]]*\[/ { in_nodes=1; next }
        in_nodes && /^  \]/ { exit }
        in_nodes && /^   \{/ { cur_id=""; cur_name=""; next }
        in_nodes && /^   \},?/ {
            if (cur_id == uid) { print cur_name; exit }
            next
        }
        in_nodes && cur_id == "" && /"Id":[[:space:]]*"/ {
            match($0, /"Id":[[:space:]]*"[^"]+"/)
            s = substr($0, RSTART, RLENGTH)
            sub(/^"Id":[[:space:]]*"/, "", s); sub(/"$/, "", s)
            cur_id = s
        }
        in_nodes && cur_name == "" && /"SchedulerNodeName":[[:space:]]*"/ {
            match($0, /"SchedulerNodeName":[[:space:]]*"[^"]*"/)
            s = substr($0, RSTART, RLENGTH)
            sub(/^"SchedulerNodeName":[[:space:]]*"/, "", s); sub(/"$/, "", s)
            cur_name = s
        }
    ' "$status_file"
}


# Parse command-line arguments
while getopts "n:c:o:u:p:d:f:l:" opt; do
  case $opt in
    n) namespace=$(echo "$OPTARG" | tr '[:upper:]' '[:lower:]') ;;
    c) cli="$OPTARG" ;;
    o) option=$(echo "$OPTARG" | tr '[:lower:]' '[:upper:]') ;;
    u) ftpsuser=$(echo "$OPTARG" | tr '[:lower:]' '[:upper:]') ;;
    p) ftpspass="$OPTARG" ;;
    d) user_output_dir="$OPTARG" ;;
    f) file_prefix="${OPTARG:0:15}_" ;;
    l) max_pods_logs="$OPTARG" ;;
    *) usage ;;
  esac
done

# Prompt for namespace if not provided
#if [[ -z "$namespace" ]]; then
#  read -p "Enter the namespace: " namespace
#  namespace=$(echo "$namespace" | tr '[:upper:]' '[:lower:]')
#  if [[ -z "$namespace" ]]; then
#    echo "Error: Namespace cannot be empty."
#    exit 1
#  fi
#fi



# Prompt for k8s CLI  if not provided
#if [[ -z "$cli" ]]; then
#  read -p "Enter the k8s CLI (oc/kubectl): " cli
#fi

validate_and_derive_k8s_cli() {


# Validate user-provided CLI

if [[ -n "$cli" ]]; then
# Check if the CLI value is kubectl or OC
print_info "cli is passed as $cli, validating"


if [[ "$cli" != "oc" && "$cli" != "kubectl" ]]; then
  print_info "Error: Invalid k8s CLI. Choose either 'oc' or 'kubectl'."
  exit 1
fi

# Check if the CLI is available
if ! command -v "$cli" &> /dev/null; then
  print_info "Error: '$cli' command not found. Please ensure that '$cli' is available in this server"
  exit 1
fi


# Check if the CLI command works
if ! $cli get namespaces &> /dev/null; then
  print_info "Error: '$cli' is available but not functioning correctly. Ensure you have the necessary permissions to execute '$cli' commands on the cluster."
  exit 1
fi

fi

# Automatic Cli derrivation

if [[ -z "$cli" ]]; then

print_info "CLI tool is not passed, deriving it automatically"

    kubectl_ok=false
    oc_ok=false

    # Check kubectl
    if command -v kubectl >/dev/null 2>&1 && \
       kubectl version --request-timeout=5s >/dev/null 2>&1; then
        kubectl_ok=true
    fi

    # Check oc
    if command -v oc >/dev/null 2>&1 && \
       oc version --request-timeout=5s >/dev/null 2>&1; then
        oc_ok=true
    fi

# No usable CLI
    if ! $kubectl_ok && ! $oc_ok; then
        print_info "ERROR: Neither kubectl nor oc can access a cluster" >&2
        exit 1
    fi

    # If only one works, use it
    if $kubectl_ok && ! $oc_ok; then
        cli="kubectl"
    elif ! $kubectl_ok && $oc_ok; then
        cli="oc"
    else
        # Both work → detect OpenShift
        if kubectl api-resources 2>/dev/null | grep -qi 'openshift'; then
            cli="oc"
        else
            cli="kubectl"
        fi
    fi

print_info "Using CLI: $cli"
fi


}

validate_and_derive_k8s_cli


validate_and_derive_option() {
  # Default option to PX if not provided (with 10-second timed prompt)
  if [[ -z "$option" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): -o option not passed. Pass -o PXB if you are looking to extract PXB diags."
    # When the script is piped (e.g., `curl ... | bash`), stdin is the script content itself,
    # so the prompt must read from the controlling terminal via /dev/tty. If no controlling
    # terminal is available (e.g., cron), skip the prompt and default to PX.
    if exec 3< /dev/tty 2>/dev/null; then
      printf "\033[33m%s: 10 seconds remaining...\033[0m\n" "$(date '+%Y-%m-%d %H:%M:%S')"
      printf "%s: Enter PX or PXB (default: PX, press Enter to accept default): " "$(date '+%Y-%m-%d %H:%M:%S')"
      local option_input=""
      local i
      for ((i=9; i>=1; i--)); do
        if read -t 1 -u 3 option_input; then
          break
        fi
        printf "\0337\033[A\r\033[K\033[33m%s: %2d seconds remaining...\033[0m\0338" "$(date '+%Y-%m-%d %H:%M:%S')" "$i"
      done
      exec 3<&-
      printf "\n"
      if [[ -z "$option_input" ]]; then
        option="PX"
        option_defaulted=true
        echo "$(date '+%Y-%m-%d %H:%M:%S'): No option input received, setting default option as PX. Pass -o PXB if you are looking to extract PXB diags"
      else
        option=$(echo "$option_input" | tr '[:lower:]' '[:upper:]')
      fi
    else
      option="PX"
      option_defaulted=true
      echo "$(date '+%Y-%m-%d %H:%M:%S'): No interactive terminal available, setting default option as PX. Pass -o PXB if you are looking to extract PXB diags"
    fi
  fi

  # Validate option value
  if [[ "$option" != "PX" && "$option" != "PXB" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Error: Invalid option '$option'. Choose either 'PX' or 'PXB'."
    exit 1
  fi
}

validate_and_derive_option


# Normalize input namespace if provided
validate_and_derive_namespace() {
if [[ -n "$namespace" ]]; then
  namespace=$(echo "$namespace" | tr '[:upper:]' '[:lower:]')

  if ! $cli get namespace "$namespace" >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Error: Namespace '$namespace' does not exist in the cluster."
    exit 1
  fi
else
  echo "$(date '+%Y-%m-%d %H:%M:%S'): Namespace is not passed, deriving it automatically"
  case "$option" in
    PX)
      namespace=$(
        $cli get stc -A --no-headers 2>/dev/null \
        | awk '{print $1}' \
        | sort -u
      )
      ;;
    PXB)
      namespace=$(
        $cli get deployment -A --no-headers 2>/dev/null \
        | awk '$2 == "px-backup" {print $1}' \
        | sort -u
      )
      ;;
    *)
      echo "$(date '+%Y-%m-%d %H:%M:%S'): Error: Invalid option '$option'. Expected PX or PXB."
      exit 1
      ;;
  esac

  if [[ -z "$namespace" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Error: Could not determine namespace automatically.Please pass the namespace as parameter to the script as -n <namespace>"
    exit 1
  fi

  # Ensure exactly one namespace is found
  if [[ $(echo "$namespace" | wc -l) -gt 1 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Error: Multiple namespaces found while driving it for $option:"
    echo "$namespace"
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Please provide the namespace explicitly as parameter to the script as -n <namespace>"
    exit 1
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S'): Derived namespace: $namespace"
fi

}

validate_and_derive_namespace

# Automatically get Kubernetes cluster name

if $cli get infrastructure cluster &>/dev/null; then
    # Example: mycluster-xyz12, for openshift
    cluster_name=$($cli get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
else
    # Generic Kubernetes fallback (from kubeconfig)
    cluster_name=$($cli config view --minify -o jsonpath='{.clusters[0].name}')
fi


# Confirm inputs
echo "$(date '+%Y-%m-%d %H:%M:%S'): Script Version: $SCRIPT_VERSION"
echo "$(date '+%Y-%m-%d %H:%M:%S'): k8s Cluster Name: $cluster_name"
echo "$(date '+%Y-%m-%d %H:%M:%S'): Namespace: $namespace"
echo "$(date '+%Y-%m-%d %H:%M:%S'): CLI tool: $cli"
echo "$(date '+%Y-%m-%d %H:%M:%S'): option: $option"

# Added function to check if its PX CSI V3 (version higher than 25.8.0)

check_if_px_csiv3() {
  [[ "$option" == "PX" ]] || return 0

  local REQUIRED_ARG="oem px-csi"
  local REQUIRED_IMAGE_STRING="px-pure-csi-driver"

  # Expect exactly one STC
  local STC
  STC=$($cli get stc -n "$namespace" \
    -o jsonpath='{.items[*].metadata.name}')

  local COUNT
  COUNT=$(wc -w <<< "$STC")

  if [[ "$COUNT" -ne 1 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Expected exactly one STC in namespace '$namespace', found $COUNT"
    return 1
  fi

  # Annotation check
  local MISC_ARGS
  MISC_ARGS=$($cli get stc "$STC" -n "$namespace" \
    -o jsonpath='{.metadata.annotations.portworx\.io/misc-args}' 2>/dev/null)

  if ! grep -q "$REQUIRED_ARG" <<< "$MISC_ARGS"; then
    return 1
  fi

  # Image string check
  local IMAGE
  IMAGE=$($cli get stc "$STC" -n "$namespace" \
    -o jsonpath='{.spec.image}' 2>/dev/null)

  if ! grep -q "$REQUIRED_IMAGE_STRING" <<< "$IMAGE"; then
    return 1
  fi

  # All checks passed → set flag
  PXCSIV3=true
  echo "$(date '+%Y-%m-%d %H:%M:%S'): PX CSI v3 detected"
  return 0
}

check_if_px_csiv3

# Setting up output directories

setup_output_dirs() {

# List of the cluster names we want to exclude from diag name (default ones)
invalid_cluster_names=("default" "kubernetes" "cluster.local")


cluster_name_derived=${cluster_name##*/} #Consider the string after "/" if cluster name has "/"
cluster_name_derived=${cluster_name_derived//:/_}     # replace ':' with '_'

cluster_part=""
if [[ -z "$file_prefix" && -n "$cluster_name" ]]; then
  skip_cluster=false
  for invalid in "${invalid_cluster_names[@]}"; do
    if [[ "$cluster_name" == "$invalid" ]]; then
      skip_cluster=true
      break
    fi
  done

  if [[ "$skip_cluster" == false ]]; then
    cluster_part="${cluster_name_derived}_"
  fi
fi



if [[ "$option" == "PX" ]]; then
  if [[ "$PXCSIV3" == "true" ]]; then
     main_dir="${file_prefix}PXCSI_${cluster_part}${namespace}_k8s_diags_$(date +%Y%m%d_%H%M%S)"
  else
     main_dir="${file_prefix}PXE_${cluster_part}${namespace}_k8s_diags_$(date +%Y%m%d_%H%M%S)"
  fi
else
  main_dir="${file_prefix}PXB_${cluster_part}${namespace}_k8s_diags_$(date +%Y%m%d_%H%M%S)"
fi

if [[ -n "$user_output_dir" ]]; then
  output_dir="${user_output_dir%/}/${main_dir}"
else
  output_dir="/tmp/${main_dir}"
fi

#if [[ "$option" == "PX" ]]; then
#  if [[ "$PXCSIV3" == "true" ]]; then
#     sub_dir=(${output_dir}/logs/previous ${output_dir}/k8s_px ${output_dir}/k8s_oth ${output_dir}/k8s_bkp ${output_dir}/k8s_pxb)
#  else
#     sub_dir=(${output_dir}/logs/previous ${output_dir}/px_out ${output_dir}/k8s_px ${output_dir}/k8s_oth ${output_dir}/migration ${output_dir}/k8s_bkp ${output_dir}/k8s_pxb ${output_dir}/storkctl_out)
#  fi
#else
#  sub_dir=(${output_dir}/logs/previous ${output_dir}/k8s_pxb ${output_dir}/k8s_oth ${output_dir}/k8s_bkp ${output_dir}/pxb_db_collections)
#fi

# Common directories
common_dirs=(
  "${output_dir}/logs/previous"
  "${output_dir}/logs/kube_components"
  "${output_dir}/cluster"
  "${output_dir}/storage"
  "${output_dir}/px_backup"
  "${output_dir}/monitoring"
  "${output_dir}/openshift"
  "${output_dir}/backup"
  "${output_dir}/cluster_governance"
)

# Initialize array
sub_dir=("${common_dirs[@]}")

if [[ "$option" == "PX" ]]; then
  sub_dir+=(
      "${output_dir}/portworx/workloads"
      "${output_dir}/portworx/px_csi"
    )
  
  if [[ "$PXCSIV3" != "true" ]]; then
    sub_dir+=(
      "${output_dir}/migration"
      "${output_dir}/storkctl_out"
      "${output_dir}/portworx/pxctl_out"
    )
  fi
else
  sub_dir+=(
    "${output_dir}/pxb_db_collections"
    "${output_dir}/backup/kdmp"
  )
fi


mkdir -p "$output_dir"
mkdir -p "${sub_dir[@]}"
echo "$(date '+%Y-%m-%d %H:%M:%S'): Output will be stored in: $output_dir"

}
setup_output_dirs

# Set commands based on the chosen option
if [[ "$option" == "PX" ]]; then
#  admin_ns=$($cli -n $namespace get stc -o jsonpath='{.items[*].spec.stork.args.admin-namespace}')
#  admin_ns="${admin_ns:-kube-system}"
  sec_enabled=$($cli -n $namespace get stc -o=jsonpath='{.items[*].spec.security.enabled}')


  commands=(
    "get pods -o wide -n $namespace"
    "get pods -o wide -n $namespace -o yaml"
    "describe pods -n $namespace"
    "get nodes -o wide"
    "get nodes -o wide -o yaml"
    "describe nodes"
    "get nodes -L px/enabled,px/service,px/metadata-node,portworx.io/provision-storage-node,portworx.io/provision-storage-node-handled,portworx.io/node-type"
    "get events -A -o wide --sort-by=.lastTimestamp"
    "get deploy -o wide -n $namespace"
    "get deploy -o wide -n $namespace -o yaml"
    "describe deploy -n $namespace"
    "get volumeattachments"
    "get volumeattachments -o yaml"
    "get csidrivers"
    "get csinodes"
    "get csinodes -o yaml"
    "get configmaps -n $namespace"
    "get configmap px-versions -n $namespace -o yaml"
    "describe namespace $namespace"
    "get namespace $namespace -o yaml"
    "get secret -n $namespace"
    "get sc"
    "get sc -o yaml"
    "get pvc -A -o wide"
    "get pvc -A -o yaml"
    "get pv"
    "get pv -o yaml"
    "get sn -n $namespace"
    "get mutatingwebhookconfiguration"
    "get mutatingwebhookconfiguration -o yaml"
    "get svc,ep -o wide -n $namespace"
    "get svc,ep -o yaml -n $namespace"
    "get ds -o yaml -n $namespace"
    "get pdb -n $namespace"
    "get pdb -n $namespace -o yaml"
    "get pods -n kube-system -o wide"
    "version"
    "get controllerrevisions -n $namespace"
    "get controllerrevisions -n $namespace -o yaml"
    "api-resources -o wide"
    "get autopilotrules"
    "get autopilotrules -o yaml"
    "get autopilotruleobjects -A"
    "get autopilotruleobjects -A -o yaml"
    "get applicationbackups -A"
    "get applicationbackups -A -o yaml"
    "get applicationbackupschedule -A"
    "get applicationbackupschedule -A -o yaml"
    "describe applicationbackupschedule -A"
    "get applicationrestores -A"
    "get applicationrestores -A -o yaml"
    "describe applicationrestores -A"
    "get applicationregistrations -A"
    "get applicationregistrations -A -o yaml"
    "get backuplocations -A"
    "get backuplocations -A -o yaml"
    "get volumesnapshots -A"
    "get volumesnapshots -A -o yaml"
    "get volumesnapshotcontents"
    "get volumesnapshotcontents -o yaml"
    "get volumesnapshotdatas -A"
    "get volumesnapshotdatas -A -o yaml"
    "get volumesnapshotschedules -A"
    "get volumesnapshotschedules -A -o yaml"
    "get volumesnapshotrestores -A"
    "get volumesnapshotrestores -A -o yaml"
    "get volumesnapshotclasses"
    "get volumesnapshotclasses -o yaml"
    "get schedulepolicies"
    "get schedulepolicies -o yaml"
    "get dataexports -A"
    "get dataexports -A -o yaml"
    "get prometheuses -A"
    "get prometheuses -A -o yaml"
    "get prometheusrules -A"
    "get prometheusrules -A -o yaml"
    "get alertmanagers -A"
    "get alertmanagers -A -o yaml" 
    "get alertmanagerconfigs -A"
    "get alertmanagerconfigs -A -o yaml" 
    "get servicemonitors -A"
    "get servicemonitors -A -o yaml"
    "get cm kdmp-config -n kube-system -o yaml"
    "get cm stork-controller-config -n kube-system -o yaml"
    "get rules -A"
    "get rules -A -o yaml"
    "get svc,ep -A -l "portworx.io/volid" -o wide"
    "get svc,ep -A -l "portworx.io/volid" -o yaml"
    "get pods -A -o wide"
    "get volumebackups -A"
    "get volumebackups -A -o yaml"
    "get jobs -A -l kdmp.portworx.com/driver-name=kopiabackup --show-labels"
    "get jobs -A -l kdmp.portworx.com/driver-name=kopiabackup -o yaml"
    "get groupvolumesnapshots.stork.libopenstorage.org -A"
    "get groupvolumesnapshots.stork.libopenstorage.org -A -o yaml"
    "get volumeplacementstrategies"
    "get volumeplacementstrategies -o yaml"
    "get ComponentK8sConfig -n $namespace"
    "get ComponentK8sConfig -n $namespace -o yaml"
    "get sa -o wide -n $namespace"
    "get sa -o yaml -n $namespace"
    "get purevolumes -A"
    "get purevolumes -A -o yaml"
    "get puresnapshots -A"
    "get puresnapshots -A -o yaml"
    "get storagenodeinitiators"
    "get storagenodeinitiators -o yaml"
    "get purestoragecluster -n $namespace"
    "get purestoragecluster -n $namespace -o yaml"
    
  )
  output_files=(
    "portworx/workloads/px_pods.txt"
    "portworx/workloads/px_pods.yaml"
    "portworx/workloads/px_pods_desc.txt"
    "cluster/k8s_nodes.txt"
    "cluster/k8s_nodes.yaml"
    "cluster/k8s_nodes_desc.txt"
    "portworx/k8s_nodes_px_labels.txt"
    "cluster/k8s_events_all.txt"
    "portworx/workloads/px_deploy.txt"
    "portworx/workloads/px_deploy.yaml"
    "portworx/workloads/px_deploy_desc.txt"
    "storage/volumeattachments.txt"
    "storage/volumeattachments.yaml"
    "storage/csidrivers.txt"
    "storage/csinodes.txt"
    "storage/csinodes.yaml"
    "portworx/px_cm.txt"
    "portworx/px-versions_cm.yaml"
    "portworx/px_ns_dec.txt"
    "portworx/px_ns.yaml"
    "portworx/px_secret_list.txt"
    "storage/sc.txt"
    "storage/sc.yaml"
    "storage/pvc_list.txt"
    "storage/pvc_all.yaml"
    "storage/pv_list.txt"
    "storage/pv_all.yaml"
    "portworx/px_storagenodes_list.txt"
    "cluster_governance/mutatingwebhookconfiguration.txt"
    "cluster_governance/mutatingwebhookconfiguration.yaml"
    "portworx/px_svc_ep.txt"
    "portworx/px_svc_ep.yaml"
    "portworx/workloads/px_ds.yaml"
    "portworx/px_pdb.txt"
    "portworx/px_pdb.yaml"
    "cluster/pods_kube_system.txt"
    "cluster/k8s_version.txt"
    "portworx/px_controllerrevisions.txt"
    "portworx/px_controllerrevisions.yaml"
    "cluster/k8s_api_resources.txt"
    "portworx/autopilotrules.txt"
    "portworx/autopilotrules.yaml"
    "portworx/autopilotruleobjects.txt"
    "portworx/autopilotruleobjects.yaml"
    "backup/applicationbackups.txt"
    "backup/applicationbackups.yaml"
    "backup/applicationbackupschedules.txt"
    "backup/applicationbackupschedules.yaml"
    "backup/applicationbackupschedules_desc.txt"
    "backup/applicationrestores.txt"
    "backup/applicationrestores.yaml"
    "backup/applicationrestores_desc.txt"
    "backup/applicationregistrations.txt"
    "backup/applicationregistrations.yaml"
    "backup/backuplocations.txt"
    "backup/backuplocations.yaml"
    "backup/volumesnapshots.txt"
    "backup/volumesnapshots.yaml"
    "backup/volumesnapshotcontents.txt"
    "backup/volumesnapshotcontents.yaml"
    "backup/volumesnapshotdatas.txt"
    "backup/volumesnapshotdatas.yaml"
    "backup/volumesnapshotschedules.txt"
    "backup/volumesnapshotschedules.yaml"
    "backup/volumesnapshotrestores.txt"
    "backup/volumesnapshotrestores.yaml"
    "backup/volumesnapshotclasses.txt"
    "backup/volumesnapshotclasses.yaml"
    "backup/schedulepolicies.txt"
    "backup/schedulepolicies.yaml"  
    "backup/dataexports.txt"
    "backup/dataexports.yaml"
    "monitoring/prometheuses_list.txt"
    "monitoring/prometheuses.yaml"
    "monitoring/prometheuses_rules_list.txt"
    "monitoring/prometheuses_rules.yaml"
    "monitoring/alertmanagers_list.txt"
    "monitoring/alertmanagers.yaml"
    "monitoring/alertmanagerconfigs.txt"
    "monitoring/alertmanagerconfigs.yaml"
    "monitoring/servicemonitors.txt"
    "monitoring/servicemonitors.yaml"  
    "px_backup/kdmp-config.yaml"
    "px_backup/stork-controller-config.yaml"
    "backup/px_rules.txt"
    "backup/px_rules.yaml"
    "portworx/px_sharedv4_svc_ep.txt"
    "portworx/px_sharedv4_svc_ep.yaml"
    "cluster/pods_all.txt"
    "backup/volumebackups.txt"
    "backup/volumebackups.yaml"
    "px_backup/kopia_backup_jobs.txt"
    "px_backup/kopia_backup_jobs.yaml"
    "backup/groupvolumesnapshots.txt"
    "backup/groupvolumesnapshots.yaml"
    "portworx/vps.txt"
    "portworx/vps.yaml"
    "portworx/componentk8sconfig.txt"
    "portworx/componentk8sconfig.yaml"
    "portworx/sa.txt"
    "portworx/sa.yaml"
    "portworx/px_csi/purevolumes.txt"
    "portworx/px_csi/purevolumes.yaml"
    "portworx/px_csi/puresnapshots.txt"
    "portworx/px_csi/puresnapshots.yaml"
    "portworx/px_csi/storagenodeinitiators.txt"
    "portworx/px_csi/storagenodeinitiators.yaml"
    "portworx/px_csi/purestoragecluster.txt"
    "portworx/px_csi/purestoragecluster.yaml"


  )
  pxctl_commands=(
    "status"
    "status -j"
    "cluster provision-status --output-type wide"
    "license list"
    "cluster options list"
    "cluster options list -j"
    "sv k m"
    "alerts show"
    "cloudsnap status"
    "cloudsnap status -j"
    "cloudsnap schedules list"
    "sched-policy list"
    "cd list"
    "cd list -j"
    "cred list"
    "volume list -v"
    "volume list -v -j"
    "volume list -s"
    "volume list -s -j"
    "sv call-home status -j"
    "sv pool drain list"
    "sv pool drain list -j"
    "sv pool rebalance list"
    "sv pool rebalance list -j"
    "cluster defrag schedule show"
    "cluster defrag schedule show -j"
    "cluster defrag status"
    "cluster defrag status -j"

  )
  pxctl_output_files=(
    "portworx/pxctl_out/pxctl_status.txt"
    "portworx/pxctl_out/pxctl_status.json"
    "portworx/pxctl_out/pxctl_cluster_provision_status.txt"
    "portworx/pxctl_out/pxctl_license_list.txt"
    "portworx/pxctl_out/pxctl_cluster_options.txt"
    "portworx/pxctl_out/pxctl_cluster_options.json"
    "portworx/pxctl_out/pxctl_kvdb_members.txt"
    "portworx/pxctl_out/pxctl_alerts_show.txt"
    "portworx/pxctl_out/pxctl_cs_status.txt"
    "portworx/pxctl_out/pxctl_cs_status.json"
    "portworx/pxctl_out/pxctl_cs_sched_list.txt"
    "portworx/pxctl_out/pxctl_sched-policy.txt"
    "portworx/pxctl_out/pxctl_cd_list.txt"
    "portworx/pxctl_out/pxctl_cd_list.json"
    "portworx/pxctl_out/pxctl_cred_list.txt"
    "portworx/pxctl_out/pxctl_volume_list.txt"
    "portworx/pxctl_out/pxctl_volume_list.json"
    "portworx/pxctl_out/pxctl_volume_snapshot_list.txt"
    "portworx/pxctl_out/pxctl_volume_snapshot_list.json"
    "portworx/pxctl_out/pxctl_callhome_status.json"
    "portworx/pxctl_out/pxctl_pool_drain_list.txt"
    "portworx/pxctl_out/pxctl_pool_drain_list.json"
    "portworx/pxctl_out/pxctl_pool_rebalance_list.txt"
    "portworx/pxctl_out/pxctl_pool_rebalance_list.json"
    "portworx/pxctl_out/pxctl_defrag_schedules.txt"
    "portworx/pxctl_out/pxctl_defrag_schedules.json"
    "portworx/pxctl_out/pxctl_defrag_status.txt"
    "portworx/pxctl_out/pxctl_defrag_status.json"
    
  )

  log_labels=(
    "name=autopilot"
    "name=portworx-api"
    "app=px-csi-driver"
    "name=portworx-pvc-controller"
    "role=px-telemetry-registration"
    "name=px-telemetry-phonehome"
    "app=px-plugin"
    "name=px-plugin-proxy"
    "name=portworx"
    "job-name=post-pure-csi-migrator"
    "job-name=pre-pure-csi-migrator"
    "app.kubernetes.io/component=controller-plugin"
    "app.kubernetes.io/component=node-plugin"
    "app.kubernetes.io/component=telemetry-plugin"
    "app.kubernetes.io/component=telemetry-registration"
    "role=realtime-metrics-collector"
    "app.kubernetes.io/instance=cert-manager"
    "name=px-pre-flight"
    
  )


  
  oth_commands=(
    "$cli -n kube-system get cm $($cli -n kube-system get cm|grep px-bootstrap|awk '{print $1}') -o yaml"
    "$cli -n kube-system get cm $($cli -n kube-system get cm|grep px-bootstrap|awk '{print $1}') -o json"
    "$cli -n kube-system get cm $($cli -n kube-system get cm|grep px-cloud-drive|awk '{print $1}') -o yaml"
    "$cli -n kube-system get cm $($cli -n kube-system get cm|grep px-cloud-drive|awk '{print $1}') -o json"

  )
  oth_output_files=(
    "portworx/px-bootstrap.yaml"
    "portworx/px-bootstrap.json"
    "portworx/px-cloud-drive.yaml"
    "portworx/px-cloud-drive.json"

  )
  migration_commands=(
    "get clusterpair -A"
    "get migrations.stork.libopenstorage.org -A"
    "describe migrations.stork.libopenstorage.org -A"
    "get migrations.stork.libopenstorage.org -A -o yaml"
    "get migrationschedule -A"
    "describe migrationschedule -A"
    "get migrationschedule -A -o yaml"
    "get schedulepolicies"
    "get schedulepolicies -o yaml"
    "get clusterdomainsstatuses"
    "get clusterdomainsstatuses -o yaml"
    "get resourcetransformations -A"
    "get resourcetransformations -A -o yaml"
    "get actions -A"
    "get actions -A -o yaml"
  )
   migration_output=(
    "migration/clusterpair.txt"
    "migration/migrations.txt"
    "migration/migrations_desc.txt"
    "migration/migrations.yaml"
    "migration/migrationschedule.txt"
    "migration/migrationschedule_desc.txt"
    "migration/migrationschedule.yaml"
    "migration/schedulepolicies.txt"
    "migration/schedulepolicies.yaml"
    "migration/cds.txt"
    "migration/cds.yaml"
    "migration/resourcetransformations.txt"
    "migration/resourcetransformations.yaml"
    "migration/actions.txt"
    "migration/actions.yaml"
  )

   kubevirt_commands=(
    "get kubevirts -A"
    "get kubevirts -A -o yaml"
    "get virtualmachines -A"
    "get virtualmachines -A -o yaml"
    "get virtualmachineinstances -A"
    "get virtualmachineinstances -A -o yaml"
    "get hyperconvergeds -A"
    "get hyperconvergeds -A -o yaml"
    "get cdiconfigs"
    "get cdiconfigs -o yaml"
    "get cdis"
    "get cdis -o yaml"
    "get datavolumes -A"
    "get datavolumes -A -o yaml"
    "describe datavolumes -A"
    "get storageprofiles"
    "get storageprofiles -o yaml"
    "get migrations.forklift.konveyor.io -A"
    "get migrations.forklift.konveyor.io -A -o yaml"
    "get virtualmachinerestore -A"
    "get virtualmachinerestore -A -o yaml"
    "describe virtualmachinerestore -A"
    "get pods -l kubevirt.io=virt-launcher -A"
    "get pods -l kubevirt.io=virt-launcher -A -o yaml"
    "get virtualmachineinstancemigration -A"
    "get virtualmachineinstancemigration -A -o yaml"
    "get storagemaps -A"
    "get storagemaps -A -o yaml"
    "get networkmaps -A"
    "get networkmaps -A -o yaml"
    "get providers -A"
    "get providers -A -o yaml"
    "get plans -A"
    "get plans -A -o yaml"
    "get ovirtvolumepopulators -A"
    "get ovirtvolumepopulators -A -o yaml"
    "get vspherexcopyvolumepopulators -A"
    "get vspherexcopyvolumepopulators -A -o yaml"
  )
  
   kubevirt_output=(
    "virtualization/platform/kubevirts_list.txt"
    "virtualization/platform/kubevirts.yaml"
    "virtualization/virtualmachines/virtualmachines.txt"
    "virtualization/virtualmachines/virtualmachines.yaml"
    "virtualization/virtualmachines/virtualmachineinstances.txt"
    "virtualization/virtualmachines/virtualmachineinstances.yaml"
    "virtualization/platform/hyperconvergeds.txt"
    "virtualization/platform/hyperconvergeds.yaml"
    "virtualization/platform/cdiconfigs.txt"
    "virtualization/platform/cdiconfigs.yaml"
    "virtualization/platform/cdis.txt"
    "virtualization/platform/cdis.yaml"
    "virtualization/storage/datavolumes.txt"
    "virtualization/storage/datavolumes.yaml"
    "virtualization/storage/datavolumes_desc.txt"
    "virtualization/storage/storageprofiles.txt"
    "virtualization/storage/storageprofiles.yaml"
    "virtualization/migration/migrations_list.txt"
    "virtualization/migration/migrations.yaml"
    "virtualization/restore/vmrestore.txt"
    "virtualization/restore/vmrestore.yaml"
    "virtualization/restore/vmrestore_desc.txt"
    "virtualization/virtualmachines/virt_launcher_pods.txt"
    "virtualization/virtualmachines/virt_launcher_pods.yaml"
    "virtualization/migration/vminstancemigration.txt"
    "virtualization/migration/vminstancemigration.yaml"
    "virtualization/forklift/storagemaps.txt"
    "virtualization/forklift/storagemaps.yaml"
    "virtualization/forklift/networkmaps.txt"
    "virtualization/forklift/networkmaps.yaml"
    "virtualization/forklift/providers.txt"
    "virtualization/forklift/providers.yaml"
    "virtualization/forklift/plans.txt"
    "virtualization/forklift/plans.yaml"
    "virtualization/forklift/ovirtvolumepopulators.txt"
    "virtualization/forklift/ovirtvolumepopulators.yaml"
    "virtualization/forklift/vspherexcopyvolumepopulators.txt"
    "virtualization/forklift/vspherexcopyvolumepopulators.yaml"
    
  )
  
logs_oth_ns=(
    "name=portworx-operator" #Some installations using PX Operator in different namespace than PXE installed
    "name=stork"
    "name=stork-scheduler"
    "kdmp.portworx.com/driver-name=kopiabackup"
    "kdmp.portworx.com/driver-name=nfsbackup"
)

#data masking or complex commands
data_masking_commands=(
    "$cli get secret px-pure-secret -n $namespace -o jsonpath='{.data.pure\\.json}' | base64 --decode | sed -E 's/\"APIToken\": *\"[^\"]*\"/\"APIToken\": \"*****Masked*****\"/'"
    "$cli get storagecluster -n $namespace -o yaml | awk '/ACCESS_KEY|SECRET_ACCESS/{p=1;print;next}p==1{sub(/value:.*/,\"value: \\\"****masked****\\\"\");p=0}1'"
    "$cli describe storagecluster -n $namespace | sed -E '/^[[:space:]]*Name:[[:space:]]*(.*ACCESS_KEY.*|.*SECRET_ACCESS.*)[[:space:]]*$/ { n; s/^([[:space:]]*Value:[[:space:]]*).*/\1"****masked****"/; }'"
    "$cli get cm -n $namespace -o name | grep telemetry | xargs -I {} $cli get {} -n $namespace -o yaml"
  )
  data_masking_output=(
    "portworx/px-pure-secret_masked.yaml"
    "portworx/px_stc.yaml"
    "portworx/px_stc_desc.txt"
    "portworx/px_telemetry_cm.yaml"

  )
 storkctl_resources=(
    "clusterpair"
    "migrations"
    "migrationschedules"
    "failover"
    "failback"
    "clusterdomainsstatus"
    "schedulepolicy"
    "applicationbackups"
    "applicationbackupschedules"
    "applicationbackupschedules"
    "applicationrestores"
    "backuplocation"
    "groupsnapshots"
    "volumesnapshots"
    "volumesnapshotschedules"
    "volumesnapshotrestore"
  )

#  main_dir="PX_${namespace}_k8s_diags_$(date +%Y%m%d_%H%M%S)"
#  output_dir="/tmp/${main_dir}"
#  sub_dir=(${output_dir}/logs ${output_dir}/logs/previous ${output_dir}/px_out ${output_dir}/k8s_px ${output_dir}/k8s_oth ${output_dir}/migration ${output_dir}/k8s_bkp ${output_dir}/k8s_pxb)
else
  commands=(
    "get pods -o wide -n $namespace"
    "get pods -o wide -n $namespace -o yaml"
    "describe pods -n $namespace"
    "get nodes -o wide -n $namespace"
    "get nodes -o wide -n $namespace -o yaml"
    "describe nodes -n $namespace"
    "get events -A -o wide --sort-by=.lastTimestamp"
    "get deploy -o wide -n $namespace"
    "get deploy -o wide -n $namespace -o yaml"
    "describe deploy -n $namespace"
    "get sts -o wide -n $namespace"
    "get sts -o wide -n $namespace -o yaml"
    "describe sts -n $namespace"
    "get csidrivers"
    "get csinodes"
    "get csinodes -o yaml"
    "get all -o wide -n $namespace"
    "get all -o wide -n $namespace -o yaml"
    "get configmaps -n $namespace"
    "describe namespace $namespace"
    "get namespace $namespace -o yaml"
    "get cm -o yaml -n $namespace"
    "get job,cronjobs -o wide -n $namespace --show-labels"
    "get job,cronjobs -n $namespace -o yaml"
    "describe job,cronjobs -n $namespace"
    "get applicationbackups -A"
    "get applicationbackups -A -o yaml"
    "get applicationbackupschedule -A"
    "get applicationbackupschedule -A -o yaml"
    "describe applicationbackupschedule -A"
    "get applicationrestores -A"
    "get applicationrestores -A -o yaml"
    "describe applicationrestores -A"
    "get applicationregistrations -A"
    "get applicationregistrations -A -o yaml"
    "get backuplocations -A"
    "get backuplocations -A -o yaml"
    "get volumesnapshots -A"
    "get volumesnapshots -A -o yaml"
    "get volumesnapshotcontents"
    "get volumesnapshotcontents -o yaml"
    "get volumesnapshotdatas -A"
    "get volumesnapshotdatas -A -o yaml"
    "get volumesnapshotschedules -A"
    "get volumesnapshotschedules -A -o yaml"
    "get volumesnapshotrestores -A"
    "get volumesnapshotrestores -A -o yaml"
    "get volumesnapshotclasses"
    "get volumesnapshotclasses -o yaml"
    "get schedulepolicies"
    "get schedulepolicies -o yaml"
    "get sc"
    "get sc -o yaml"
    "get pvc -A -o wide"
    "get pvc -A -o yaml"
    "get pv"
    "get pv -o yaml"
    "get controllerrevisions -n $namespace"
    "get controllerrevisions -n $namespace -o yaml"
    "get dataexports -A"
    "get prometheuses -A"
    "get prometheuses -A -o yaml"
    "get prometheusrules -A"
    "get prometheusrules -A -o yaml"
    "get alertmanagers -A"
    "get alertmanagers -A -o yaml" 
    "get alertmanagerconfigs -A"
    "get alertmanagerconfigs -A -o yaml" 
    "get servicemonitors -A"
    "get servicemonitors -A -o yaml"
    "get mutatingwebhookconfiguration"
    "get mutatingwebhookconfiguration -o yaml"
    "get cm kdmp-config -n kube-system -o yaml"
    "get backuplocationmaintenances -A"
    "get backuplocationmaintenances -A -o yaml"
    "get resourcebackups -A"
    "get resourcebackups -A -o yaml"
    "get resourceexports -A"
    "get resourceexports -A -o yaml"
    "get volumebackups -A"
    "get volumebackups -A -o yaml"
    "get volumebackupdeletes -A"
    "get volumebackupdeletes -A -o yaml"
    "get cm stork-controller-config -n kube-system -o yaml"
    "version"
    "api-resources -o wide"
    "get ns"
    "get ns -o yaml"
    "get secret -n $namespace --show-labels"
    "get pods -A -o wide"
    "get jobs -A -l kdmp.portworx.com/driver-name=kopiabackup --show-labels"
    "get jobs -A -l kdmp.portworx.com/driver-name=kopiabackup -o yaml"
    "get sa -o wide -n $namespace"
    "get sa -o yaml -n $namespace"
 )
 output_files=(
    "px_backup/pxb_pods.txt"
    "px_backup/pxb_pods.yaml"
    "px_backup/pxb_pods_desc.txt"
    "cluster/k8s_nodes.txt"
    "cluster/k8s_nodes.yaml"
    "cluster/k8s_nodes_desc.txt"
    "cluster/k8s_events_all.txt"
    "px_backup/pxb_deploy.txt"
    "px_backup/pxb_deploy.yaml"
    "px_backup/pxb_deploy_desc.txt"
    "px_backup/pxb_sts.txt"
    "px_backup/pxb_sts.yaml"
    "px_backup/pxb_sts_desc.txt"
    "storage/csidrivers.txt"
    "storage/csinodes.txt"
    "storage/csinodes.yaml"
    "px_backup/pxb_all.txt"
    "px_backup/pxb_all.yaml"
    "px_backup/pxb_cm.txt"
    "px_backup/pxb_ns_dec.txt"
    "px_backup/pxb_ns_dec.yaml"
    "px_backup/pxb_cm.yaml" 
    "px_backup/pxb_job_cronjob.txt"
    "px_backup/pxb_job_cronjob.yaml"
    "px_backup/pxb_job_cronjob_desc.txt"
    "backup/applicationbackups.txt"
    "backup/applicationbackups.yaml"
    "backup/applicationbackupschedules.txt"
    "backup/applicationbackupschedules.yaml"
    "backup/applicationbackupschedules_desc.txt"
    "backup/applicationrestores.txt"
    "backup/applicationrestores.yaml"
    "backup/applicationrestores_desc.txt"
    "backup/applicationregistrations.txt"
    "backup/applicationregistrations.yaml"
    "backup/backuplocations.txt"
    "backup/backuplocations.yaml"
    "backup/volumesnapshots.txt"
    "backup/volumesnapshots.yaml"
    "backup/volumesnapshotcontents.txt"
    "backup/volumesnapshotcontents.yaml"
    "backup/volumesnapshotdatas.txt"
    "backup/volumesnapshotdatas.yaml"
    "backup/volumesnapshotschedules.txt"
    "backup/volumesnapshotschedules.yaml"
    "backup/volumesnapshotrestores.txt"
    "backup/volumesnapshotrestores.yaml"
    "backup/volumesnapshotclasses.txt"
    "backup/volumesnapshotclasses.yaml"
    "backup/schedulepolicies.txt"
    "backup/schedulepolicies.yaml"
    "storage/sc.txt"
    "storage/sc.yaml"
    "storage/pvc_list.txt"
    "storage/pvc_all.yaml"
    "storage/pv_list.txt"
    "storage/pv_all.yaml"
    "px_backup/pxb_controllerrevisions.txt" 
    "px_backup/pxb_controllerrevisions.yaml" 
    "backup/dataexports.txt"
    "monitoring/prometheuses_list.txt"
    "monitoring/prometheuses.yaml"
    "monitoring/prometheuses_rules_list.txt"
    "monitoring/prometheuses_rules.yaml"
    "monitoring/alertmanagers_list.txt"
    "monitoring/alertmanagers.yaml"
    "monitoring/alertmanagerconfigs.txt"
    "monitoring/alertmanagerconfigs.yaml"
    "monitoring/servicemonitors.txt"
    "monitoring/servicemonitors.yaml"  
    "cluster_governance/mutatingwebhookconfiguration.txt"
    "cluster_governance/mutatingwebhookconfiguration.yaml"
    "px_backup/kdmp-config.yaml"
    "backup/kdmp/kdmp_backuplocationmaintenances.txt"
    "backup/kdmp/kdmp_backuplocationmaintenances.yaml"
    "backup/kdmp/kdmp_resourcebackups.txt"
    "backup/kdmp/kdmp_resourcebackups.yaml"
    "backup/kdmp/kdmp_resourceexports.txt"
    "backup/kdmp/kdmp_resourceexports.yaml"
    "backup/kdmp/kdmp_volumebackups.txt"
    "backup/kdmp/kdmp_volumebackups.yaml"
    "backup/kdmp/kdmp_volumebackupdeletes.txt"
    "backup/kdmp/kdmp_volumebackupdeletes.yaml"
    "px_backup/stork-controller-config.yaml"
    "cluster/k8s_version.txt"
    "cluster/k8s_api_resources.txt"
    "cluster/ns.txt"
    "cluster/ns.yaml"
    "px_backup/pxb_secret_list.txt"
    "cluster/pods_all.txt"
    "px_backup/kopia_backup_jobs.txt"
    "px_backup/kopia_backup_jobs.yaml"
    "px_backup/sa.txt"
    "px_backup/sa.yaml"
  )
log_labels=(
  ""
)
migration_commands=()
oth_commands=()
logs_oth_ns=(
    "name=stork"
    "kdmp.portworx.com/driver-name=kopiabackup"
    "kdmp.portworx.com/driver-name=nfsbackup"
)

#  main_dir="PX_Backup_${namespace}_k8s_diags_$(date +%Y%m%d_%H%M%S)"
#  output_dir="/tmp/${main_dir}"
# sub_dir=(${output_dir}/logs ${output_dir}/logs/previous ${output_dir}/k8s_pxb ${output_dir}/k8s_oth ${output_dir}/k8s_bkp)

fi

# Common extracts applicable for all 

  k8s_log_labels=(
    "component=kube-apiserver"
    "component=kube-scheduler"
    "component=etcd"
    "component=kube-controller-manager"
  )

# Array for common commands and their output files
common_commands_and_files=(
  "get resourcequota -A" "cluster_governance/resourcequota.txt"
  "get resourcequota -A -o yaml" "cluster_governance/resourcequota.yaml"
  "get limitrange -A" "cluster_governance/limitrange.txt"
  "get limitrange -A -o yaml" "cluster_governance/limitrange.yaml"
  "get leases -A" "cluster/leases.txt"
  "get leases -A -o yaml" "cluster/leases.yaml"
  "get apiservices" "cluster/apiservices.txt"
  "get networkpolicies -A -o wide" "cluster_governance/networkpolicies.txt"
  "get networkpolicies -A -o yaml" "cluster_governance/networkpolicies.yaml"
  "get backupjobs -A" "backup/ppdm_backupjobs_list.txt"
  "get backupjobs -A -o yaml" "backup/ppdm_backupjobs.yaml"
  "get backupstoragelocations -A" "backup/ppdm_backupstoragelocations_list.txt"
  "get deletebackupjobs -A" "backup/ppdm_deletebackupjobs_list.txt"
  "get deletebackupjobs -A -o yaml" "backup/ppdm_deletebackupjobs.yaml"
)

ocp_common_commands_and_files=(
  "get scc" "cluster_governance/ocp_scc.txt"
  "get scc -o yaml" "cluster_governance/ocp_scc.yaml"
  "describe scc" "cluster_governance/ocp_scc_describe.txt"
  )

ocp_px_commands_and_files=(  
  "get consoleplugins" "openshift/ocp_consoleplugins.txt"
  "get console.config" "openshift/ocp_console_config.txt"
  "get console.operator" "openshift/ocp_onsole_operator.txt"
  "get csv -n "$namespace"  " "openshift/px_ocp_csv.txt"
  "get consoleplugins -o yaml" "openshift/ocp_consoleplugins.yaml"
  "get console.config -o yaml" "openshift/ocp_console_config.yaml"
  "get console.operator -o yaml" "openshift/ocp_console_operator.yaml"
  "get csv -n "$namespace" -o yaml" "openshift/px_ocp_csv.yaml"
  "get operators -A -o wide" "openshift/oc_operators_list.txt"
  "get operators portworx-certified.portworx -o yaml" "openshift/oc_operators_portworx.yaml"
  )

pxb_mongo_export() {
  DB_PASS=$($cli -n "$namespace" get secret pxc-backup-mongodb --template='{{index .data "mongodb-root-password" | base64decode}}')

  # Helper to execute mongosh queries to keep the function DRY
  # Usage: run_query <collection_name> <projection_json>
  run_query() {
    local collection=$1
    local projection=${2:-"{}"}
    
    $cli exec -n "$namespace" pxc-backup-mongodb-2 -- \
      mongosh admin --username root --password "$DB_PASS" --quiet \
      --eval "const d = db.getSiblingDB('px-backup').${collection}.find({}, ${projection}).toArray(); print(JSON.stringify(d));"
  }
  ## 1. Backup Objects
  run_query "backupobjects" > "$output_dir/pxb_db_collections/pxb_backupobjects.json"

  ## 2. Backup Schedule Objects
  run_query "backupscheduleobjects" > "$output_dir/pxb_db_collections/pxb_backupscheduleobjects.json"

  ## 3. Cluster Objects (Excluding kubeconfig for security)
  run_query "clusterobjects" '{ "clusterInfo.kubeconfig": 0 }' > "$output_dir/pxb_db_collections/pxb_clusterobjects.json"

  ## 4. Backup Location Objects
  run_query "backuplocationobjects" > "$output_dir/pxb_db_collections/pxb_backuplocationobjects.json"

  ## 5. Schedule Policy Objects
  run_query "schedulepolicyobjects" > "$output_dir/pxb_db_collections/pxb_schedulepolicyobjects.json"

}

# Create a temporary directory for storing outputs
#mkdir -p "$output_dir"
#mkdir -p "${sub_dir[@]}"
#echo "$(date '+%Y-%m-%d %H:%M:%S'): Output will be stored in: $output_dir"
echo "$(date '+%Y-%m-%d %H:%M:%S'): Extraction is started"

#Generate Summary file with parameter and date information
summary_file=$output_dir/Summary.txt
log_info "Script version: $SCRIPT_VERSION"
log_info "k8s Cluster Name: $cluster_name"
log_info "Namespace: $namespace"
log_info "CLI tool: $cli"
log_info "option: $option"
if [[ "$option_defaulted" == "true" ]]; then
  log_info "-o option not passed, setting default option as PX. Pass -o PXB if you are looking to extract PXB diags"
fi
log_info "Security Enabled: ${sec_enabled:-false}"
log_info "Max px pod logs gather limited to: ${max_pods_logs:-NotSet}"
log_info "Extraction Started"


# Execute commands and save outputs to files
print_progress 1
for i in "${!commands[@]}"; do
  cmd="${commands[$i]}"
  output_file="$output_dir/${output_files[$i]}"
  #echo "Executing: $cli $cmd"
  $cli $cmd > "$output_file" 2>&1
  #echo "Output saved to: $output_file"
  #echo ""
  #echo "------------------------------------" 
done

   if [ "$sec_enabled" == "true" ]; then
     TOKEN_EXP="export PXCTL_AUTH_TOKEN=$($cli -n $namespace get secret px-admin-token --template='{{index .data "auth-token" | base64decode}}')"
     #echo "Security Enabled: true">>$summary_file
     #pxcmd="exec service/portworx-service -- bash -c \"\${TOKEN} && /opt/pwx/bin/pxctl"
     #pxcmd="exec service/portworx-service -- bash -c \"${TOKEN} && /opt/pwx/bin/pxctl"

  #else
     #echo "Security Enabled: false">>$summary_file
     #pxcmd="exec service/portworx-service -- \"/opt/pwx/bin/pxctl"
  fi

# Get top command output for node
if [[ "$cli" == "oc" ]]; then
  $cli adm top node > "$output_dir/cluster/top_nodes.txt" 2>&1
else
  $cli top node > "$output_dir/cluster/top_nodes.txt" 2>&1
fi

case "$OSTYPE" in
  msys*|cygwin*)
    export MSYS_NO_PATHCONV=1 # Avoid erroring the command in windows gitbash
    ;;
esac

# Execute pxctl commands 

extract_pxctl_op() {
for i in "${!pxctl_commands[@]}"; do
  cmd="${pxctl_commands[$i]}"
  output_file="$output_dir/${pxctl_output_files[$i]}"
  #echo "Executing: pxctl $cmd"
  #final_px_command="$pxcmd $cmd\""
  #echo $final_px_command
  if [ "$sec_enabled" == "true" ]; then
  $cli -n $namespace exec service/portworx-service -- bash -c "${TOKEN_EXP} && /opt/pwx/bin/pxctl $cmd" > "$output_file" 2>&1
  else
  $cli -n $namespace exec service/portworx-service -- bash -c "/opt/pwx/bin/pxctl $cmd" > "$output_file" 2>&1
  fi
  #$cli -n $namespace $final_px_command > "$output_file" 2>&1
  #echo "Output saved to: $output_file"
  #echo ""
  #echo "------------------------------------" 
done
}

if [[ "$PXCSIV3" == "true" ]]; then
  print_progress 2 skip
else
  print_progress 2
  extract_pxctl_op
fi
# Generating Logs
print_progress 3

#settig default value
pxc_max_pods_logs="${max_pods_logs:-200}"
pxe_max_pods_logs="${max_pods_logs:-5}"

# Define the labels you want to apply the log limit to
px_op_ds_labels=("name=portworx-api" "name=px-telemetry-phonehome" "name=portworx" "app.kubernetes.io/component=node-plugin" "app.kubernetes.io/component=telemetry-plugin" "name=px-pre-flight")
pxc_op_ds_limit_labels=("app.kubernetes.io/component=node-plugin")
pxe_op_ds_limit_labels=("name=portworx")

# Adding header for date check file
if [[ "$option" == "PX" ]]; then
echo "PX-POD-Status  - BASTION_HOST_TIME | POD_NAME | NODE_NAME | PX_POD_TIME" >> "${output_dir}/portworx/date_px_containers.out"
fi

for i in "${!log_labels[@]}"; do
  label="${log_labels[$i]}"
  log_count=0
  date_count=0

  # Get pods for current label
  if [[ "$option" == "PX" ]]; then
    PODS=($($cli get pods -n "$namespace" -l "$label" -o jsonpath="{.items[*].metadata.name}"))
  else
    PODS=($($cli get pods -n "$namespace" -o jsonpath="{.items[*].metadata.name}"))
  fi

  # Check if current label is in the px_op_ds_labels set
  if printf '%s\n' "${px_op_ds_labels[@]}" | grep -Fxq "$label"; then
    label_value=$(echo "$label" | awk -F '=' '{print $2}')
    not_ready_pods=()
    ready_pods=()
    #check if it sin in PXCSI limit set and assign pxc_max_pods_logs or default 200
    if [[ " ${label} " =~ " ${pxc_op_ds_limit_labels[@]} " ]]; then
        max_logs=$pxc_max_pods_logs
    #check if it sin in PX-E limit set and assign pxe_max_pods_logs or default 5
    elif [[ " ${label} " =~ " ${pxe_op_ds_limit_labels[@]} " ]]; then
        max_logs=$pxe_max_pods_logs
    else
        max_logs=5
    fi

    # Separate pods by container readiness
    for POD in "${PODS[@]}"; do
      if is_container_creating "$namespace" "$POD"; then
        continue
      fi
      ready_statuses=$($cli get pod -n "$namespace" "$POD" -o custom-columns="READY:.status.containerStatuses[*].ready" --no-headers)
      if echo "$ready_statuses" | grep -q "false"; then
        not_ready_pods+=("$POD")
      else
        ready_pods+=("$POD")
      fi
    done

    # Prioritize logs from not-ready pods
    for POD in "${not_ready_pods[@]}"; do
      if [[ $log_count -ge $max_logs ]]; then break; fi
      NODE_NAME=$($cli get pods -n "$namespace" "$POD" -o jsonpath='{.spec.nodeName}')
      mkdir -p ${output_dir}/logs/${label_value}/
      LOG_FILE="${output_dir}/logs/${label_value}/${NODE_NAME}.log"
      $cli logs -n "$namespace" "$POD" --tail -1 --all-containers > "$LOG_FILE"
      ((log_count++))
    done

    # Fill remaining with ready pods
    for POD in "${ready_pods[@]}"; do
      if [[ $log_count -ge $max_logs ]]; then break; fi
      NODE_NAME=$($cli get pods -n "$namespace" "$POD" -o jsonpath='{.spec.nodeName}')
      mkdir -p ${output_dir}/logs/${label_value}/
      LOG_FILE="${output_dir}/logs/${label_value}/${NODE_NAME}.log"
      $cli logs -n "$namespace" "$POD" --tail -1 --all-containers > "$LOG_FILE"
      ((log_count++))
    done

    # Getting date output from few pods
    if [[ ${label_value} == portworx ]]; then
          for POD in "${not_ready_pods[@]}"; do
            if [[ $date_count -ge 2 ]]; then break; fi
            NODE_NAME=$($cli get pods -n "$namespace" "$POD" -o jsonpath='{.spec.nodeName}')
            BASTION_TIME=$(date "+%Y-%m-%d %H:%M:%S")
            POD_TIME=$($cli exec -n "$namespace" "$POD" -- date "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            echo "[NOT-READY-POD] - $BASTION_TIME | $POD | $NODE_NAME | $POD_TIME" >> "${output_dir}/portworx/date_px_containers.out"
            ((date_count++))
          done

            for POD in "${ready_pods[@]}"; do
            if [[ $date_count -ge 5 ]]; then break; fi
            NODE_NAME=$($cli get pods -n "$namespace" "$POD" -o jsonpath='{.spec.nodeName}')
            BASTION_TIME=$(date "+%Y-%m-%d %H:%M:%S")
            POD_TIME=$($cli exec -n "$namespace" "$POD" -- date "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
            echo "[READY-POD]    - $BASTION_TIME | $POD | $NODE_NAME | $POD_TIME" >> "${output_dir}/portworx/date_px_containers.out"
            ((date_count++))
          done
      fi

  else
    # No limit: dump logs for all matching pods
    for POD in "${PODS[@]}"; do
      if is_container_creating "$namespace" "$POD"; then
        continue
      fi
      LOG_FILE="${output_dir}/logs/${POD}.log"
      $cli logs -n "$namespace" "$POD" --tail -1 --all-containers > "$LOG_FILE"
    done
  fi

done

# Collect coordinator portworx pod logs (PX, non-PXCSIV3)
if [[ "$option" == "PX" && "$PXCSIV3" != "true" ]]; then
  pxctl_status_file="${output_dir}/portworx/pxctl_out/pxctl_status.json"
  coord_node=$(get_coordinator_node "$pxctl_status_file")
  if [[ -n "$coord_node" && "$coord_node" != "null" ]]; then
    existing_log="${output_dir}/logs/portworx/${coord_node}.log"
    coord_log="${output_dir}/logs/portworx/coordinator_${coord_node}.log"
    if [[ -s "$existing_log" ]]; then
      mv "$existing_log" "$coord_log"
    else
      coord_pod=$($cli get pods -n "$namespace" -l name=portworx --field-selector spec.nodeName="$coord_node" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
      if [[ -n "$coord_pod" ]] && ! is_container_creating "$namespace" "$coord_pod"; then
        $cli logs -n "$namespace" "$coord_pod" --tail -1 --all-containers > "$coord_log"
      fi
    fi
  fi
fi

print_progress 4

for i in "${!k8s_log_labels[@]}"; do
  label="${k8s_log_labels[$i]}"
  PODS=$($cli get pods -n kube-system -l $label -o jsonpath="{.items[*].metadata.name}")
  for POD in $PODS; do
  if is_container_creating "kube-system" "$POD"; then
    continue
  fi
  LOG_FILE="${output_dir}/logs/kube_components/${POD}.log"
  #echo "Fetching logs for pod: $POD"
  # Fetch logs and write to file
  $cli logs -n kube-system "$POD" --tail -1 --all-containers > "$LOG_FILE"
  done
  #echo "Logs for pod $POD written to: $LOG_FILE"
done

#execute only if is OpenShift cluster to get kube-api server logs
if $cli api-versions | grep -q 'openshift'; then
  mkdir -p ${output_dir}/logs/ocp/
  OCP_KUBEAPI_PODS=$($cli get pods -n openshift-kube-apiserver -l apiserver=true -o jsonpath="{.items[*].metadata.name}")
  for OCP_KUBEAPI_PODS in $OCP_KUBEAPI_PODS; do
  if is_container_creating "openshift-kube-apiserver" "$POD"; then
    continue
  fi
  LOG_FILE="${output_dir}/logs/ocp/${OCP_KUBEAPI_PODS}.log"
  $cli logs -n openshift-kube-apiserver "$OCP_KUBEAPI_PODS" --tail -1 --all-containers > "$LOG_FILE"
  done

  OCP_ETCD_PODS=$($cli get pods -n openshift-etcd -l app=etcd -o jsonpath="{.items[*].metadata.name}")
  if is_container_creating "openshift-etcd" "$POD"; then
    continue
  fi
  for OCP_ETCD_PODS in $OCP_ETCD_PODS; do
  LOG_FILE="${output_dir}/logs/ocp/${OCP_ETCD_PODS}.log"
  $cli logs -n openshift-etcd "$OCP_ETCD_PODS" --tail -1 --all-containers > "$LOG_FILE"
  done

  if [[ "$option" == "PX" ]]; then
    {
    PODS=$($cli get pods -n openshift-console-operator -l name=console-operator -o jsonpath="{.items[*].metadata.name}")
    for POD in $PODS; do
    if is_container_creating "openshift-console-operator" "$POD"; then
      continue
    fi
    LOG_FILE="${output_dir}/logs/${POD}.log"
    $cli logs -n openshift-console-operator "$POD" --tail -1 --all-containers > "$LOG_FILE"
    done

    PODS=$($cli get pods -n openshift-console -l component=ui -o jsonpath="{.items[*].metadata.name}")
    for POD in $PODS; do
    if is_container_creating "openshift-console" "$POD"; then
      continue
    fi
    LOG_FILE="${output_dir}/logs/${POD}.log"
    $cli logs -n openshift-console "$POD" --tail -1 --all-containers > "$LOG_FILE"
    done
    }
  fi
fi

# Execute other commands 
#print_progress 5



#Check if kubevirt is enabled and get kubevirt configs only if kubevirt is enabled
print_progress 5

if $cli get crd | grep -q "virtualmachines.kubevirt.io"; then
  #echo "KubeVirt is likely enabled."
  mkdir -p $output_dir/virtualization/platform $output_dir/virtualization/virtualmachines $output_dir/virtualization/storage $output_dir/virtualization/migration $output_dir/virtualization/restore $output_dir/virtualization/forklift
  for i in "${!kubevirt_commands[@]}"; do
    cmd="${kubevirt_commands[$i]}"
    output_file="$output_dir/${kubevirt_output[$i]}"
    $cli $cmd > "$output_file" 2>&1
  done
fi


#Execute log extractions from other namespaces

print_progress 6

for i in "${!logs_oth_ns[@]}"; do
  label="${logs_oth_ns[$i]}"
  $cli get pods -A -l $label -o jsonpath="{range .items[*]}{.metadata.namespace}{' '}{.metadata.name}{' '}{.status.containerStatuses[*].restartCount}{'\n'}{end}"|
  while read -r namespace pod restartcount; do  
  if [[ -n "$namespace" && -n "$pod" ]]; then
        if is_container_creating "$namespace" "$pod"; then
          continue
        fi
        LOG_FILE="${output_dir}/logs/${pod}.log"
        LOG_FILE_PREV="${output_dir}/logs/previous/${pod}_prev.log"
        if [[ "$option" == "PXB" ]]; then
        POD_YAML_FILE="${output_dir}/px_backup/${pod}.yaml"
        else
        POD_YAML_FILE="${output_dir}/portworx/workloads/${pod}.yaml"
        fi
        #echo "Saving logs for Pod: $pod (Namespace: $namespace)"
        $cli logs -n "$namespace" "$pod" --tail -1 --all-containers > "$LOG_FILE"
        $cli -n "$namespace" get pod "$pod" -o yaml > "$POD_YAML_FILE"
        if [[ "$restartcount" > 0 ]]; then         
          if [[ "$label" == "name=portworx-operator" || "$label" == "name=stork" || "$label" == "name=stork-scheduler" ]]; then
            $cli logs -n "$namespace" "$pod" --tail -1 --all-containers  -p 2>/dev/null > "$LOG_FILE_PREV"
          fi
        fi
  fi
  
  done
done

#Execute Migration commands

extract_oth_commands_op() {

for i in "${!oth_commands[@]}"; do
  cmd="${oth_commands[$i]}"
  output_file="$output_dir/${oth_output_files[$i]}"
  #echo "Executing:  $cmd"
  $cmd > "$output_file" 2>&1
  #echo "Output saved to: $output_file"
  #echo ""
  #echo "------------------------------------" 
done
}

#print_progress 8
extract_migration_op() {
for i in "${!migration_commands[@]}"; do
  cmd="${migration_commands[$i]}"
  output_file="$output_dir/${migration_output[$i]}"
  #echo "Executing: $cli $cmd"
  $cli $cmd > "$output_file" 2>&1
  #echo "Output saved to: $output_file"
  #echo ""
  #echo "------------------------------------" 
done
}

#Execute masked data extractions

nslookup_purity_ips() {
    local target_file=$1
    local output_file="$output_dir/portworx/purity_backend_dns_names.txt"
    # Initialize/Overwrite file with the header (Silent in terminal)
    {
        echo "Backend - MgmtEndPoint - DNS Name"
        echo "--------------------------------------------------"
    } > "$output_file"
    
    if [[ -z "$target_file" || ! -f "$target_file" ]]; then
        return 0
    fi
    
    local keys=$(jq -r 'keys[]' "$target_file" 2>/dev/null)
    
    if [[ -n "$keys" ]]; then
        for key in $keys; do
            if [[ "$key" == "FlashArrays" || "$key" == "FlashBlades" ]]; then
                local ips=$(jq -r ".$key[].MgmtEndPoint" "$target_file" 2>/dev/null)

                if [[ "$PXCSIV3" == "true" ]]; then
                  exec_rs="ds/px-pure-csi-node -c node-plugin"
                else
                  exec_rs="svc/stork-service"
                fi

                if [[ -n "$ips" && "$ips" != "null" ]]; then
                    for ip in $ips; do
                        # Execute lookup and append result directly to output_file
                        hostname=$( $cli -n "$namespace" exec $exec_rs -- python3 -c "import socket; print(socket.gethostbyaddr('$ip')[0])" 2>/dev/null)

                        echo "$key - $ip - ${hostname:-'Could not be retrived'}" >> "$output_file"
                    done
                fi
            fi
        done
    fi
}

extract_masked_data() {
for i in "${!data_masking_commands[@]}"; do
  cmd="${data_masking_commands[$i]}"
  output_file="$output_dir/${data_masking_output[$i]}"
  eval "$cmd" > "$output_file" 2>&1
  if [[ ${data_masking_output[$i]} == "portworx/px-pure-secret_masked.yaml" ]]; then
    nslookup_purity_ips "$output_file"
  fi
done
}

# Function to extract common commands and save outputs
extract_common_commands_op() {
  #echo "$(date '+%Y-%m-%d %H:%M:%S'): Extracting common commands..."
  for ((i=0; i<${#common_commands_and_files[@]}; i+=2)); do
    cmd="${common_commands_and_files[i]}"
    output_file="$output_dir/${common_commands_and_files[i+1]}"
    #echo ">>> Running: kubectl $cmd > $file"
    $cli $cmd > "$output_file" 2>&1
  done
}

extract_ocp_specific_commands_op() {
  #echo "$(date '+%Y-%m-%d %H:%M:%S'): Extracting common commands..."
  for ((i=0; i<${#ocp_common_commands_and_files[@]}; i+=2)); do
    cmd="${ocp_common_commands_and_files[i]}"
    output_file="$output_dir/${ocp_common_commands_and_files[i+1]}"
    #echo ">>> Running: kubectl $cmd > $file"
    $cli $cmd > "$output_file" 2>&1
  done

  if [[ "$option" == "PX" ]]; then
    for ((i=0; i<${#ocp_px_commands_and_files[@]}; i+=2)); do
      cmd="${ocp_px_commands_and_files[i]}"
      output_file="$output_dir/${ocp_px_commands_and_files[i+1]}"
      #echo ">>> Running: kubectl $cmd > $file"
      $cli $cmd > "$output_file" 2>&1
    done
  fi

  extract_ocp_scc_details
}

# Collect additional SCC details for OpenShift troubleshooting
extract_ocp_scc_details() {
  local pod_scc_ns="$output_dir/cluster_governance/ocp_pod_scc_${namespace}.txt"
  local pod_scc_ks="$output_dir/cluster_governance/ocp_pod_scc_kube_system.txt"
  local sa_scc_map="$output_dir/cluster_governance/ocp_sa_scc_map_${namespace}.txt"

  # Pod -> SCC annotation mapping for the install namespace
  {
    printf "%-60s %-30s %s\n" "POD" "SERVICEACCOUNT" "SCC"
    $cli get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}' 2>/dev/null \
      | awk -F'\t' 'NF{ printf "%-60s %-30s %s\n", $1, ($2==""?"-":$2), ($3==""?"-":$3) }'
  } > "$pod_scc_ns" 2>&1

  # Pod -> SCC annotation mapping for kube-system (Stork, Autopilot, etc.)
  {
    printf "%-60s %-30s %s\n" "POD" "SERVICEACCOUNT" "SCC"
    $cli get pods -n kube-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\n"}{end}' 2>/dev/null \
      | awk -F'\t' 'NF{ printf "%-60s %-30s %s\n", $1, ($2==""?"-":$2), ($3==""?"-":$3) }'
  } > "$pod_scc_ks" 2>&1

  # SCC -> service accounts from the install namespace that are listed under .users
  {
    printf "%-40s %s\n" "SCC" "SERVICEACCOUNTS (from namespace ${namespace})"
    local sccs
    sccs=$($cli get scc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for scc in $sccs; do
      local users
      users=$($cli get scc "$scc" -o jsonpath='{.users[*]}' 2>/dev/null \
        | tr ' ' '\n' \
        | grep "system:serviceaccount:${namespace}:" \
        | sed "s|system:serviceaccount:${namespace}:||g" \
        | paste -sd "," -)
      printf "%-40s %s\n" "$scc" "${users:--}"
    done
  } > "$sa_scc_map" 2>&1
}

# Extract storkctl get output of stork managed objects to have better list representation than kubectl get

extract_storkctl_op() {
    local resource
    for resource in "${storkctl_resources[@]}"; do
        # Build output file path
        local output_file="$output_dir/storkctl_out/storkctl_${resource}.txt"

        # Run the CLI command and redirect output
       #$cli -n $namespace exec  get "$resource" --all-namespaces > "$output_file"
       $cli -n $namespace exec service/stork-service -- bash -c "/storkctl/linux/storkctl get "$resource" --all-namespaces" > "$output_file" 2>&1
    done
}

# Generate Cluster_Overview.txt summarising the cluster by parsing files
# $option: PXE (PX, non CSIv3), PXCSI (PX, CSIv3), PXB (PX Backup).
generate_cluster_overview() {
  local stc="$output_dir/portworx/px_stc.yaml"
  local pxctl_status="$output_dir/portworx/pxctl_out/pxctl_status.txt"
  local k8s_version_file="$output_dir/cluster/k8s_version.txt"
  local k8s_nodes_file="$output_dir/cluster/k8s_nodes.txt"
  local deploy_file="$output_dir/portworx/workloads/px_deploy.yaml"
  local pure_secret="$output_dir/portworx/px-pure-secret_masked.yaml"
  local pxb_pods_file="$output_dir/px_backup/pxb_pods.yaml"
  local overview_file="$output_dir/Cluster_Overview.txt"
  local NA="N/A"

  # Mode discrimination
  local mode="PXE"
  if [[ "$option" == "PXB" ]]; then
    mode="PXB"
  elif [[ "$option" == "PX" && "$PXCSIV3" == "true" ]]; then
    mode="PXCSI"
  fi

  # Cluster Identity
  local cluster_id="" cluster_uuid=""
  if [[ "$mode" == "PXCSI" && -f "$stc" ]]; then
    cluster_id=$(awk '
      /^  metadata:/ {f=1; next}
      f && /^  [a-zA-Z]/ {f=0; exit}
      f && /^    name:/ {sub(/.*name:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}
    ' "$stc")
    cluster_uuid=$(awk '
      /^  status:/ {f=1; next}
      f && /^  [a-zA-Z]/ {f=0; exit}
      f && /^    clusterUid:/ {sub(/.*clusterUid:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}
    ' "$stc")
  elif [[ "$mode" == "PXE" ]]; then
    if [[ -f "$pxctl_status" ]]; then
      cluster_id=$(awk -F: '/Cluster ID:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$pxctl_status")
      cluster_uuid=$(awk -F: '/Cluster UUID:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$pxctl_status")
    fi
    if [[ -z "$cluster_uuid" && -f "$stc" ]]; then
      cluster_uuid=$(awk '{l=$0; sub(/^[[:space:]]+/,"",l)} index(l,"clusterUid: ")==1 {v=substr(l,13); sub(/[[:space:]]+$/,"",v); print v; exit}' "$stc")
    fi
  fi

  # PX Version (for PXE/PXCSI) or PXB Version (px-backup deployment image)
  local px_version="" pxb_version=""
  if [[ "$mode" == "PXB" ]]; then
    if [[ -f "$pxb_pods_file" ]]; then
      pxb_version=$(awk '/image:[[:space:]]+.*\/px-backup:/ {sub(/.*\/px-backup:/,""); sub(/[[:space:]]+$/,""); print; exit}' "$pxb_pods_file")
    fi
  else
    [[ -f "$stc" ]] && px_version=$(awk '/^    version: / {sub(/.*version: /,""); print; exit}' "$stc")
  fi

  # PX Operator Version
  local operator_version=""
  if [[ -f "$stc" ]]; then
    operator_version=$(awk '{l=$0; sub(/^[[:space:]]+/,"",l)} index(l,"operatorVersion: ")==1 {v=substr(l,18); sub(/[[:space:]]+$/,"",v); print v; exit}' "$stc")
  fi
  if [[ -z "$operator_version" ]]; then
    local f
    for f in "$output_dir"/portworx/workloads/portworx-operator-*.yaml; do
      [[ -f "$f" ]] || continue
      operator_version=$(awk '/image: .*px-operator:/ {sub(/.*px-operator:/,""); print; exit}' "$f")
      [[ -n "$operator_version" ]] && break
    done
  fi

  # Stork Version (PXE: stork deployment/pod yaml under portworx/workloads;
  # PXB: stork pod yaml under px_backup; PXCSI: not applicable)
  local stork_version=""
  if [[ "$mode" == "PXE" ]]; then
    if [[ -f "$deploy_file" ]]; then
      stork_version=$(awk '/image:[[:space:]]+.*\/stork:/ {sub(/.*\/stork:/,""); sub(/[[:space:]]+$/,""); print; exit}' "$deploy_file")
    fi
    if [[ -z "$stork_version" ]]; then
      local sf
      for sf in "$output_dir"/portworx/workloads/stork-[0-9a-f]*.yaml \
                "$output_dir"/portworx/workloads/stork-[!s]*.yaml; do
        [[ -f "$sf" ]] || continue
        stork_version=$(awk '/image:[[:space:]]+.*\/stork:/ {sub(/.*\/stork:/,""); sub(/[[:space:]]+$/,""); print; exit}' "$sf")
        [[ -n "$stork_version" ]] && break
      done
    fi
  elif [[ "$mode" == "PXB" ]]; then
    local sf
    for sf in "$output_dir"/px_backup/stork-[0-9a-f]*.yaml \
              "$output_dir"/px_backup/stork-[!s]*.yaml; do
      [[ -f "$sf" ]] || continue
      stork_version=$(awk '/image:[[:space:]]+.*\/stork:/ {sub(/.*\/stork:/,""); sub(/[[:space:]]+$/,""); print; exit}' "$sf")
      [[ -n "$stork_version" ]] && break
    done
  fi

  # Autopilot Version (from autopilot deployment image)
  local autopilot_version=""
  if [[ -f "$deploy_file" ]]; then
    autopilot_version=$(awk '/image:[[:space:]]+.*\/autopilot:/ {sub(/.*\/autopilot:/,""); sub(/[[:space:]]+$/,""); print; exit}' "$deploy_file")
  fi

  # StorageCluster Status (phase, runtime state, latest condition + time)
  local stc_phase="" stc_runtime="" stc_last_msg="" stc_last_time=""
  if [[ -f "$stc" ]]; then
    stc_phase=$(awk '{l=$0; sub(/^[[:space:]]+/,"",l)} index(l,"phase: ")==1 {v=substr(l,8); sub(/[[:space:]]+$/,"",v); print v; exit}' "$stc")
    stc_runtime=$(awk '
      /^    conditions:/ {flag=1; next}
      flag && /^    [a-zA-Z]/ {flag=0; exit}
      flag && /^    - / {status=""; next}
      flag && /^      status:/ {sub(/.*status: */,""); sub(/[[:space:]]+$/,""); status=$0; next}
      flag && /^      type:[[:space:]]+RuntimeState/ {print status; exit}
    ' "$stc")
    stc_last_msg=$(awk '
      /^    conditions:/ {flag=1; next}
      flag && /^    [a-zA-Z]/ {flag=0; exit}
      flag && /^      message:/ {sub(/.*message: */,""); gsub(/^"|"$/,""); print; exit}
    ' "$stc")
    stc_last_time=$(awk '
      /^    conditions:/ {flag=1; next}
      flag && /^    [a-zA-Z]/ {flag=0; exit}
      flag && /^    - lastTransitionTime:/ {sub(/.*lastTransitionTime:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}
    ' "$stc")
  fi

  # K8s Version + Distro
  local k8s_version="" k8s_distro="Vanilla"
  [[ -f "$k8s_version_file" ]] && k8s_version=$(awk -F': ' '/Server Version:/ {print $2; exit}' "$k8s_version_file")
  case "$k8s_version" in
    *+rke2*) k8s_distro="RKE2" ;;
    *+k3s*)  k8s_distro="K3s"  ;;
    *-eks-*) k8s_distro="EKS"  ;;
    *-gke.*) k8s_distro="GKE"  ;;
    *-aks*)  k8s_distro="AKS"  ;;
  esac
  if [[ -d "$output_dir/openshift" ]] && ls "$output_dir/openshift"/* >/dev/null 2>&1; then
    k8s_distro="OpenShift"
  fi

  # Nodes
  local k8s_nodes_total=0 k8s_nodes_unhealthy=0 storage_nodes="$NA"
  local worker_os="" worker_kernel=""
  if [[ -f "$k8s_nodes_file" ]]; then
    k8s_nodes_total=$(awk 'NR>1 && NF>0' "$k8s_nodes_file" | wc -l | tr -d ' ')
    k8s_nodes_unhealthy=$(awk 'NR>1 && NF>0 && $2!="Ready"' "$k8s_nodes_file" | wc -l | tr -d ' ')
    worker_os=$(awk 'NR>1 && $3 ~ /worker/ {out=""; for(i=8;i<=NF-2;i++) out=out (out?" ":"") $i; print out}' \
                 "$k8s_nodes_file" | sort -u | paste -sd ", " -)
    worker_kernel=$(awk 'NR>1 && $3 ~ /worker/ {print $(NF-1)}' "$k8s_nodes_file" | sort -u | paste -sd ", " -)
    if [[ -z "$worker_os" ]]; then
      worker_os=$(awk 'NR>1 {out=""; for(i=8;i<=NF-2;i++) out=out (out?" ":"") $i; print out}' \
                   "$k8s_nodes_file" | sort -u | paste -sd ", " -)
      worker_kernel=$(awk 'NR>1 {print $(NF-1)}' "$k8s_nodes_file" | sort -u | paste -sd ", " -)
    fi
  fi
  if [[ "$mode" == "PXCSI" ]]; then
    local px_pods_file="$output_dir/portworx/workloads/px_pods.txt"
    if [[ -f "$px_pods_file" ]]; then
      storage_nodes=$(awk 'NR>1 && $1 ~ /^px-pure-csi-node/ {print $7}' "$px_pods_file" | sort -u | grep -c '.' | tr -d ' ')
    fi
  elif [[ -f "$pxctl_status" ]]; then
    storage_nodes=$(awk -F: '/Total Nodes:/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}' "$pxctl_status")
  fi

  # License status (PXCSI is hardcoded; PXE reads from pxctl status)
  local license_status="$NA"
  if [[ "$mode" == "PXCSI" ]]; then
    license_status="PX CSI for FA/FB"
  elif [[ -f "$pxctl_status" ]]; then
    license_status=$(awk '/^License:/ {sub(/^License:[[:space:]]*/,""); print; exit}' "$pxctl_status")
  fi

  # PX Volume and Snapshot counts
  # PXE: derived from pxctl outputs
  # PXCSI: derived from purevolumes.txt / puresnapshots.txt
  local vol_count="$NA" snap_count="$NA"
  local vol_list="$output_dir/portworx/pxctl_out/pxctl_volume_list.txt"
  local snap_list="$output_dir/portworx/pxctl_out/pxctl_volume_snapshot_list.txt"
  local pure_vol_file="$output_dir/portworx/px_csi/purevolumes.txt"
  local pure_snap_file="$output_dir/portworx/px_csi/puresnapshots.txt"
  if [[ "$mode" == "PXCSI" ]]; then
    if [[ -f "$pure_vol_file" ]]; then
      vol_count=$(awk '
        NR>1 && NF>=5 { bt[$4]++; total++ }
        END {
          if (total==0) { print "0"; exit }
          out=""
          for (k in bt) out = out (out?", ":"") k ": " bt[k]
          printf "%d (%s)\n", total, out
        }
      ' "$pure_vol_file")
    fi
    if [[ -f "$pure_snap_file" ]]; then
      snap_count=$(awk 'NR>1 && NF>=3 {c++} END {print c+0}' "$pure_snap_file")
    fi
  else
    if [[ -f "$vol_list" ]]; then
      vol_count=$(awk 'NR>1 && NF>0 {c++} END {print c+0}' "$vol_list")
    fi
    if [[ -f "$snap_list" ]]; then
      snap_count=$(awk 'NR>1 && NF>0 {c++} END {print c+0}' "$snap_list")
    fi
  fi

  # HA=1 volume count: data volumes only (excludes proxy / direct-access volumes)
  # pxctl volume list -v columns (whitespace-split): $1=ID $2=NAME $3=size_val $4=size_unit
  #   $5=HA $6=SHARED $7=ENCRYPTED $8=PROXY-VOLUME $9=IO_PRIORITY $10+...=STATUS $NF=SNAP-ENABLED
  local ha1_vol_count=0
  if [[ -f "$vol_list" ]]; then
    ha1_vol_count=$(awk 'NR>1 && NF>0 && $5=="1" && $8=="no" {c++} END {print c+0}' "$vol_list")
  fi

  # Telemetry
  local telemetry_raw="" telemetry="$NA"
  if [[ -f "$stc" ]]; then
    telemetry_raw=$(awk '
      /^      telemetry:/ {flag=1; next}
      flag && /^      [a-zA-Z]/ {flag=0}
      flag && /^        enabled:/ {print $2; exit}
    ' "$stc")
    case "$telemetry_raw" in
      true)  telemetry="Enabled"  ;;
      *) telemetry="Disabled" ;;
    esac
  fi

  # Storage Type and Cloud Provider
  local storage_type="$NA" cloud_provider="$NA"
  if [[ -f "$stc" ]]; then
    if grep -qE "^    cloudStorage:" "$stc"; then
      storage_type="Cloud"
      cloud_provider=$(awk '
        /^    cloudStorage:/ {flag=1; next}
        flag && /^    [a-zA-Z]/ {flag=0}
        flag && /^      provider:/ {sub(/.*provider: */,""); print; exit}
      ' "$stc")
      [[ -z "$cloud_provider" ]] && cloud_provider="$NA"
    elif grep -qE "^    storage:" "$stc"; then
      storage_type="Local"
    fi
  fi

  # Storage Backend
  # PXE: StoreV1 vs StoreV2 (StoreV2 is opted-in via -T px-storev2 in the
  #      portworx.io/misc-args annotation on the StorageCluster)
  # PXCSI: FlashArrays / FlashBlades (or both) from px-pure-secret_masked.yaml
  local store_version="$NA" misc_args=""
  if [[ "$mode" == "PXCSI" ]]; then
    if [[ -f "$pure_secret" ]]; then
      store_version=$(awk '
        /"FlashArrays"[[:space:]]*:/ { fa = ($0 ~ /\[[[:space:]]*\]/ ? "empty" : "present") }
        /"FlashBlades"[[:space:]]*:/ { fb = ($0 ~ /\[[[:space:]]*\]/ ? "empty" : "present") }
        END {
          out=""
          if (fa=="present") out="FlashArrays"
          if (fb=="present") out=(out ? out", FlashBlades" : "FlashBlades")
          print (out ? out : "N/A")
        }
      ' "$pure_secret")
    fi
  elif [[ "$mode" == "PXE" ]]; then
    store_version="StoreV1"
    if [[ -f "$stc" ]]; then
      misc_args=$(awk '
        /^    annotations:/ {flag=1; next}
        flag && /^    [a-zA-Z]/ {flag=0; exit}
        flag && /^      portworx\.io\/misc-args:/ {sub(/.*misc-args:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}
      ' "$stc")
      if [[ "$misc_args" == *px-storev2* ]]; then
        store_version="StoreV2"
      fi
    fi
  fi

  # KVDB TLS
  local kvdb_tls="$NA" _raw=""
  if [[ -f "$stc" ]]; then
    _raw=$(awk '
      /^    kvdb:/ {flag=1; next}
      flag && /^    [a-zA-Z]/ {flag=0; exit}
      flag && /^      enableTLS:/ {sub(/.*enableTLS:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}
    ' "$stc")
    case "$_raw" in
      true)  kvdb_tls="Enabled"  ;;
      *) kvdb_tls="Disabled" ;;
    esac
  fi

  # PX Security
  local px_security="Disabled"
  if [[ -f "$stc" ]]; then
    _raw=$(awk '
      /^    security:/ {flag=1; next}
      flag && /^    [a-zA-Z]/ {flag=0; exit}
      flag && /^      enabled:/ {sub(/.*enabled:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}
    ' "$stc")
    case "$_raw" in
      true)  px_security="Enabled"  ;;
      *) px_security="Disabled" ;;
    esac
  fi

  # Autopilot enabled flag
  local autopilot_enabled="$NA"
  if [[ -f "$stc" ]]; then
    _raw=$(awk '
      /^    autopilot:/ {flag=1; next}
      flag && /^    [a-zA-Z]/ {flag=0; exit}
      flag && /^      enabled:/ {sub(/.*enabled:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}
    ' "$stc")
    case "$_raw" in
      true)  autopilot_enabled="Enabled"  ;;
      *) autopilot_enabled="Disabled" ;;
    esac
  fi

  # Stork webhook-controller arg
  local stork_webhook="$NA"
  if [[ -f "$stc" ]]; then
    _raw=$(awk '
      /^    stork:/ {sf=1; next}
      sf && /^    [a-zA-Z]/ {sf=0; exit}
      sf && /^      args:/ {af=1; next}
      sf && af && /^      [a-zA-Z]/ {af=0}
      sf && af && /^        webhook-controller:/ {sub(/.*webhook-controller:[[:space:]]*/,""); gsub(/^"|"$/,""); sub(/[[:space:]]+$/,""); print; exit}
    ' "$stc")
    case "$_raw" in
      true)  stork_webhook="Enabled"  ;;
      *) stork_webhook="Disabled" ;;
    esac
  fi

  # Custom Image Registry (indicates internal/airgapped-style registry)
  local custom_registry="$NA"
  [[ -f "$stc" ]] && custom_registry=$(awk '
    /^    customImageRegistry:/ {sub(/.*customImageRegistry:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}
  ' "$stc")
  [[ -z "$custom_registry" ]] && custom_registry="$NA"

  # Airgapped installation (px-versions ConfigMap listed in portworx/px_cm.txt)
  local airgapped="No"
  local px_cm_file="$output_dir/portworx/px_cm.txt"
  if [[ -f "$px_cm_file" ]] && grep -qE "^px-versions[[:space:]]" "$px_cm_file"; then
    airgapped="Yes (px-versions CM present)"
  fi

  # ---- Health Check variables ----

  # Pods health: any not-ready or non-Running pods (excluding Completed jobs).

  local px_pods_file
  if [[ "$mode" == "PXB" ]]; then
    px_pods_file="$output_dir/px_backup/pxb_pods.txt"
  else
    px_pods_file="$output_dir/portworx/workloads/px_pods.txt"
  fi
  local unhealthy_pods=()
  if [[ -f "$px_pods_file" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && unhealthy_pods+=("$line")
    done < <(awk 'NR>1 && NF>0 && $3 != "Completed" {
      split($2, r, "/")
      if (r[1] != r[2] || $3 != "Running") printf "%-45s READY=%-7s STATUS=%s\n", $1, $2, $3
    }' "$px_pods_file")
  fi

  # Disruption budget: check px-kvdb and px-storage PDBs from portworx/px_pdb.txt
  # Columns (whitespace-split): $1=NAME $2=MIN_AVAIL $3=MAX_UNAVAIL $4=ALLOWED_DISRUPTIONS $5=AGE
  # Flag any PDB where ALLOWED DISRUPTIONS is 0 or absent.
  local pdb_file="$output_dir/portworx/px_pdb.txt"
  local pdb_issues=()
  if [[ -f "$pdb_file" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && pdb_issues+=("$line")
    done < <(awk 'NR>1 && ($1=="px-kvdb" || $1=="px-storage") {
      if ($4 == "" || $4+0 <= 0)
        printf "%-15s (ALLOWED DISRUPTIONS=%s)\n", $1, ($4=="" ? "missing" : $4)
    }' "$pdb_file")
  fi

  # KVDB member health: any member with HEALTHY=false, plus count check (expected >= 3)
  local kvdb_members_file="$output_dir/portworx/pxctl_out/pxctl_kvdb_members.txt"
  local unhealthy_kvdb=()
  local kvdb_member_count=0
  if [[ -f "$kvdb_members_file" ]]; then
    kvdb_member_count=$(awk 'NR>2 && NF>0 {c++} END {print c+0}' "$kvdb_members_file")
    while IFS= read -r line; do
      [[ -n "$line" ]] && unhealthy_kvdb+=("$line")
    done < <(awk 'NR>2 && NF>0 && $5=="false" {print $1, "(HEALTHY=false)"}' "$kvdb_members_file")
  fi

  # PX Cluster State: check each node's Status and StorageStatus in pxctl_status.txt
  # Valid combinations: Online+Up | Online+"Up (This node)" | Online+"No Storage"
  local cluster_node_issues=()
  if [[ -f "$pxctl_status" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && cluster_node_issues+=("$line")
    done < <(awk '
      /^[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]/ {
        # Detect column shift: "Unavailable" replaces two-field "val unit" pairs
        if ($6 == "Unavailable") {
          status = $8; ss1 = $9; ss2 = $10
        } else {
          status = $10; ss1 = $11; ss2 = $12
        }
        if (ss1 == "No" && ss2 == "Storage") {
          storagestatus = "No Storage"
          valid = (status == "Online")
        } else if (ss1 == "Up") {
          storagestatus = (ss2 == "(This" ? "Up (This node)" : "Up")
          valid = (status == "Online")
        } else {
          storagestatus = ss1
          valid = 0
        }
        if (!valid)
          printf "%-35s  Status=%-10s  StorageStatus=%s\n", $3, status, storagestatus
      }
    ' "$pxctl_status")
  fi

  # Kernel version consistency across PX nodes (parsed from pxctl status node table)
  local mixed_kernels="No" kernel_list=""
  if [[ -f "$pxctl_status" ]]; then
    kernel_list=$(awk '
      /^[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]/ {
        for (i=1; i<=NF; i++) {
          if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]+$/ && i+1<=NF) {
            print $(i+1); break
          }
        }
      }
    ' "$pxctl_status" | sort -u)
    if [[ -n "$kernel_list" ]] && [[ $(echo "$kernel_list" | wc -l | tr -d ' ') -gt 1 ]]; then
      mixed_kernels="Yes"
    fi
  fi

  # Pending PVCs backed by a PX StorageClass
  local px_pvc_pending=()
  local sc_yaml="$output_dir/storage/sc.yaml"
  local pvc_list_file="$output_dir/storage/pvc_list.txt"
  if [[ -f "$sc_yaml" && -f "$pvc_list_file" ]]; then
    local px_sc_names
    px_sc_names=$(awk '
      /^- apiVersion:/ || /^apiVersion:/ {name=""}
      /^  name:/ {name=$2}
      /^  provisioner:[[:space:]]*(pxd\.portworx\.com|kubernetes\.io\/portworx-volume)/ {if (name) print name}
    ' "$sc_yaml")
    if [[ -n "$px_sc_names" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && px_pvc_pending+=("$line")
      done < <(awk -v px_scs="$px_sc_names" '
        BEGIN { n=split(px_scs, arr, "\n"); for (i=1;i<=n;i++) sc_map[arr[i]]=1 }
        NR>1 && $3=="Pending" && sc_map[$7] { print $1"/"$2, "("$7")" }
      ' "$pvc_list_file")
    fi
  fi

  # Update Strategy type
  local update_strategy_type="$NA"
  if [[ -f "$stc" ]]; then
    update_strategy_type=$(awk '
      /^    updateStrategy:/ {flag=1; next}
      flag && /^    [a-zA-Z]/ {flag=0; exit}
      flag && /^      type:/ {sub(/.*type:[[:space:]]*/,""); sub(/[[:space:]]+$/,""); print; exit}
    ' "$stc")
  fi

  # Usage: _sec "Section Name"  → "-- SECTION NAME --...--"


  _sec() {
  local title
  title=$(echo "$1" | tr '[:lower:]' '[:upper:]')
  local total=62
  local label=" ${title} "
  local label_len=${#label}
  local remaining=$(( total - label_len ))
  local left=$(( remaining / 2 ))
  local right=$(( remaining - left ))
  local left_bar="" right_bar="" i
  for ((i=0; i<left; i++));  do left_bar+="━"; done
  for ((i=0; i<right; i++)); do right_bar+="━"; done
  printf "\n%s%s%s\n" "$left_bar" "$label" "$right_bar"
}

  {
    echo "================================================================"
    echo "           Portworx Cluster Overview"
    echo "================================================================"
    printf "Generated:           %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "Diag Bundle:         %s\n" "$(basename "$output_dir")"
    printf "Generator Version:   %s\n" "$SCRIPT_VERSION"

    # Cluster Identity (skipped for PXB)
    if [[ "$mode" != "PXB" ]]; then
      _sec "Cluster Identity"
      printf "Cluster ID:          %s\n" "${cluster_id:-$NA}"
      printf "Cluster UUID:        %s\n" "${cluster_uuid:-$NA}"
      printf "License:             %s\n" "${license_status:-$NA}"
      [[ "$custom_registry" != "$NA" ]] && \
        printf "Image Registry:      Internal (%s)\n" "$custom_registry"
    fi

    _sec "Versions"
    if [[ "$mode" == "PXB" ]]; then
      printf "PXB Version:         %s\n" "${pxb_version:-$NA}"
    else
      printf "PX Version:          %s\n" "${px_version:-$NA}"
    fi
    if [[ "$mode" != "PXB" ]]; then
      printf "Operator Version:    %s\n" "${operator_version:-$NA}"
    fi

    if [[ "$mode" == "PXE" ]]; then
      printf "Stork Version:       %s\n" "${stork_version:-$NA}"
      printf "Autopilot Version:   %s\n" "${autopilot_version:-$NA}"
    elif [[ "$mode" == "PXB" && -n "$stork_version" ]]; then
      printf "Stork Version:       %s\n" "$stork_version"
    fi
    
    printf "K8s Version:         %s\n" "${k8s_version:-$NA}"
    printf "K8s Distro:          %s\n" "$k8s_distro"

    # StorageCluster Status (skipped for PXB)
    if [[ "$mode" != "PXB" ]]; then
      _sec "StorageCluster Status"
      printf "Phase:               %s\n" "${stc_phase:-$NA}"
      printf "Runtime State:       %s\n" "${stc_runtime:-$NA}"
      if [[ -n "$stc_last_msg" && -n "$stc_last_time" ]]; then
        printf "Last Condition:      %s (%s)\n" "$stc_last_msg" "$stc_last_time"
      else
        printf "Last Condition:      %s\n" "${stc_last_msg:-$NA}"
      fi
    fi

    _sec "Nodes"
    printf "Total k8s Nodes:     %s\n" "$k8s_nodes_total"
    printf "Unhealthy k8s Nodes: %s\n" "$k8s_nodes_unhealthy"
    
    if [[ "$mode" != "PXB" ]]; then
      printf "Portworx Nodes:      %s\n" "${storage_nodes:-$NA}"
    fi

    if [[ "$mode" == "PXE" ]]; then
      printf "Worker OS:           %s\n" "${worker_os:-$NA}"
      printf "Worker Kernel:       %s\n" "${worker_kernel:-$NA}"
    fi

    # Storage section (skipped entirely for PXB)
    if [[ "$mode" == "PXE" ]]; then
      _sec "Storage"
      printf "Storage Type:        %s\n" "$storage_type"
      printf "Cloud Provider:      %s\n" "$cloud_provider"
      printf "Storage Backend:     %s\n" "$store_version"
      printf "Total PX Volumes:    %s\n" "$vol_count"
      printf "Total PX Snapshots:  %s\n" "$snap_count"
    elif [[ "$mode" == "PXCSI" ]]; then
      _sec "Storage"
      printf "Storage Backend:     %s\n" "$store_version"
      printf "Total PX Volumes:    %s\n" "$vol_count"
      printf "Total PX Snapshots:  %s\n" "$snap_count"
    fi

    _sec "Features"
    if [[ "$mode" == "PXE" ]]; then
      printf "Telemetry:           %s\n" "$telemetry"
      printf "KVDB TLS:            %s\n" "$kvdb_tls"
      printf "PX Security:         %s\n" "$px_security"
      printf "Autopilot:           %s\n" "$autopilot_enabled"
      printf "Stork Webhook:       %s\n" "$stork_webhook"
    elif [[ "$mode" == "PXCSI" ]]; then
      printf "Telemetry:           %s\n" "$telemetry"
    fi
    printf "Airgapped:           %s\n" "$airgapped"

    # Health Checks (per-check mode gating). Pxctl-derived checks (cluster state,
    # PDB, KVDB members, kernel, HA-1) apply to PXE only. PXB and PXCSI omit
    # StorageCluster-based Update Strategy is suppressed for PXB.
    _sec "Health Checks"
    # PX Cluster State (PXE only)
    if [[ "$mode" == "PXE" ]]; then
      if [[ ${#cluster_node_issues[@]} -eq 0 ]]; then
        printf "%-22s [OK]   All nodes Online\n" "PX Cluster State:"
      else
        printf "%-22s [WARN] Node(s) in unexpected state:\n" "PX Cluster State:"
        for _n in "${cluster_node_issues[@]}"; do printf "  - %s\n" "$_n"; done
      fi
    fi
    # Pods (label differs per mode)
    local _pods_label="PX Pods:"
    [[ "$mode" == "PXB" ]] && _pods_label="PXB Pods:"
    if [[ ${#unhealthy_pods[@]} -eq 0 ]]; then
      printf "%-22s [OK]   All pods healthy\n" "$_pods_label"
    else
      printf "%-22s [WARN] Unhealthy pods detected:\n" "$_pods_label"
      for _p in "${unhealthy_pods[@]}"; do printf "  - %s\n" "$_p"; done
    fi
    # Disruption Budget (PXE only)
    if [[ "$mode" == "PXE" ]]; then
      if [[ ${#pdb_issues[@]} -eq 0 ]]; then
        printf "%-22s [OK]   px-kvdb and px-storage disruptions allowed\n" "Disruption Budget:"
      else
        printf "%-22s [WARN] Zero disruptions allowed:\n" "Disruption Budget:"
        for _i in "${pdb_issues[@]}"; do printf "  - %s\n" "$_i"; done
      fi
    fi
    # KVDB Members (PXE only)
    if [[ "$mode" == "PXE" ]]; then
      if [[ ${#unhealthy_kvdb[@]} -eq 0 && "$kvdb_member_count" -ge 3 ]]; then
        printf "%-22s [OK]   All %d members healthy\n" "KVDB Members:" "$kvdb_member_count"
      else
        printf "%-22s [WARN] Issues detected:\n" "KVDB Members:"
        [[ "$kvdb_member_count" -lt 3 ]] && \
          printf "  - Only %d member(s) found (expected >= 3)\n" "$kvdb_member_count"
        for _m in "${unhealthy_kvdb[@]}"; do printf "  - %s\n" "$_m"; done
      fi
    fi
    # Kernel Versions (PXE only)
    if [[ "$mode" == "PXE" ]]; then
      if [[ "$mixed_kernels" == "Yes" ]]; then
        printf "%-22s [WARN] Mixed kernel versions across PX nodes:\n" "Kernel Versions:"
        while IFS= read -r _k; do [[ -n "$_k" ]] && printf "  - %s\n" "$_k"; done <<< "$kernel_list"
      else
        _single_kernel=$(echo "$kernel_list" | head -1)
        printf "%-22s [OK]   Consistent (%s)\n" "Kernel Versions:" "${_single_kernel:-$NA}"
      fi
    fi
    # HA-1 Volumes (PXE only)
    if [[ "$mode" == "PXE" ]]; then
      if [[ "$ha1_vol_count" -gt 0 ]]; then
        printf "%-22s [WARN] %d volume(s) with HA=1 (single replica) detected\n" "HA-1 Volumes:" "$ha1_vol_count"
      else
        printf "%-22s [OK]   No single-replica volumes\n" "HA-1 Volumes:"
      fi
    fi
    # Pending PX PVCs (PXE + PXCSI; not PXB)
    if [[ "$mode" != "PXB" ]]; then
      if [[ ${#px_pvc_pending[@]} -eq 0 ]]; then
        printf "%-22s [OK]   None\n" "Pending PX PVCs:"
      else
        printf "%-22s [WARN] PX-backed PVCs stuck in Pending:\n" "Pending PX PVCs:"
        for _pvc in "${px_pvc_pending[@]}"; do printf "  - %s\n" "$_pvc"; done
      fi
    fi
    # Update Strategy (StorageCluster-based; PXE + PXCSI only)
    if [[ "$mode" != "PXB" ]]; then
      if [[ "$update_strategy_type" == "RollingUpdate" ]]; then
        printf "%-22s [OK]   RollingUpdate\n" "Update Strategy:"
      else
        printf "%-22s [WARN] Expected RollingUpdate, found: %s\n" "Update Strategy:" "${update_strategy_type:-$NA}"
      fi
    fi
    echo
    echo "================================================================"
  } > "$overview_file"
}



print_progress 7
extract_masked_data
if [[ "$option" == "PXB" ]]; then
  pxb_mongo_export
fi
print_progress 8
extract_common_commands_op
if $cli api-versions | grep -q 'openshift'; then
extract_ocp_specific_commands_op
fi


if [[ "$PXCSIV3" == "true" ]]; then
  print_progress 9 skip
  print_progress 10 skip
  print_progress 11 skip
else
  print_progress 9
  extract_oth_commands_op
  print_progress 10
  extract_migration_op
  print_progress 11
  extract_storkctl_op
fi
  print_progress 12
  generate_cluster_overview

echo "$(date '+%Y-%m-%d %H:%M:%S'): Extraction is completed"
log_info "Extraction is completed"

# Compress the output directory into a tar file
archive_file="${main_dir}.tar.gz"
parent_dir="$(dirname "$output_dir")"
#cd /tmp
cd "$parent_dir"
tar -czf "$archive_file" "$main_dir"
echo "************************************************************************************************"
echo ""
echo "$(date '+%Y-%m-%d %H:%M:%S'): Diagnostic bundle created at: $parent_dir/$archive_file"
echo ""
echo "************************************************************************************************"

# Delete the temporary op directory 
if [[ -d "$output_dir" ]]; then
  rm -rf "$output_dir"
  echo ""
else
  echo ""
fi

#Uploads to FTPS if FTPS credentails are provided with -u username and -p password

if [[ -n "$ftpsuser" && -n "$ftpspass" ]]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S'): FTPS credentials are provided as Argument. Uploading to FTPS directly"

  ftpshost_base="ftps.purestorage.com"
  ftps_url_primary="ftps://$ftpshost_base/"
  ftps_url_fallback="https://$ftpshost_base/"  

  echo "$(date '+%Y-%m-%d %H:%M:%S'): Trying FTPS upload method to $ftps_url_primary"
  curl --progress-bar -S -u "$ftpsuser:$ftpspass" -T "$parent_dir/$archive_file" "$ftps_url_primary"
  if [[ $? -eq 0 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Successfully uploaded to FTPS - $ftps_url_primary"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S'): FTPS upload failed to $ftps_url_primary. Trying fallback method..."

    ftps_connection_response=$(curl -Is "$ftps_url_fallback" -u "$ftpsuser:$ftpspass" -o /dev/null -w "%{http_code}\n")

    if [[ "$ftps_connection_response" -eq 200 ]]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S'): FTPS connection successful to $ftps_url_fallback."
      echo "$(date '+%Y-%m-%d %H:%M:%S'): Trying FTPS upload method to $ftps_url_fallback..."
      curl --progress-bar --ftp-ssl -u "$ftpsuser:$ftpspass" -T "$parent_dir/$archive_file" "$ftps_url_fallback" -o /dev/null
      if [[ $? -eq 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Successfully uploaded to FTPS - $ftps_url_fallback"
      else
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Error: Problem in upload to "$ftps_url_fallback". Upload failed/partial"
      fi
    elif [[ "$ftps_connection_response" -eq 401 ]]; then
      echo "$(date '+%Y-%m-%d %H:%M:%S'): FTPS connection successful, but credentials look incorrect. Please get updated credentials or upload the generated log file manually over case."
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S'): FTPS fallback connection check failed. Please provide the output file: $parent_dir/$archive_file over case"
    fi
  fi
fi

echo "$(date '+%Y-%m-%d %H:%M:%S'): Script execution completed successfully."
