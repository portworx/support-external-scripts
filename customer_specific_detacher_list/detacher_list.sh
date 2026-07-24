#!/bin/bash
# px-detach-released-pvs.sh
# Detaches Released Portworx PVs after verifying:
#   1. RelaxedReclaim is enabled
#   2. NBDD (Node Block Device Delete) is enabled cluster-wide and on all pools
# Supports PX Security (px-admin-token) when enabled on the StorageCluster.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration defaults (overridable via flags or env)
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-portworx}"
SLEEP_BETWEEN=10
PX_BIN="/opt/pwx/bin/pxctl"
PX_SVC="service/portworx-service"
cli=""
TOKEN_EXP=""

# Temp files — cleaned up on exit
TMPDIR_WORK=$(mktemp -d)
STC_YAML="${TMPDIR_WORK}/stc.yaml"
CLUSTER_OPTS_JSON="${TMPDIR_WORK}/cluster_opts.json"
trap 'rm -rf "${TMPDIR_WORK}"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info()       { log "INFO  $*"; }
warn()       { log "WARN  $*"; }
err()        { log "ERROR $*" >&2; }
print_info() { info "$*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [-n namespace] [-c cli_tool]
  -n  Kubernetes namespace where Portworx runs  (default: portworx)
  -c  CLI tool to use: 'oc' or 'kubectl'        (auto-detected if omitted)
  -h  Show this help
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while getopts "n:c:h" opt; do
  case $opt in
    n) NAMESPACE=$(echo "$OPTARG" | tr '[:upper:]' '[:lower:]') ;;
    c) cli="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

# ---------------------------------------------------------------------------
# CLI validation / auto-detection
# ---------------------------------------------------------------------------
validate_and_derive_k8s_cli() {

  if [[ -n "$cli" ]]; then
    print_info "CLI passed as '$cli', validating..."

    if [[ "$cli" != "oc" && "$cli" != "kubectl" ]]; then
      err "Invalid k8s CLI '$cli'. Choose either 'oc' or 'kubectl'."
      exit 1
    fi

    if ! command -v "$cli" &>/dev/null; then
      err "'$cli' command not found. Ensure it is installed and in PATH."
      exit 1
    fi

    if ! $cli get namespaces &>/dev/null; then
      err "'$cli' is present but cannot reach the cluster. Check your kubeconfig/permissions."
      exit 1
    fi

    print_info "Using CLI: $cli"
    return
  fi

  print_info "No CLI specified — detecting automatically..."

  local kubectl_ok=false
  local oc_ok=false

  if command -v kubectl &>/dev/null && kubectl version --request-timeout=5s &>/dev/null; then
    kubectl_ok=true
  fi

  if command -v oc &>/dev/null && oc version --request-timeout=5s &>/dev/null; then
    oc_ok=true
  fi

  if ! $kubectl_ok && ! $oc_ok; then
    err "Neither 'kubectl' nor 'oc' can reach the cluster."
    exit 1
  fi

  if $kubectl_ok && ! $oc_ok; then
    cli="kubectl"
  elif ! $kubectl_ok && $oc_ok; then
    cli="oc"
  else
    if kubectl api-resources 2>/dev/null | grep -qi 'openshift'; then
      cli="oc"
    else
      cli="kubectl"
    fi
  fi

  print_info "Using CLI: $cli"
}

validate_and_derive_k8s_cli

# ---------------------------------------------------------------------------
# PX Security detection
# ---------------------------------------------------------------------------
info "Checking PX Security status in namespace '${NAMESPACE}'..."

sec_enabled="false"
sec_enabled=$(
  $cli -n "${NAMESPACE}" get stc \
    -o=jsonpath='{.items[0].spec.security.enabled}' 2>/dev/null
) || true

if [[ "$sec_enabled" == "true" ]]; then
  TOKEN_EXP="export PXCTL_AUTH_TOKEN=$(
    $cli -n "${NAMESPACE}" get secret px-admin-token \
      --template='{{index .data "auth-token" | base64decode}}'
  )"
  info "PX Security token retrieved successfully."
fi

# Builds the bash -c string, prepending the token export when security is on
pxctl_cmd() {
  if [[ "$sec_enabled" == "true" ]]; then
    echo "${TOKEN_EXP} && ${PX_BIN} $1"
  else
    echo "${PX_BIN} $1"
  fi
}

# ---------------------------------------------------------------------------
# Fetch STC YAML and cluster options JSON once — reused by both checks
# ---------------------------------------------------------------------------
info "Fetching StorageCluster YAML..."
$cli get stc -n "${NAMESPACE}" -o yaml > "${STC_YAML}" 2>/dev/null || true

info "Fetching cluster options (JSON)..."
$cli -n "${NAMESPACE}" exec ${PX_SVC} -- bash -c \
  "$(pxctl_cmd "cluster options list -j")" \
  > "${CLUSTER_OPTS_JSON}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 1: Verify RelaxedReclaim is "on"
# ---------------------------------------------------------------------------
info "Checking RelaxedReclaim setting in namespace '${NAMESPACE}'..."

RELAXED_RECLAIM_STATUS=$(
  $cli -n "${NAMESPACE}" exec ${PX_SVC} -- bash -c \
    "$(pxctl_cmd "cluster options list")" 2>&1 \
  | awk -F':' '/RelaxedReclaim/ { split($2, a, ","); gsub(/[[:space:]]/, "", a[1]); print tolower(a[1]); exit }'
) || true

if [[ -z "${RELAXED_RECLAIM_STATUS}" ]]; then
  err "Could not retrieve RelaxedReclaim status from '${PX_SVC}' in namespace '${NAMESPACE}'."
  err "Possible causes:"
  err "  - Namespace '${NAMESPACE}' is incorrect (use -n <namespace>)"
  err "  - Service '${PX_SVC}' does not exist or has no ready pods"
  err "  - '${PX_BIN}' is not present inside the container"
  err "  - Insufficient RBAC permissions to exec into the pod"
  err "  - PX Security is enabled but token could not be retrieved"
  err ""
  err "Verify manually:  $cli -n ${NAMESPACE} exec ${PX_SVC} -- bash -c '$(pxctl_cmd "cluster options list")'"
  exit 1
fi

info "RelaxedReclaim is currently: ${RELAXED_RECLAIM_STATUS}"

if [[ "${RELAXED_RECLAIM_STATUS}" != "on" ]]; then
  warn "RelaxedReclaim is NOT 'on' (found: '${RELAXED_RECLAIM_STATUS}'). Aborting detach."
  warn "Enable it first:  $cli -n ${NAMESPACE} exec ${PX_SVC} -- bash -c '$(pxctl_cmd "cluster options update --relaxed-reclaim on")'"
  #exit 1
fi

info "RelaxedReclaim is ON. Proceeding."

# ---------------------------------------------------------------------------
# Step 2: Verify NBDD is enabled cluster-wide and on all pool metrics
# ---------------------------------------------------------------------------
check_nbdd() {
  info "Checking NBDD (Node Block Device Delete) setting..."

  local nbdd_after="" nbdd_max=""

  # ── Prefer STC runtimeOptions ────────────────────────────────────────────
  if [[ -s "${STC_YAML}" ]]; then
    nbdd_after=$(awk '
      /^    runtimeOptions:/ { f=1; next }
      f && /^    [a-zA-Z]/   { f=0; exit }
      f && /^      device_delete_after_discard:/ {
        sub(/.*device_delete_after_discard:[[:space:]]*/,"")
        gsub(/["'"'"']/,""); sub(/[[:space:]]+$/,""); print; exit
      }
    ' "${STC_YAML}")

    nbdd_max=$(awk '
      /^    runtimeOptions:/ { f=1; next }
      f && /^    [a-zA-Z]/   { f=0; exit }
      f && /^      device_delete_max_concurrent:/ {
        sub(/.*device_delete_max_concurrent:[[:space:]]*/,"")
        gsub(/["'"'"']/,""); sub(/[[:space:]]+$/,""); print; exit
      }
    ' "${STC_YAML}")
  fi

  # ── Fallback: cluster options JSON ───────────────────────────────────────
  if [[ -z "$nbdd_after" && -s "${CLUSTER_OPTS_JSON}" ]]; then
    nbdd_after=$(awk -F: '
      /"device_delete_after_discard"/ { gsub(/[[:space:],"]/,"",$2); print $2; exit }
    ' "${CLUSTER_OPTS_JSON}")

    nbdd_max=$(awk -F: '
      /"device_delete_max_concurrent"/ { gsub(/[[:space:],"]/,"",$2); print $2; exit }
    ' "${CLUSTER_OPTS_JSON}")
  fi

  # ── Report cluster-level setting ─────────────────────────────────────────
  if [[ "$nbdd_after" == "1" ]]; then
    info "NBDD cluster setting : Enabled (device_delete_max_concurrent=${nbdd_max:-N/A})"
  else
    err "NBDD is NOT enabled (device_delete_after_discard='${nbdd_after:-unset}'). Aborting detach."
    err "Enable NBDD via StorageCluster runtimeOptions or:"
    err "  $cli -n ${NAMESPACE} exec ${PX_SVC} -- bash -c '$(pxctl_cmd "cluster options update --device-delete-after-discard 1")'"
    exit 1
  fi
}

check_nbdd

# ---------------------------------------------------------------------------
# Step 3: Get Released PVs matching the criteria
# ---------------------------------------------------------------------------
info "Fetching Released PVs (Delete policy)..."

mapfile -t PV_LIST < <(
  $cli get pv -o json | jq -r '
    .items[] |
    select(
      .status.phase == "Released" and
      .spec.persistentVolumeReclaimPolicy == "Delete" and
      .spec.csi.driver == "pxd.portworx.com"
    ) | .metadata.name
  '
)

if [[ ${#PV_LIST[@]} -eq 0 ]]; then
  info "No matching Released PVs found. Nothing to do."
  exit 0
fi

info "Found ${#PV_LIST[@]} PV(s) to detach:"
 
# Fetch pxctl volume list once and reuse for all PV lookups
info "Fetching pxctl volume list..."
PX_VOL_LIST=$(
  $cli -n "${NAMESPACE}" exec ${PX_SVC} -- bash -c \
    "$(pxctl_cmd "volume list")" 2>/dev/null
) || true
 
# Build a single egrep pattern from all PV names: pv1|pv2|pv3|...
EGREP_PATTERN=$(IFS='|'; echo "${PV_LIST[*]}")
 
echo ""
echo "Matching volumes from pxctl volume list:"
echo "${PX_VOL_LIST}" | egrep "${EGREP_PATTERN}" || warn "No matching volumes found in pxctl volume list."
echo ""

