#!/usr/bin/env bash
# gm_released_pv_detacher_v3.sh
#
# Detaches "Released" Portworx PVs after verifying safe cluster-side settings.
#
# Version-aware behaviour:
#   * PXE <  3.5.2 (e.g. 3.2.3): verify RelaxedReclaim only.  NBDD is skipped
#                                (feature introduced in 3.5.2).
#   * PXE >= 3.5.2 (e.g. 3.5.2): verify RelaxedReclaim AND NBDD.
#
# The PXE version is auto-detected from the StorageCluster (.spec.image or
# .status.version). It can be overridden with --px-version, or NBDD checks
# can be forced on/off with --check-nbdd / --skip-nbdd.
#
# This build assumes PX Security is NOT enabled (no auth token handling).
#
# Usage: see -h / --help
#
# Exit codes:
#   0  success (or dry-run success, or nothing to do)
#   1  usage / precondition failure
#   2  detach step had one or more failures
#   3  aborted by user

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration defaults (overridable via flags or env)
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-portworx}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-30}"
CLAIM_NAMESPACE="${CLAIM_NAMESPACE:-powerprotect}"
EXCLUDE_SC="${EXCLUDE_SC:-px-fada-rw}"
PX_BIN="${PX_BIN:-/opt/pwx/bin/pxctl}"
PX_SVC="${PX_SVC:-service/portworx-service}"
PX_VERSION_OVERRIDE="${PX_VERSION_OVERRIDE:-}"   # e.g. "3.2.3" or "3.5.2"
NBDD_MODE="auto"                                  # auto | always | never
DRY_RUN=false
ASSUME_YES=false
cli=""

# NBDD is only meaningful from this PXE version onward.
NBDD_MIN_VERSION="3.5.2"

# Temp files — cleaned up on exit
TMPDIR_WORK="$(mktemp -d)"
STC_YAML="${TMPDIR_WORK}/stc.yaml"
CLUSTER_OPTS_JSON="${TMPDIR_WORK}/cluster_opts.json"
cleanup() { rm -rf "${TMPDIR_WORK}"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Logging helpers (printf-based; safe with % in payloads)
# ---------------------------------------------------------------------------
_ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()   { printf '[%s] %s\n'  "$(_ts)" "$*"; }
info()  { printf '[%s] INFO  %s\n' "$(_ts)" "$*"; }
warn()  { printf '[%s] WARN  %s\n' "$(_ts)" "$*"; }
err()   { printf '[%s] ERROR %s\n' "$(_ts)" "$*" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -n, --namespace NS         Namespace where Portworx runs             (default: ${NAMESPACE})
      --claim-namespace NS   Only detach PVs bound to claims in this NS (default: ${CLAIM_NAMESPACE})
      --exclude-sc SC        Exclude PVs on this StorageClass          (default: ${EXCLUDE_SC})
  -c, --cli TOOL             CLI tool: 'oc' or 'kubectl' (auto-detected if omitted)
  -s, --sleep N              Seconds to wait between detaches          (default: ${SLEEP_BETWEEN})
      --px-bin PATH          pxctl binary path inside PX pod           (default: ${PX_BIN})
      --px-svc RES           Portworx service resource                 (default: ${PX_SVC})
      --px-version X.Y.Z     Override PXE version detection            (e.g. 3.2.3, 3.5.2)
      --check-nbdd           Force NBDD verification on
      --skip-nbdd            Force NBDD verification off
      --dry-run              Show what would happen; do nothing
  -y, --yes                  Non-interactive; accept all prompts (use with care)
  -h, --help                 Show this help

Behavior:
  * Auto-detects PXE version from the StorageCluster.
      - PXE <  ${NBDD_MIN_VERSION}: verifies RelaxedReclaim only (NBDD not applicable).
      - PXE >= ${NBDD_MIN_VERSION}: verifies RelaxedReclaim AND NBDD.
  * If a required check fails, aborts unless --yes is set (or user confirms).
  * Prompts for a final confirmation before detaching (skipped with --yes).
  * PX Security is assumed OFF; script errors out if it is enabled.

Environment overrides (same names as flags):
  NAMESPACE, SLEEP_BETWEEN, CLAIM_NAMESPACE, EXCLUDE_SC, PX_BIN, PX_SVC
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      [[ -n "${2:-}" ]] || { err "$1 requires a value"; exit 1; }
      NAMESPACE="$2"; shift 2 ;;
    --claim-namespace)
      [[ -n "${2:-}" ]] || { err "$1 requires a value"; exit 1; }
      CLAIM_NAMESPACE="$2"; shift 2 ;;
    --exclude-sc)
      [[ -n "${2:-}" ]] || { err "$1 requires a value"; exit 1; }
      EXCLUDE_SC="$2"; shift 2 ;;
    -c|--cli)
      [[ -n "${2:-}" ]] || { err "$1 requires a value"; exit 1; }
      cli="$2"; shift 2 ;;
    -s|--sleep)
      if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
        err "$1 requires a non-negative integer"; exit 1
      fi
      SLEEP_BETWEEN="$2"; shift 2 ;;
    --px-bin)
      [[ -n "${2:-}" ]] || { err "$1 requires a value"; exit 1; }
      PX_BIN="$2"; shift 2 ;;
    --px-svc)
      [[ -n "${2:-}" ]] || { err "$1 requires a value"; exit 1; }
      PX_SVC="$2"; shift 2 ;;
    --px-version)
      [[ -n "${2:-}" ]] || { err "$1 requires a value"; exit 1; }
      if [[ ! "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        err "--px-version must look like X.Y.Z (e.g. 3.2.3)"; exit 1
      fi
      PX_VERSION_OVERRIDE="$2"; shift 2 ;;
    --check-nbdd) NBDD_MODE="always"; shift ;;
    --skip-nbdd)  NBDD_MODE="never";  shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -y|--yes)   ASSUME_YES=true; shift ;;
    -h|--help)  usage; exit 0 ;;
    --)         shift; break ;;
    -*)         err "Unknown option: $1"; usage >&2; exit 1 ;;
    *)          err "Unexpected positional argument: $1"; usage >&2; exit 1 ;;
  esac
done

# Validate namespace format (RFC 1123 label)
if [[ ! "${NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  err "Invalid namespace '${NAMESPACE}' (must be lowercase RFC 1123 label)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Confirm helper
# ---------------------------------------------------------------------------
confirm_proceed() {
  local prompt_msg="$1"
  warn "--------------------------------------------------------------"
  warn "CAUTION: ${prompt_msg}"
  warn "Proceeding WITHOUT this setting may cause data inconsistency."
  warn "--------------------------------------------------------------"
  if [[ "${ASSUME_YES}" == "true" ]]; then
    warn "--yes supplied; proceeding without interactive confirmation."
    return 0
  fi
  if [[ ! -t 0 ]]; then
    err "Non-interactive shell and --yes not supplied. Aborting for safety."
    return 1
  fi
  local answer=""
  while true; do
    read -rp "Do you want to proceed anyway? [yes/no]: " answer
    answer="$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')"
    case "${answer}" in
      yes|y) return 0 ;;
      no|n)  return 1 ;;
      *)     echo "Please type 'yes' or 'no'." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Preflight: required binaries
# ---------------------------------------------------------------------------
require_bin() {
  command -v "$1" >/dev/null 2>&1 || { err "Required binary not found in PATH: $1"; exit 1; }
}
require_bin jq
require_bin awk
require_bin sed

# ---------------------------------------------------------------------------
# CLI detection / validation
# ---------------------------------------------------------------------------
validate_and_derive_k8s_cli() {
  if [[ -n "${cli}" ]]; then
    info "CLI passed as '${cli}', validating..."
    if [[ "${cli}" != "oc" && "${cli}" != "kubectl" ]]; then
      err "Invalid k8s CLI '${cli}'. Choose 'oc' or 'kubectl'."; exit 1
    fi
    require_bin "${cli}"
    if ! "${cli}" get namespaces >/dev/null 2>&1; then
      err "'${cli}' cannot reach the cluster. Check kubeconfig/permissions."; exit 1
    fi
    info "Using CLI: ${cli}"
    return
  fi
  info "No CLI specified — detecting automatically..."
  local kubectl_ok=false oc_ok=false
  if command -v kubectl >/dev/null 2>&1 && kubectl version --request-timeout=5s >/dev/null 2>&1; then
    kubectl_ok=true
  fi
  if command -v oc >/dev/null 2>&1 && oc version --request-timeout=5s >/dev/null 2>&1; then
    oc_ok=true
  fi
  if ! $kubectl_ok && ! $oc_ok; then
    err "Neither 'kubectl' nor 'oc' can reach the cluster."; exit 1
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
  info "Using CLI: ${cli}"
}
validate_and_derive_k8s_cli

if [[ "${DRY_RUN}" == "true" ]]; then
  warn "*** DRY-RUN MODE ENABLED — no detach commands will be executed ***"
fi
info "Namespace              : ${NAMESPACE}"
info "Claim namespace filter : ${CLAIM_NAMESPACE}"
info "Excluded StorageClass  : ${EXCLUDE_SC}"
info "Sleep between detaches : ${SLEEP_BETWEEN}s"

# ---------------------------------------------------------------------------
# StorageCluster sanity check + refuse to run if PX Security is enabled
# ---------------------------------------------------------------------------
info "Checking StorageCluster in namespace '${NAMESPACE}'..."
stc_count="$(${cli} -n "${NAMESPACE}" get stc -o json 2>/dev/null | jq '.items | length' 2>/dev/null || echo 0)"
if [[ "${stc_count}" == "0" ]]; then
  err "No StorageCluster found in namespace '${NAMESPACE}'. Check -n and permissions."; exit 1
fi
if [[ "${stc_count}" -gt 1 ]]; then
  warn "Multiple StorageClusters found in '${NAMESPACE}' (${stc_count}); using the first."
fi

sec_enabled="$(
  ${cli} -n "${NAMESPACE}" get stc \
    -o=jsonpath='{.items[0].spec.security.enabled}' 2>/dev/null || true
)"
if [[ "${sec_enabled}" == "true" ]]; then
  err "PX Security is ENABLED on this StorageCluster."
  err "This build of the script does not support PX Security (no token handling)."
  err "Use a security-aware build, or disable PX Security before running."
  exit 1
fi

# Build a bash -c payload for pxctl (no token).
pxctl_cmd() { printf '%s %s' "${PX_BIN}" "$1"; }

# ---------------------------------------------------------------------------
# PXE version detection
# ---------------------------------------------------------------------------
# Returns 0 iff $1 (semver X.Y.Z) is >= $2. Uses sort -V.
version_ge() {
  [[ "$1" == "$2" ]] && return 0
  local lower
  lower="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
  [[ "${lower}" == "$2" ]]
}

detect_px_version() {
  # Priority: explicit override -> STC .status.version -> STC .spec.image tag
  if [[ -n "${PX_VERSION_OVERRIDE}" ]]; then
    printf '%s' "${PX_VERSION_OVERRIDE}"
    return
  fi
  local v=""
  v="$(${cli} -n "${NAMESPACE}" get stc \
        -o=jsonpath='{.items[0].status.version}' 2>/dev/null || true)"
  if [[ -z "${v}" ]]; then
    local img
    img="$(${cli} -n "${NAMESPACE}" get stc \
          -o=jsonpath='{.items[0].spec.image}' 2>/dev/null || true)"
    # e.g. "portworx/oci-monitor:3.5.2" -> "3.5.2"
    v="${img##*:}"
  fi
  # Strip anything past the semver (build suffixes like "-rc1", "_openshift")
  if [[ "${v}" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' ""
  fi
}

info "Detecting PXE version..."
PX_VERSION="$(detect_px_version)"
if [[ -z "${PX_VERSION}" ]]; then
  warn "Could not detect PXE version from StorageCluster."
  warn "Pass --px-version X.Y.Z to override, or --check-nbdd / --skip-nbdd."
  if [[ "${NBDD_MODE}" == "auto" ]]; then
    err "NBDD mode is 'auto' but version is unknown. Refusing to guess."
    exit 1
  fi
else
  info "PXE version detected: ${PX_VERSION}"
fi

# Decide whether to check NBDD
case "${NBDD_MODE}" in
  always) DO_NBDD_CHECK=true;  info "NBDD check: forced ON  (--check-nbdd)" ;;
  never)  DO_NBDD_CHECK=false; info "NBDD check: forced OFF (--skip-nbdd)"  ;;
  auto)
    if version_ge "${PX_VERSION}" "${NBDD_MIN_VERSION}"; then
      DO_NBDD_CHECK=true
      info "NBDD check: ENABLED (PXE ${PX_VERSION} >= ${NBDD_MIN_VERSION})"
    else
      DO_NBDD_CHECK=false
      info "NBDD check: SKIPPED (PXE ${PX_VERSION} < ${NBDD_MIN_VERSION}; NBDD not applicable)"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Fetch STC YAML + cluster options JSON (used by both checks)
# ---------------------------------------------------------------------------
info "Fetching StorageCluster YAML..."
if ! ${cli} get stc -n "${NAMESPACE}" -o yaml > "${STC_YAML}" 2>/dev/null; then
  warn "Could not fetch StorageCluster YAML; NBDD check will fall back to cluster options."
fi

info "Fetching cluster options (JSON) from ${PX_SVC}..."
if ! ${cli} -n "${NAMESPACE}" exec "${PX_SVC}" -- bash -c "$(pxctl_cmd 'cluster options list -j')" \
       > "${CLUSTER_OPTS_JSON}" 2>/dev/null; then
  warn "Could not fetch cluster options JSON; falling back to text parse where possible."
  : > "${CLUSTER_OPTS_JSON}"
fi

# ---------------------------------------------------------------------------
# Step 1: RelaxedReclaim (prefer JSON; fall back to text)
# ---------------------------------------------------------------------------
info "Checking RelaxedReclaim setting..."
RELAXED_RECLAIM_STATUS=""
if [[ -s "${CLUSTER_OPTS_JSON}" ]]; then
  RELAXED_RECLAIM_STATUS="$(
    jq -r '
      (.RelaxedReclaim // .relaxed_reclaim // .relaxedReclaim // empty)
      | tostring | ascii_downcase
    ' "${CLUSTER_OPTS_JSON}" 2>/dev/null || true
  )"
fi
if [[ -z "${RELAXED_RECLAIM_STATUS}" ]]; then
  RELAXED_RECLAIM_STATUS="$(
    ${cli} -n "${NAMESPACE}" exec "${PX_SVC}" -- bash -c "$(pxctl_cmd 'cluster options list')" 2>/dev/null \
    | awk -F':' '/RelaxedReclaim/ { split($2,a,","); gsub(/[[:space:]]/,"",a[1]); print tolower(a[1]); exit }' \
    || true
  )"
fi

if [[ -z "${RELAXED_RECLAIM_STATUS}" ]]; then
  err "Could not determine RelaxedReclaim status from '${PX_SVC}' in namespace '${NAMESPACE}'."
  err "Possible causes: wrong namespace, service missing, pxctl not present, or RBAC."
  err "Reproduce manually:"
  err "  ${cli} -n ${NAMESPACE} exec ${PX_SVC} -- bash -c '$(pxctl_cmd 'cluster options list')'"
  exit 1
fi
info "RelaxedReclaim is currently: ${RELAXED_RECLAIM_STATUS}"

if [[ "${RELAXED_RECLAIM_STATUS}" != "on" ]]; then
  warn "RelaxedReclaim is NOT 'on'."
  warn "To enable it, run:"
  warn "  ${cli} -n ${NAMESPACE} exec ${PX_SVC} -- bash -c '$(pxctl_cmd 'cluster options update --relaxed-reclaim on')'"
  if ! confirm_proceed "RelaxedReclaim is disabled."; then
    err "Aborted. Enable RelaxedReclaim and re-run, or pass --yes to override."
    exit 3
  fi
  warn "Proceeding WITHOUT RelaxedReclaim enabled."
else
  info "RelaxedReclaim is ON. Proceeding."
fi

# ---------------------------------------------------------------------------
# Step 2: NBDD (Node Block Device Delete)
# ---------------------------------------------------------------------------
check_nbdd() {
  info "Checking NBDD (Node Block Device Delete) setting..."
  local nbdd_after="" nbdd_max=""

  # Prefer STC runtimeOptions via jsonpath (robust to indentation)
  if [[ -s "${STC_YAML}" ]]; then
    nbdd_after="$(${cli} -n "${NAMESPACE}" get stc \
        -o=jsonpath='{.items[0].spec.runtimeOptions.device_delete_after_discard}' 2>/dev/null || true)"
    nbdd_max="$(${cli} -n "${NAMESPACE}" get stc \
        -o=jsonpath='{.items[0].spec.runtimeOptions.device_delete_max_concurrent}' 2>/dev/null || true)"
  fi

  # Fallback: cluster options JSON via jq
  if [[ -z "${nbdd_after}" && -s "${CLUSTER_OPTS_JSON}" ]]; then
    nbdd_after="$(jq -r '(.device_delete_after_discard // empty) | tostring' "${CLUSTER_OPTS_JSON}" 2>/dev/null || true)"
    nbdd_max="$(jq -r '(.device_delete_max_concurrent // empty) | tostring' "${CLUSTER_OPTS_JSON}" 2>/dev/null || true)"
  fi

  if [[ "${nbdd_after}" == "1" ]]; then
    info "NBDD cluster setting : Enabled (device_delete_max_concurrent=${nbdd_max:-N/A})"
    return
  fi

  warn "NBDD is NOT enabled (device_delete_after_discard='${nbdd_after:-unset}')."
  warn "To enable NBDD, update StorageCluster runtimeOptions or run:"
  warn "  ${cli} -n ${NAMESPACE} exec ${PX_SVC} -- bash -c '$(pxctl_cmd 'cluster options update --device-delete-after-discard 1')'"
  if ! confirm_proceed "NBDD is disabled — underlying block devices will NOT be deleted after detach."; then
    err "Aborted. Enable NBDD and re-run, or pass --yes to override."
    exit 3
  fi
  warn "Proceeding WITHOUT NBDD enabled."
}

if [[ "${DO_NBDD_CHECK}" == "true" ]]; then
  check_nbdd
else
  info "Skipping NBDD verification for this PXE version."
fi

# ---------------------------------------------------------------------------
# Step 3: Discover Released PVs to detach
# ---------------------------------------------------------------------------
info "Fetching Released PVs (claim ns='${CLAIM_NAMESPACE}', policy=Delete, excluding SC='${EXCLUDE_SC}')..."
PV_LIST_FILE="${TMPDIR_WORK}/pv_list.txt"
${cli} get pv -o json | jq -r --arg cns "${CLAIM_NAMESPACE}" --arg xsc "${EXCLUDE_SC}" '
  .items[]
  | select(
      .status.phase == "Released"
      and .spec.persistentVolumeReclaimPolicy == "Delete"
      and (.spec.csi.driver // "") == "pxd.portworx.com"
      and (.spec.claimRef.namespace // "") == $cns
      and (.spec.storageClassName // "") != $xsc
    )
  | .metadata.name
' > "${PV_LIST_FILE}"

PV_LIST=()
while IFS= read -r _pv; do
  [ -n "${_pv}" ] && PV_LIST+=("${_pv}")
done < "${PV_LIST_FILE}"

TOTAL=${#PV_LIST[@]}
if [[ ${TOTAL} -eq 0 ]]; then
  info "No matching Released PVs found. Nothing to do."
  exit 0
fi
info "Found ${TOTAL} PV(s) to detach:"
for pv in "${PV_LIST[@]}"; do
  printf '  - %s\n' "${pv}"
done

# ---------------------------------------------------------------------------
# Final confirmation before mass-detach (unless dry-run or --yes)
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" != "true" && "${ASSUME_YES}" != "true" ]]; then
  if [[ ! -t 0 ]]; then
    err "Non-interactive shell; refusing to detach without --yes."
    exit 3
  fi
  read -rp "About to detach ${TOTAL} PV(s). Type 'DETACH' to continue: " ans
  if [[ "${ans}" != "DETACH" ]]; then
    err "Aborted by user."
    exit 3
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Detach loop
# ---------------------------------------------------------------------------
COUNT=0
FAILED=()
for pv in "${PV_LIST[@]}"; do
  COUNT=$(( COUNT + 1 ))
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[${COUNT}/${TOTAL}] [DRY-RUN] Would detach PV: ${pv}"
    info "[${COUNT}/${TOTAL}] [DRY-RUN] Command: ${cli} -n ${NAMESPACE} exec ${PX_SVC} -- bash -c '$(pxctl_cmd "host detach ${pv} --redirect")'"
  else
    info "[${COUNT}/${TOTAL}] Detaching PV: ${pv}"
    if out="$(${cli} -n "${NAMESPACE}" exec "${PX_SVC}" -- bash -c "$(pxctl_cmd "host detach ${pv} --redirect")" 2>&1)"; then
      info "[${COUNT}/${TOTAL}] Successfully detached: ${pv}"
      [[ -n "${out}" ]] && printf '%s\n' "${out}"
    else
      rc=$?
      err "[${COUNT}/${TOTAL}] Failed to detach ${pv} (rc=${rc})"
      [[ -n "${out}" ]] && err "${out}"
      FAILED+=("${pv}")
    fi
  fi
  if (( COUNT < TOTAL )); then
    if [[ "${DRY_RUN}" == "true" ]]; then
      info "[DRY-RUN] Would sleep ${SLEEP_BETWEEN}s before next detach."
    else
      info "Sleeping ${SLEEP_BETWEEN}s before next detach..."
      sleep "${SLEEP_BETWEEN}"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
info "=== Detach Summary ==="
if [[ "${DRY_RUN}" == "true" ]]; then
  info "Mode                       : DRY-RUN (no changes made)"
  info "PVs that would be detached : ${TOTAL}"
  for pv in "${PV_LIST[@]}"; do info "  - ${pv}"; done
  info "Re-run without --dry-run to perform the actual detach."
  exit 0
fi

info "Total PVs processed : ${TOTAL}"
info "Successful          : $(( TOTAL - ${#FAILED[@]} ))"
info "Failed              : ${#FAILED[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  err "The following PVs could not be detached:"
  for pv in "${FAILED[@]}"; do err "  - ${pv}"; done
  exit 2
fi
info "All PVs detached successfully."
