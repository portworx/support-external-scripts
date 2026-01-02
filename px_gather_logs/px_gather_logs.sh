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
#       px_gather_logs.sh -n portworx -c kubectl -o PX
#   For PX Backup:
#       px_gather_logs.sh -n px-backup -c oc -o PXB
#
# - If no parameters are passed, the script will prompt for mandatory arguments input.
#
# ================================================================

SCRIPT_VERSION="25.12.5"


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
    local total_stages="11"
    local action=$2
    if [[ "$action" == "skip" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Skipping $current_stage/$total_stages..." | tee -a "$summary_file"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S'): Extracting $current_stage/$total_stages..." | tee -a "$summary_file"
    fi
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
if ! $cli cluster-info &> /dev/null; then
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


# Prompt for option if not provided
if [[ -z "$option" ]]; then
  read -p "Choose an option (PX/PXB) (Enter PX for Portworx Enterprise/CSI, Enter PXB for PX Backup): " option
  option=$(echo "$option" | tr '[:lower:]' '[:upper:]')
  if [[ "$option" != "PX" && "$option" != "PXB" ]]; then
    echo "Error: Invalid option. Choose either 'PX' or 'PXB'."
    exit 1
  fi
fi


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

if [[ "$option" == "PX" ]]; then
  if [[ "$PXCSIV3" == "true" ]]; then
     sub_dir=(${output_dir}/logs/previous ${output_dir}/k8s_px ${output_dir}/k8s_oth ${output_dir}/k8s_bkp ${output_dir}/k8s_pxb)
  else
     sub_dir=(${output_dir}/logs/previous ${output_dir}/px_out ${output_dir}/k8s_px ${output_dir}/k8s_oth ${output_dir}/migration ${output_dir}/k8s_bkp ${output_dir}/k8s_pxb ${output_dir}/storkctl_out)
  fi
else
  sub_dir=(${output_dir}/logs/previous ${output_dir}/k8s_pxb ${output_dir}/k8s_oth ${output_dir}/k8s_bkp)
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
    "get nodes -o wide -n $namespace"
    "get nodes -o wide -n $namespace -o yaml"
    "describe nodes -n $namespace"
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
    "get mutatingwebhookconfiguration"
    "get mutatingwebhookconfiguration -o yaml"
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
    "k8s_px/px_pods.txt"
    "k8s_px/px_pods.yaml"
    "k8s_px/px_pods_desc.txt"
    "k8s_oth/k8s_nodes.txt"
    "k8s_oth/k8s_nodes.yaml"
    "k8s_oth/k8s_nodes_desc.txt"
    "k8s_oth/k8s_events_all.txt"
    "k8s_px/px_deploy.txt"
    "k8s_px/px_deploy.yaml"
    "k8s_px/px_deploy_desc.txt"
    "k8s_oth/volumeattachments.txt"
    "k8s_oth/volumeattachments.yaml"
    "k8s_oth/csidrivers.txt"
    "k8s_oth/csinodes.txt"
    "k8s_oth/csinodes.yaml"
    "k8s_px/px_cm.txt"
    "k8s_px/px-versions_cm.yaml"
    "k8s_px/px_ns_dec.txt"
    "k8s_px/px_ns_dec.yaml"
    "k8s_px/px_secret_list.txt"
    "k8s_oth/sc.txt"
    "k8s_oth/sc.yaml"
    "k8s_oth/pvc_list.txt"
    "k8s_oth/pvc_all.yaml"
    "k8s_oth/pv_list.txt"
    "k8s_oth/pv_all.yaml"
    "k8s_px/px_storagenodes_list.txt"
    "k8s_oth/mutatingwebhookconfiguration.txt"
    "k8s_oth/mutatingwebhookconfiguration.yaml"
    "k8s_px/px_svc_ep.txt"
    "k8s_px/px_svc_ep.yaml"
    "k8s_px/px_ds.yaml"
    "k8s_px/px_pdb.txt"
    "k8s_px/px_pdb.yaml"
    "k8s_oth/pods_kube_system.txt"
    "k8s_oth/k8s_version.txt"
    "k8s_oth/k8s_api_resources.txt"
    "k8s_px/autopilotrules.txt"
    "k8s_px/autopilotrules.yaml"
    "k8s_px/autopilotruleobjects.txt"
    "k8s_px/autopilotruleobjects.yaml"
    "k8s_bkp/applicationbackups.txt"
    "k8s_bkp/applicationbackups.yaml"
    "k8s_bkp/applicationbackupschedules.txt"
    "k8s_bkp/applicationbackupschedules.yaml"
    "k8s_bkp/applicationbackupschedules_desc.txt"
    "k8s_bkp/applicationrestores.txt"
    "k8s_bkp/applicationrestores.yaml"
    "k8s_bkp/applicationrestores_desc.txt"
    "k8s_bkp/applicationregistrations.txt"
    "k8s_bkp/applicationregistrations.yaml"
    "k8s_bkp/backuplocations.txt"
    "k8s_bkp/backuplocations.yaml"
    "k8s_bkp/volumesnapshots.txt"
    "k8s_bkp/volumesnapshots.yaml"
    "k8s_bkp/volumesnapshotcontents.txt"
    "k8s_bkp/volumesnapshotcontents.yaml"
    "k8s_bkp/volumesnapshotdatas.txt"
    "k8s_bkp/volumesnapshotdatas.yaml"
    "k8s_bkp/volumesnapshotschedules.txt"
    "k8s_bkp/volumesnapshotschedules.yaml"
    "k8s_bkp/volumesnapshotrestores.txt"
    "k8s_bkp/volumesnapshotrestores.yaml"
    "k8s_bkp/volumesnapshotclasses.txt"
    "k8s_bkp/volumesnapshotclasses.yaml"
    "k8s_bkp/schedulepolicies.txt"
    "k8s_bkp/schedulepolicies.yaml"  
    "k8s_bkp/dataexports.txt"
    "k8s_bkp/dataexports.yaml"
    "k8s_oth/prometheuses_list.txt"
    "k8s_oth/prometheuses.yaml"
    "k8s_oth/prometheuses_rules_list.txt"
    "k8s_oth/prometheuses_rules.yaml"
    "k8s_oth/alertmanagers_list.txt"
    "k8s_oth/alertmanagers.yaml"
    "k8s_oth/alertmanagerconfigs.txt"
    "k8s_oth/alertmanagerconfigs.yaml"
    "k8s_oth/servicemonitors.txt"
    "k8s_oth/servicemonitors.yaml"  
    "k8s_oth/mutatingwebhookconfiguration.txt"
    "k8s_oth/mutatingwebhookconfiguration.yaml"
    "k8s_pxb/kdmp-config.yaml"
    "k8s_pxb/stork-controller-config.yaml"
    "k8s_bkp/px_rules.txt"
    "k8s_bkp/px_rules.yaml"
    "k8s_px/px_sharedv4_svc_ep.txt"
    "k8s_px/px_sharedv4_svc_ep.yaml"
    "k8s_oth/pods_all.txt"
    "k8s_bkp/volumebackups.txt"
    "k8s_bkp/volumebackups.yaml"
    "k8s_pxb/kopia_backup_jobs.txt"
    "k8s_pxb/kopia_backup_jobs.yaml"
    "k8s_bkp/groupvolumesnapshots.txt"
    "k8s_bkp/groupvolumesnapshots.yaml"
    "k8s_px/vps.txt"
    "k8s_px/vps.yaml"
    "k8s_px/componentk8sconfig.txt"
    "k8s_px/componentk8sconfig.yaml"
    "k8s_px/sa.txt"
    "k8s_px/sa.yaml"
    "k8s_px/purevolumes.txt"
    "k8s_px/purevolumes.yaml"
    "k8s_px/puresnapshots.txt"
    "k8s_px/puresnapshots.yaml"
    "k8s_px/storagenodeinitiators.txt"
    "k8s_px/storagenodeinitiators.yaml"
    "k8s_px/purestoragecluster.txt"
    "k8s_px/purestoragecluster.yaml"


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
    "px_out/pxctl_status.txt"
    "px_out/pxctl_status.json"
    "px_out/pxctl_cluster_provision_status.txt"
    "px_out/pxctl_license_list.txt"
    "px_out/pxctl_cluster_options.txt"
    "px_out/pxctl_cluster_options.json"
    "px_out/pxctl_kvdb_members.txt"
    "px_out/pxctl_alerts_show.txt"
    "px_out/pxctl_cs_status.txt"
    "px_out/pxctl_cs_status.json"
    "px_out/pxctl_cs_sched_list.txt"
    "px_out/pxctl_sched-policy.txt"
    "px_out/pxctl_cd_list.txt"
    "px_out/pxctl_cd_list.json"
    "px_out/pxctl_cred_list.txt"
    "px_out/pxctl_volume_list.txt"
    "px_out/pxctl_volume_list.json"
    "px_out/pxctl_volume_snapshot_list.txt"
    "px_out/pxctl_volume_snapshot_list.json"
    "px_out/pxctl_callhome_status.json"
    "px_out/pxctl_pool_drain_list.txt"
    "px_out/pxctl_pool_drain_list.json"
    "px_out/pxctl_pool_rebalance_list.txt"
    "px_out/pxctl_pool_rebalance_list.json"
    "px_out/pxctl_defrag_schedules.txt"
    "px_out/pxctl_defrag_schedules.json"
    "px_out/pxctl_defrag_status.txt"
    "px_out/pxctl_defrag_status.json"
    
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
    
  )


  
  oth_commands=(
    "$cli -n kube-system get cm $($cli -n kube-system get cm|grep px-bootstrap|awk '{print $1}') -o yaml"
    "$cli -n kube-system get cm $($cli -n kube-system get cm|grep px-bootstrap|awk '{print $1}') -o json"
    "$cli -n kube-system get cm $($cli -n kube-system get cm|grep px-cloud-drive|awk '{print $1}') -o yaml"
    "$cli -n kube-system get cm $($cli -n kube-system get cm|grep px-cloud-drive|awk '{print $1}') -o json"

  )
  oth_output_files=(
    "k8s_px/px-bootstrap.yaml"
    "k8s_px/px-bootstrap.json"
    "k8s_px/px-cloud-drive.yaml"
    "k8s_px/px-cloud-drive.json"

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
    
  )
  
   kubevirt_output=(
    "kubevirt/kubevirts_list.txt"
    "kubevirt/kubevirts.yaml"
    "kubevirt/kubevirt_virtualmachines.txt"
    "kubevirt/kubevirt_virtualmachines.yaml"
    "kubevirt/kubevirt_virtualmachineinstances.txt"
    "kubevirt/kubevirt_virtualmachineinstances.yaml"
    "kubevirt/kubevirt_hyperconvergeds.txt"
    "kubevirt/kubevirt_hyperconvergeds.yaml"
    "kubevirt/kubevirt_kubevirt_cdiconfigs.txt"
    "kubevirt/kubevirt_cdiconfigs.yaml"
    "kubevirt/kubevirt_cdis.txt"
    "kubevirt/kubevirt_cdis.yaml"
    "kubevirt/kubevirt_datavolumes.txt"
    "kubevirt/kubevirt_datavolumes.yaml"
    "kubevirt/kubevirt_datavolumes_desc.txt"
    "kubevirt/kubevirt_storageprofiles.txt"
    "kubevirt/kubevirt_storageprofiles.yaml"
    "kubevirt/kubevirt_migrations_list.txt"
    "kubevirt/kubevirt_migrations.yaml"
    "kubevirt/kubevirt_vmrestore.txt"
    "kubevirt/kubevirt_vmrestore.yaml"
    "kubevirt/kubevirt_vmrestore_desc.txt"
    "kubevirt/kubevirt_virt_launcher_pods.txt"
    "kubevirt/kubevirt_virt_launcher_pods.yaml"
    "kubevirt/kubevirt_vminstancemigration.txt"
    "kubevirt/kubevirt_vminstancemigration.yaml"
    
  )
  
logs_oth_ns=(
    "name=portworx-operator" #Some installations using PX Operator in different namespace than PXE installed
    "name=stork"
    "name=stork-scheduler"
    "kdmp.portworx.com/driver-name=kopiabackup"
    "kdmp.portworx.com/driver-name=nfsbackup"
)
data_masking_commands=(
    "$cli get secret px-pure-secret -n $namespace -o jsonpath='{.data.pure\\.json}' | base64 --decode | sed -E 's/\"APIToken\": *\"[^\"]*\"/\"APIToken\": \"*****Masked*****\"/'"
    "$cli get storagecluster -n $namespace -o yaml | awk '/ACCESS_KEY|SECRET_ACCESS/{p=1;print;next}p==1{sub(/value:.*/,\"value: \\\"****masked****\\\"\");p=0}1'"
    "$cli describe storagecluster -n $namespace | sed -E '/^[[:space:]]*Name:[[:space:]]*(.*ACCESS_KEY.*|.*SECRET_ACCESS.*)[[:space:]]*$/ { n; s/^([[:space:]]*Value:[[:space:]]*).*/\1"****masked****"/; }'"

  )
  data_masking_output=(
    "k8s_px/px-pure-secret_masked.yaml"
    "k8s_px/px_stc.yaml"
    "k8s_px/px_stc_desc.txt"

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
    "k8s_pxb/pxb_pods.txt"
    "k8s_pxb/pxb_pods.yaml"
    "k8s_pxb/pxb_pods_desc.txt"
    "k8s_oth/k8s_nodes.txt"
    "k8s_oth/k8s_nodes.yaml"
    "k8s_oth/k8s_nodes_desc.txt"
    "k8s_oth/k8s_events_all.txt"
    "k8s_pxb/pxb_deploy.txt"
    "k8s_pxb/pxb_deploy.yaml"
    "k8s_pxb/pxb_deploy_desc.txt"
    "k8s_pxb/pxb_sts.txt"
    "k8s_pxb/pxb_sts.yaml"
    "k8s_pxb/pxb_sts_desc.txt"
    "k8s_oth/csidrivers.txt"
    "k8s_oth/csinodes.txt"
    "k8s_oth/csinodes.yaml"
    "k8s_pxb/pxb_all.txt"
    "k8s_pxb/pxb_all.yaml"
    "k8s_pxb/pxb_cm.txt"
    "k8s_pxb/pxb_ns_dec.txt"
    "k8s_pxb/pxb_ns_dec.yaml"
    "k8s_pxb/pxb_cm.yaml" 
    "k8s_pxb/pxb_job_cronjob.txt"
    "k8s_pxb/pxb_job_cronjob.yaml"
    "k8s_pxb/pxb_job_cronjob_desc.txt"
    "k8s_bkp/applicationbackups.txt"
    "k8s_bkp/applicationbackups.yaml"
    "k8s_bkp/applicationbackupschedules.txt"
    "k8s_bkp/applicationbackupschedules.yaml"
    "k8s_bkp/applicationbackupschedules_desc.txt"
    "k8s_bkp/applicationrestores.txt"
    "k8s_bkp/applicationrestores.yaml"
    "k8s_bkp/applicationrestores_desc.txt"
    "k8s_bkp/applicationregistrations.txt"
    "k8s_bkp/applicationregistrations.yaml"
    "k8s_bkp/backuplocations.txt"
    "k8s_bkp/backuplocations.yaml"
    "k8s_bkp/volumesnapshots.txt"
    "k8s_bkp/volumesnapshots.yaml"
    "k8s_bkp/volumesnapshotcontents.txt"
    "k8s_bkp/volumesnapshotcontents.yaml"
    "k8s_bkp/volumesnapshotdatas.txt"
    "k8s_bkp/volumesnapshotdatas.yaml"
    "k8s_bkp/volumesnapshotschedules.txt"
    "k8s_bkp/volumesnapshotschedules.yaml"
    "k8s_bkp/volumesnapshotrestores.txt"
    "k8s_bkp/volumesnapshotrestores.yaml"
    "k8s_bkp/volumesnapshotclasses.txt"
    "k8s_bkp/volumesnapshotclasses.yaml"
    "k8s_bkp/schedulepolicies.txt"
    "k8s_bkp/schedulepolicies.yaml"
    "k8s_oth/sc.txt"
    "k8s_oth/sc.yaml"
    "k8s_oth/pvc_list.txt"
    "k8s_oth/pvc_all.yaml"
    "k8s_oth/pv_list.txt"
    "k8s_oth/pv_all.yaml"
    "k8s_bkp/dataexports.txt"
    "k8s_oth/prometheuses_list.txt"
    "k8s_oth/prometheuses.yaml"
    "k8s_oth/prometheuses_rules_list.txt"
    "k8s_oth/prometheuses_rules.yaml"
    "k8s_oth/alertmanagers_list.txt"
    "k8s_oth/alertmanagers.yaml"
    "k8s_oth/alertmanagerconfigs.txt"
    "k8s_oth/alertmanagerconfigs.yaml"
    "k8s_oth/servicemonitors.txt"
    "k8s_oth/servicemonitors.yaml"  
    "k8s_oth/mutatingwebhookconfiguration.txt"
    "k8s_oth/mutatingwebhookconfiguration.yaml"
    "k8s_pxb/kdmp-config.yaml"
    "k8s_bkp/kdmp_backuplocationmaintenances.txt"
    "k8s_bkp/kdmp_backuplocationmaintenances.yaml"
    "k8s_bkp/kdmp_resourcebackups.txt"
    "k8s_bkp/kdmp_resourcebackups.yaml"
    "k8s_bkp/kdmp_resourceexports.txt"
    "k8s_bkp/kdmp_resourceexports.yaml"
    "k8s_bkp/kdmp_volumebackups.txt"
    "k8s_bkp/kdmp_volumebackups.yaml"
    "k8s_bkp/kdmp_volumebackupdeletes.txt"
    "k8s_bkp/kdmp_volumebackupdeletes.yaml"
    "k8s_pxb/stork-controller-config.yaml"
    "k8s_oth/k8s_version.txt"
    "k8s_oth/k8s_api_resources.txt"
    "k8s_oth/ns.txt"
    "k8s_oth/ns.yaml"
    "k8s_pxb/pxb_secret_list.txt"
    "k8s_oth/pods_all.txt"
    "k8s_pxb/kopia_backup_jobs.txt"
    "k8s_pxb/kopia_backup_jobs.yaml"
    "k8s_pxb/sa.txt"
    "k8s_pxb/sa.yaml"
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
  "get resourcequota -A" "k8s_oth/resourcequota.txt"
  "get resourcequota -A -o yaml" "k8s_oth/resourcequota.yaml"
  "get limitrange -A" "k8s_oth/limitrange.txt"
  "get limitrange -A -o yaml" "k8s_oth/limitrange.yaml"
  "get leases -A" "k8s_oth/leases.txt"
  "get leases -A -o yaml" "k8s_oth/leases.yaml"
)

ocp_common_commands_and_files=(
  "get scc" "k8s_oth/ocp_scc.txt"
  "get scc -o yaml" "k8s_oth/ocp_scc.yaml"
  )

ocp_px_commands_and_files=(  
  "get consoleplugins" "k8s_oth/ocp_consoleplugins.txt"
  "get console.config" "k8s_oth/ocp_console_config.txt"
  "get console.operator" "k8s_oth/ocp_onsole_operator.txt"
  "get csv -n "$namespace"  " "k8s_px/px_ocp_csv.txt"
  "get consoleplugins -o yaml" "k8s_oth/ocp_consoleplugins.yaml"
  "get console.config -o yaml" "k8s_oth/ocp_console_config.yaml"
  "get console.operator -o yaml" "k8s_oth/ocp_console_operator.yaml"
  "get csv -n "$namespace" -o yaml" "k8s_px/px_ocp_csv.yaml"
  )

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
  $cli adm top node > "$output_dir/k8s_oth/top_nodes.txt" 2>&1
else
  $cli top node > "$output_dir/k8s_oth/top_nodes.txt" 2>&1
fi


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
px_op_ds_labels=("name=portworx-api" "name=px-telemetry-phonehome" "name=portworx" "app.kubernetes.io/component=node-plugin" "app.kubernetes.io/component=telemetry-plugin")
pxc_op_ds_limit_labels=("app.kubernetes.io/component=node-plugin")
pxe_op_ds_limit_labels=("name=portworx")

for i in "${!log_labels[@]}"; do
  label="${log_labels[$i]}"
  log_count=0

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

  else
    # No limit: dump logs for all matching pods
    for POD in "${PODS[@]}"; do
      LOG_FILE="${output_dir}/logs/${POD}.log"
      $cli logs -n "$namespace" "$POD" --tail -1 --all-containers > "$LOG_FILE"
    done
  fi

done



print_progress 4

for i in "${!k8s_log_labels[@]}"; do
  label="${k8s_log_labels[$i]}"
  PODS=$($cli get pods -n kube-system -l $label -o jsonpath="{.items[*].metadata.name}")
  for POD in $PODS; do
  LOG_FILE="${output_dir}/logs/${POD}.log"
  #echo "Fetching logs for pod: $POD"
  # Fetch logs and write to file
  $cli logs -n kube-system "$POD" --tail -1 --all-containers > "$LOG_FILE"
  done
  #echo "Logs for pod $POD written to: $LOG_FILE"
done

#execute only if is OpenShift cluster to get kube-api server logs
if $cli api-versions | grep -q 'openshift'; then
  PODS=$($cli get pods -n openshift-kube-apiserver -l apiserver=true -o jsonpath="{.items[*].metadata.name}")
  for POD in $PODS; do
  LOG_FILE="${output_dir}/logs/${POD}.log"
  $cli logs -n openshift-kube-apiserver "$POD" --tail -1 --all-containers > "$LOG_FILE"
  done

  if [[ "$option" == "PX" ]]; then
    {
    PODS=$($cli get pods -n openshift-console-operator -l name=console-operator -o jsonpath="{.items[*].metadata.name}")
    for POD in $PODS; do
    LOG_FILE="${output_dir}/logs/${POD}.log"
    $cli logs -n openshift-console-operator "$POD" --tail -1 --all-containers > "$LOG_FILE"
    done

    PODS=$($cli get pods -n openshift-console -l component=ui -o jsonpath="{.items[*].metadata.name}")
    for POD in $PODS; do
    LOG_FILE="${output_dir}/logs/${POD}.log"
    $cli logs -n openshift-console "$POD" --tail -1 --all-containers > "$LOG_FILE"
    done
    }
  fi
fi

# Execute other commands 
print_progress 5

for i in "${!oth_commands[@]}"; do
  cmd="${oth_commands[$i]}"
  output_file="$output_dir/${oth_output_files[$i]}"
  #echo "Executing:  $cmd"
  $cmd > "$output_file" 2>&1
  #echo "Output saved to: $output_file"
  #echo ""
  #echo "------------------------------------" 
done

#Check if kubevirt is enabled and get kubevirt configs only if kubevirt is enabled
print_progress 6

if $cli get crd | grep -q "virtualmachines.kubevirt.io"; then
  #echo "KubeVirt is likely enabled."
  mkdir -p $output_dir/kubevirt
  for i in "${!kubevirt_commands[@]}"; do
    cmd="${kubevirt_commands[$i]}"
    output_file="$output_dir/${kubevirt_output[$i]}"
    $cli $cmd > "$output_file" 2>&1
  done
fi


#Execute log extractions from other namespaces

print_progress 7

for i in "${!logs_oth_ns[@]}"; do
  label="${logs_oth_ns[$i]}"
  $cli get pods -A -l $label -o jsonpath="{range .items[*]}{.metadata.namespace}{' '}{.metadata.name}{' '}{.status.containerStatuses[*].restartCount}{'\n'}{end}"|
  while read -r namespace pod restartcount; do  
  if [[ -n "$namespace" && -n "$pod" ]]; then
        LOG_FILE="${output_dir}/logs/${pod}.log"
        LOG_FILE_PREV="${output_dir}/logs/previous/${pod}_prev.log"
        if [[ "$option" == "PXB" ]]; then
        POD_YAML_FILE="${output_dir}/k8s_pxb/${pod}.yaml"
        else
        POD_YAML_FILE="${output_dir}/k8s_px/${pod}.yaml"
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

extract_masked_data() {
for i in "${!data_masking_commands[@]}"; do
  cmd="${data_masking_commands[$i]}"
  output_file="$output_dir/${data_masking_output[$i]}"
  eval "$cmd" > "$output_file" 2>&1
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



print_progress 8
extract_masked_data
print_progress 9
extract_common_commands_op
if $cli api-versions | grep -q 'openshift'; then
extract_ocp_specific_commands_op
fi


if [[ "$PXCSIV3" == "true" ]]; then
  print_progress 10 skip
  print_progress 11 skip
else
  print_progress 10
  extract_migration_op
  print_progress 11
  extract_storkctl_op
fi

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
