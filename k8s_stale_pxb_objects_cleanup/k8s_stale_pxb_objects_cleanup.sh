#!/usr/bin/env bash
# =============================================================================
# cleanup-nfs-resources.sh
#
# PURPOSE
#   Clean up stale NFS-related Kubernetes resources that match defined name
#   patterns and are older than a configurable number of days.
#
# ─────────────────────────────────────────────────────────────────────────────
# PRE-REQUISITES
#   1. Backup ALL ConfigMaps, PVCs, PVs, and Secrets across ALL namespaces
#      into:  k8s_backup_for_cleanup_<DDMMYYYYHH24MMSS>/
#   2. Show statistics of stale objects (age > MAX_AGE_DAYS):
#        - ConfigMaps  matching CM_PATTERN  in namespace NAMESPACE
#        - PVCs        matching PVC_PATTERN in namespace NAMESPACE
#        - PVs         matching PV_PATTERN  cluster-wide
#        - Secrets     matching SECRET_PATTERN across ALL namespaces
#   3. Display full deletion list on screen AND save to:
#        k8s_objects_to_be_cleaned_<DDMMYYYYHH24MMSS>.txt
#
# CONFIRMATION
#   Prompt user to type 'yes' to proceed; anything else exits safely.
#
# EXECUTION  (DELAY seconds between each individual object deletion)
#   Step 1 — ConfigMaps   matching CM_PATTERN     in namespace NAMESPACE
#   Step 2 — PVCs         matching PVC_PATTERN    in namespace NAMESPACE
#   Step 3 — PVs          matching PV_PATTERN     cluster-wide
#   Step 4 — Secrets      matching SECRET_PATTERN across ALL namespaces
# =============================================================================

set -euo pipefail

# =============================================================================
# TIMESTAMP  (shared by backup dir and report file — same run, same stamp)
# =============================================================================
RUN_TS="$(date '+%d%m%Y%H%M%S')"

# =============================================================================
# CONFIGURABLE DEFAULTS  (override via flags or environment variables)
# =============================================================================
NAMESPACE="${NAMESPACE:-central}"
CM_PATTERN="${CM_PATTERN:-nfs-delete}"
PVC_PATTERN="${PVC_PATTERN:-nfs-delete}"
PV_PATTERN="${PV_PATTERN:-nfs-delete}"
SECRET_PATTERN="${SECRET_PATTERN:-cred-secret-nfs-backup}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-30}"
DELAY="${DELAY:-5}"
BACKUP_DIR="${BACKUP_DIR:-k8s_backup_for_cleanup_${RUN_TS}}"
REPORT_FILE="${REPORT_FILE:-k8s_objects_to_be_cleaned_${RUN_TS}.txt}"

# =============================================================================
# COLOURS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GREY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# USAGE
# =============================================================================
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Backs up k8s resources, lists stale objects, and deletes them after confirmation.

  Backup  → k8s_backup_for_cleanup_<DDMMYYYYHH24MMSS>/
  Report  → k8s_objects_to_be_cleaned_<DDMMYYYYHH24MMSS>.txt

Options:
  -n, --namespace       NS    Target namespace for CM/PVC deletion  (default: central)
  --cm-pattern         PAT    ConfigMap name pattern                (default: nfs-delete)
  --pvc-pattern        PAT    PVC name pattern                      (default: nfs-delete)
  --pv-pattern         PAT    PV name pattern                       (default: nfs-delete)
  --secret-pattern     PAT    Secret name pattern                   (default: cred-secret-nfs-backup)
  -a, --age-days      DAYS    Min age (days) to be considered stale (default: 30)
  -d, --delay         SECS    Delay (s) between each deletion       (default: 5)
  -h, --help                  Show this help

Environment variables (lower priority than flags):
  NAMESPACE, CM_PATTERN, PVC_PATTERN, PV_PATTERN, SECRET_PATTERN,
  MAX_AGE_DAYS, DELAY

Examples:
  $(basename "$0")
  $(basename "$0") -n central -a 60 -d 10
  MAX_AGE_DAYS=90 $(basename "$0")
EOF
  exit 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)    NAMESPACE="$2";      shift 2 ;;
    --cm-pattern)      CM_PATTERN="$2";     shift 2 ;;
    --pvc-pattern)     PVC_PATTERN="$2";    shift 2 ;;
    --pv-pattern)      PV_PATTERN="$2";     shift 2 ;;
    --secret-pattern)  SECRET_PATTERN="$2"; shift 2 ;;
    -a|--age-days)     MAX_AGE_DAYS="$2";   shift 2 ;;
    -d|--delay)        DELAY="$2";          shift 2 ;;
    -h|--help)         usage ;;
    *) echo -e "${RED}Unknown option: $1${NC}" >&2; usage ;;
  esac
done

# =============================================================================
# LOGGING
# =============================================================================
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() {
  echo ""
  echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${BOLD}${CYAN}│  $*${NC}"
  echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────────${NC}"
}

# =============================================================================
# DATE / AGE HELPERS
# =============================================================================
timestamp_to_epoch() {
  local ts="${1/T/ }"
  ts="${ts%Z}"
  if date --version &>/dev/null 2>&1; then
    date -d "$ts" +%s 2>/dev/null || echo ""
  else
    date -j -f "%Y-%m-%d %H:%M:%S" "$ts" +%s 2>/dev/null || echo ""
  fi
}

age_in_days() {
  local epoch
  epoch=$(timestamp_to_epoch "$1")
  [[ -z "$epoch" ]] && { echo "?"; return; }
  echo $(( ( $(date +%s) - epoch ) / 86400 ))
}

is_older_than() {
  local epoch
  epoch=$(timestamp_to_epoch "$1")
  [[ -z "$epoch" ]] && return 0   # unparseable → treat as stale
  (( ( $(date +%s) - epoch ) > ($2 * 86400) ))
}

# =============================================================================
# COUNTDOWN BETWEEN INDIVIDUAL DELETIONS
# =============================================================================
countdown() {
  local secs="$1"
  for ((i=secs; i>0; i--)); do
    printf "\r  ${YELLOW}  Next deletion in %2ds ...${NC} " "$i"
    sleep 1
  done
  printf "\r%-45s\n" ""
}

# =============================================================================
# PRE-REQ 1 — BACKUP
# Directory: k8s_backup_for_cleanup_<DDMMYYYYHH24MMSS>/
#   all-namespaces/          ← combined -o wide list + YAML per resource type
#   per-namespace/<ns>/      ← same, scoped per namespace (only non-empty)
#   pv/                      ← cluster-scoped PVs
# =============================================================================

_backup_write() {
  # _backup_write RESOURCE_TYPE TARGET_DIR NS_FLAG
  local rtype="$1" tdir="$2" ns_flag="$3"
  mkdir -p "$tdir"
  local list_f="${tdir}/${rtype}-list.txt"
  local yaml_f="${tdir}/${rtype}-all.yaml"

  # shellcheck disable=SC2086
  kubectl get "$rtype" $ns_flag --no-headers -o wide \
    > "$list_f" 2>/dev/null || true
  local cnt
  cnt=$(grep -c '' "$list_f" 2>/dev/null || echo 0)
  log_ok "    list → ${list_f}  (${cnt} object(s))"

  # shellcheck disable=SC2086
  kubectl get "$rtype" $ns_flag -o yaml \
    > "$yaml_f" 2>/dev/null || true
  local sz
  sz=$(du -sh "$yaml_f" 2>/dev/null | awk '{print $1}')
  log_ok "    yaml → ${yaml_f}  (${sz})"
}

_backup_namespaced() {
  local rtype="$1"
  log_info "  ▸ ${rtype}  —  all namespaces combined"
  _backup_write "$rtype" "${BACKUP_DIR}/all-namespaces" "--all-namespaces"

  log_info "  ▸ ${rtype}  —  per namespace"
  local namespaces
  namespaces=$(kubectl get namespaces --no-headers \
                 -o custom-columns=":metadata.name" 2>/dev/null || true)
  local ns_count=0
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    local cnt
    cnt=$(kubectl get "$rtype" -n "$ns" --no-headers 2>/dev/null \
            | wc -l | tr -d ' ')
    if (( cnt > 0 )); then
      _backup_write "$rtype" "${BACKUP_DIR}/per-namespace/${ns}" "-n ${ns}"
      (( ns_count++ )) || true
    fi
  done <<< "$namespaces"
  log_info "      ${ns_count} namespace(s) contained ${rtype}s."
}

_backup_pv() {
  log_info "  ▸ pv  —  cluster-scoped"
  _backup_write "pv" "${BACKUP_DIR}/pv" ""
}

run_backup() {
  log_section "PRE-REQ 1/3  —  Backup ALL resources  →  ${BACKUP_DIR}/"
  mkdir -p "$BACKUP_DIR"

  echo ""
  _backup_namespaced "configmap"
  echo ""
  _backup_namespaced "pvc"
  echo ""
  _backup_pv
  echo ""
  _backup_namespaced "secret"

  echo ""
  log_ok "Backup complete."
  cat <<-LAYOUT
  ${BACKUP_DIR}/
    all-namespaces/           ← combined list + YAML  (configmap, pvc, secret)
    per-namespace/<ns>/       ← per-namespace breakdown
    pv/                       ← cluster-scoped PVs
LAYOUT
}

# =============================================================================
# PRE-REQ 2 — ANALYSE  (populate deletion-candidate arrays + counters)
# =============================================================================

# Deletion-candidate arrays
#   Namespaced : "name|created|age_days"
#   Secrets    : "namespace|name|created|age_days"
declare -a CM_DELETE=() PVC_DELETE=() PV_DELETE=() SECRET_DELETE=()

# Counters  [resource_key] = value
declare -A TOTAL_CNT=([configmap]=0 [pvc]=0 [pv]=0 [secret]=0)
declare -A DEL_CNT=(  [configmap]=0 [pvc]=0 [pv]=0 [secret]=0)
declare -A SKIP_CNT=( [configmap]=0 [pvc]=0 [pv]=0 [secret]=0)

_analyse_namespaced() {
  local rtype="$1" ns="$2" pattern="$3" max_age="$4"
  local raw total=0 eligible=0 skipped=0

  raw=$(kubectl get "$rtype" -n "$ns" --no-headers \
          -o custom-columns="NAME:.metadata.name,CREATED:.metadata.creationTimestamp" \
          2>/dev/null | grep "$pattern" || true)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local name created age
    name=$(    awk '{print $1}' <<< "$line")
    created=$( awk '{print $2}' <<< "$line")
    age=$(age_in_days "$created")
    (( total++ )) || true
    if is_older_than "$created" "$max_age"; then
      (( eligible++ )) || true
      case "$rtype" in
        configmap)  CM_DELETE+=(  "${name}|${created}|${age}") ;;
        pvc)       PVC_DELETE+=(  "${name}|${created}|${age}") ;;
      esac
    else
      (( skipped++ )) || true
    fi
  done <<< "$raw"

  TOTAL_CNT[$rtype]=$total
  DEL_CNT[$rtype]=$eligible
  SKIP_CNT[$rtype]=$skipped
}

_analyse_pv() {
  local pattern="$1" max_age="$2"
  local raw total=0 eligible=0 skipped=0

  raw=$(kubectl get pv --no-headers \
          -o custom-columns="NAME:.metadata.name,CREATED:.metadata.creationTimestamp" \
          2>/dev/null | grep "$pattern" || true)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local name created age
    name=$(    awk '{print $1}' <<< "$line")
    created=$( awk '{print $2}' <<< "$line")
    age=$(age_in_days "$created")
    (( total++ )) || true
    if is_older_than "$created" "$max_age"; then
      (( eligible++ )) || true
      PV_DELETE+=("${name}|${created}|${age}")
    else
      (( skipped++ )) || true
    fi
  done <<< "$raw"

  TOTAL_CNT[pv]=$total
  DEL_CNT[pv]=$eligible
  SKIP_CNT[pv]=$skipped
}

_analyse_secrets_all_ns() {
  local pattern="$1" max_age="$2"
  local total=0 eligible=0 skipped=0

  local namespaces
  namespaces=$(kubectl get namespaces --no-headers \
                 -o custom-columns=":metadata.name" 2>/dev/null || true)

  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    local raw
    raw=$(kubectl get secret -n "$ns" --no-headers \
            -o custom-columns="NAME:.metadata.name,CREATED:.metadata.creationTimestamp" \
            2>/dev/null | grep "$pattern" || true)
    [[ -z "$raw" ]] && continue

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local name created age
      name=$(    awk '{print $1}' <<< "$line")
      created=$( awk '{print $2}' <<< "$line")
      age=$(age_in_days "$created")
      (( total++ )) || true
      if is_older_than "$created" "$max_age"; then
        (( eligible++ )) || true
        SECRET_DELETE+=("${ns}|${name}|${created}|${age}")
      else
        (( skipped++ )) || true
      fi
    done <<< "$raw"
  done <<< "$namespaces"

  TOTAL_CNT[secret]=$total
  DEL_CNT[secret]=$eligible
  SKIP_CNT[secret]=$skipped
}

run_analyse() {
  log_section "PRE-REQ 2/3  —  Statistics: stale objects (age > ${MAX_AGE_DAYS}d)"
  echo ""
  log_info "Scanning ConfigMaps  in namespace '${NAMESPACE}' (pattern: ${CM_PATTERN}) ..."
  _analyse_namespaced "configmap" "$NAMESPACE" "$CM_PATTERN" "$MAX_AGE_DAYS"

  log_info "Scanning PVCs        in namespace '${NAMESPACE}' (pattern: ${PVC_PATTERN}) ..."
  _analyse_namespaced "pvc" "$NAMESPACE" "$PVC_PATTERN" "$MAX_AGE_DAYS"

  log_info "Scanning PVs         cluster-wide (pattern: ${PV_PATTERN}) ..."
  _analyse_pv "$PV_PATTERN" "$MAX_AGE_DAYS"

  log_info "Scanning Secrets     all namespaces (pattern: ${SECRET_PATTERN}) ..."
  _analyse_secrets_all_ns "$SECRET_PATTERN" "$MAX_AGE_DAYS"
}

# =============================================================================
# PRE-REQ 2 — STATISTICS TABLE
# =============================================================================
print_stats() {
  local total_del=$(( \
    ${DEL_CNT[configmap]} + ${DEL_CNT[pvc]} + \
    ${DEL_CNT[pv]}        + ${DEL_CNT[secret]} ))
  local grand_tot=$(( \
    ${TOTAL_CNT[configmap]} + ${TOTAL_CNT[pvc]} + \
    ${TOTAL_CNT[pv]}        + ${TOTAL_CNT[secret]} ))
  local grand_skp=$(( \
    ${SKIP_CNT[configmap]} + ${SKIP_CNT[pvc]} + \
    ${SKIP_CNT[pv]}        + ${SKIP_CNT[secret]} ))

  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════╦══════════╦══════════════╦══════════════════════╗${NC}"
  printf  "${BOLD}${CYAN}║${NC}  %-28s ${BOLD}${CYAN}║${NC}  %-8s${BOLD}${CYAN}║${NC}  %-12s${BOLD}${CYAN}║${NC}  %-20s${BOLD}${CYAN}║${NC}\n" \
          "  Stale objects (>${MAX_AGE_DAYS}d)" "Total" "To Delete" "Skip (too recent)"
  echo -e "${BOLD}${CYAN}╠══════════════════════════════╬══════════╬══════════════╬══════════════════════╣${NC}"

  _stat_row() {
    local label="$1" rkey="$2"
    local tot=${TOTAL_CNT[$rkey]}
    local del=${DEL_CNT[$rkey]}
    local skp=${SKIP_CNT[$rkey]}
    local del_col
    [[ $del -gt 0 ]] && del_col="${RED}${del}${NC}" || del_col="${GREEN}${del}${NC}"
    printf "${CYAN}║${NC}  %-28s ${CYAN}║${NC}  %6s    ${CYAN}║${NC}  " "$label" "$tot"
    echo -en "${del_col}"
    printf "%-10s  ${CYAN}║${NC}  %-20s  ${CYAN}║${NC}\n" "" "$skp"
  }

  _stat_row "configmap  (ns:${NAMESPACE})"    "configmap"
  _stat_row "pvc        (ns:${NAMESPACE})"    "pvc"
  _stat_row "pv         (cluster-wide)"       "pv"
  _stat_row "secret     (all namespaces)"     "secret"

  echo -e "${BOLD}${CYAN}╠══════════════════════════════╬══════════╬══════════════╬══════════════════════╣${NC}"
  echo -e "${BOLD}${CYAN}╠══════════════════════════════╬══════════╬══════════════╬══════════════════════╣${NC}"

  printf "${BOLD}${CYAN}║${NC}  %-28s ${CYAN}║${NC}  %6s    ${CYAN}║${NC}  " "TOTAL" "$grand_tot"
  [[ $total_del -gt 0 ]] \
    && echo -en "${RED}${BOLD}${total_del}${NC}" \
    || echo -en "${GREEN}${BOLD}${total_del}${NC}"
  printf "%-10s  ${CYAN}║${NC}  %-20s  ${CYAN}║${NC}\n" "" "$grand_skp"

  echo -e "${BOLD}${CYAN}╚══════════════════════════════╩══════════╩══════════════╩══════════════════════╝${NC}"
  echo ""

  if [[ $total_del -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}✔  No stale objects found. Nothing to delete.${NC}"
  else
    echo -e "  ${RED}${BOLD}⚠  ${total_del} object(s) are stale and will be PERMANENTLY DELETED.${NC}"
  fi
}

# =============================================================================
# PRE-REQ 3 — BUILD, DISPLAY AND SAVE DELETION LIST
# =============================================================================

# _report_section_no_ns TITLE ENTRIES_ARRAY_ITEMS...
_report_section_no_ns() {
  local title="$1"; shift
  local -a entries=("$@")

  printf "\n"
  printf "  %s\n" "─────────────────────────────────────────────────────────────────────────────────"
  printf "  %s\n" "$title"
  printf "  %s\n" "─────────────────────────────────────────────────────────────────────────────────"

  if [[ ${#entries[@]} -eq 0 ]]; then
    printf "  (none)\n"
    return
  fi

  printf "  %-52s  %-26s  %s\n"  "NAME"    "CREATED (UTC)"   "AGE (days)"
  printf "  %-52s  %-26s  %s\n"  \
    "$(printf '%.0s─' {1..52})"  "$(printf '%.0s─' {1..26})"  "──────────"
  for entry in "${entries[@]}"; do
    IFS='|' read -r name created age <<< "$entry"
    printf "  %-52s  %-26s  %s\n" "$name" "$created" "$age"
  done
}

# _report_section_with_ns TITLE ENTRIES_ARRAY_ITEMS...
_report_section_with_ns() {
  local title="$1"; shift
  local -a entries=("$@")

  printf "\n"
  printf "  %s\n" "─────────────────────────────────────────────────────────────────────────────────"
  printf "  %s\n" "$title"
  printf "  %s\n" "─────────────────────────────────────────────────────────────────────────────────"

  if [[ ${#entries[@]} -eq 0 ]]; then
    printf "  (none)\n"
    return
  fi

  printf "  %-20s  %-48s  %-26s  %s\n" \
    "NAMESPACE" "NAME" "CREATED (UTC)" "AGE (days)"
  printf "  %-20s  %-48s  %-26s  %s\n" \
    "$(printf '%.0s─' {1..20})" "$(printf '%.0s─' {1..48})" \
    "$(printf '%.0s─' {1..26})" "──────────"
  for entry in "${entries[@]}"; do
    IFS='|' read -r ns name created age <<< "$entry"
    printf "  %-20s  %-48s  %-26s  %s\n" "$ns" "$name" "$created" "$age"
  done
}

write_and_display_report() {
  log_section "PRE-REQ 3/3  —  Objects to be deleted  →  ${REPORT_FILE}"

  local total_del=$(( \
    ${DEL_CNT[configmap]} + ${DEL_CNT[pvc]} + \
    ${DEL_CNT[pv]}        + ${DEL_CNT[secret]} ))
  local grand_tot=$(( \
    ${TOTAL_CNT[configmap]} + ${TOTAL_CNT[pvc]} + \
    ${TOTAL_CNT[pv]}        + ${TOTAL_CNT[secret]} ))
  local grand_skp=$(( \
    ${SKIP_CNT[configmap]} + ${SKIP_CNT[pvc]} + \
    ${SKIP_CNT[pv]}        + ${SKIP_CNT[secret]} ))

  # Build the plain-text report body in a function so it can be tee'd cleanly
  _report_body() {
    printf "=================================================================================\n"
    printf "  K8S OBJECTS TO BE CLEANED\n"
    printf "  Generated        : %s\n" "$(date '+%d-%m-%Y %H:%M:%S %Z')"
    printf "  Run timestamp    : %s\n" "$RUN_TS"
    printf "=================================================================================\n"
    printf "  Target namespace : %s\n"  "$NAMESPACE"
    printf "  ConfigMap pattern: %s\n"  "$CM_PATTERN"
    printf "  PVC pattern      : %s\n"  "$PVC_PATTERN"
    printf "  PV pattern       : %s\n"  "$PV_PATTERN"
    printf "  Secret pattern   : %s\n"  "$SECRET_PATTERN"
    printf "  Min age (days)   : %s\n"  "$MAX_AGE_DAYS"
    printf "=================================================================================\n"

    # ── Summary table ─────────────────────────────────────────────────────────
    printf "\n  SUMMARY\n"
    printf "  %-30s  %8s  %12s  %20s\n" \
      "RESOURCE" "TOTAL" "TO DELETE" "SKIP (too recent)"
    printf "  %-30s  %8s  %12s  %20s\n" \
      "$(printf '%.0s─' {1..30})" "────────" "────────────" "────────────────────"
    printf "  %-30s  %8s  %12s  %20s\n" \
      "configmap (ns:${NAMESPACE})" \
      "${TOTAL_CNT[configmap]}" "${DEL_CNT[configmap]}" "${SKIP_CNT[configmap]}"
    printf "  %-30s  %8s  %12s  %20s\n" \
      "pvc (ns:${NAMESPACE})" \
      "${TOTAL_CNT[pvc]}" "${DEL_CNT[pvc]}" "${SKIP_CNT[pvc]}"
    printf "  %-30s  %8s  %12s  %20s\n" \
      "pv (cluster-wide)" \
      "${TOTAL_CNT[pv]}" "${DEL_CNT[pv]}" "${SKIP_CNT[pv]}"
    printf "  %-30s  %8s  %12s  %20s\n" \
      "secret (all namespaces)" \
      "${TOTAL_CNT[secret]}" "${DEL_CNT[secret]}" "${SKIP_CNT[secret]}"
    printf "  %-30s  %8s  %12s  %20s\n" \
      "$(printf '%.0s─' {1..30})" "────────" "────────────" "────────────────────"
    printf "  %-30s  %8s  %12s  %20s\n" \
      "TOTAL" "$grand_tot" "$total_del" "$grand_skp"

    # ── Per-resource detail ────────────────────────────────────────────────────
    _report_section_no_ns \
      "1. CONFIGMAPS  |  ns: ${NAMESPACE}  |  pattern: ${CM_PATTERN}  |  age > ${MAX_AGE_DAYS}d" \
      "${CM_DELETE[@]+"${CM_DELETE[@]}"}"

    _report_section_no_ns \
      "2. PVCs  |  ns: ${NAMESPACE}  |  pattern: ${PVC_PATTERN}  |  age > ${MAX_AGE_DAYS}d" \
      "${PVC_DELETE[@]+"${PVC_DELETE[@]}"}"

    _report_section_no_ns \
      "3. PVs  |  cluster-wide  |  pattern: ${PV_PATTERN}  |  age > ${MAX_AGE_DAYS}d" \
      "${PV_DELETE[@]+"${PV_DELETE[@]}"}"

    _report_section_with_ns \
      "4. SECRETS  |  all namespaces  |  pattern: ${SECRET_PATTERN}  |  age > ${MAX_AGE_DAYS}d" \
      "${SECRET_DELETE[@]+"${SECRET_DELETE[@]}"}"

    printf "\n"
    printf "=================================================================================\n"
    printf "  TOTAL OBJECTS TO BE DELETED : %s\n" "$total_del"
    printf "=================================================================================\n"
  }

  # Pipe through tee: display on screen AND write to file simultaneously
  _report_body | tee "$REPORT_FILE"

  echo ""
  log_ok "Report saved → ${REPORT_FILE}"
}

# =============================================================================
# CONFIRMATION PROMPT
# =============================================================================
confirm_deletion() {
  local total_del=$(( \
    ${DEL_CNT[configmap]} + ${DEL_CNT[pvc]} + \
    ${DEL_CNT[pv]}        + ${DEL_CNT[secret]} ))

  if [[ $total_del -eq 0 ]]; then
    echo ""
    log_warn "No stale objects found matching the criteria. Nothing to delete."
    exit 0
  fi

  echo ""
  echo -e "  ${YELLOW}${BOLD}Backup location : ${BACKUP_DIR}/${NC}"
  echo -e "  ${YELLOW}${BOLD}Report file     : ${REPORT_FILE}${NC}"
  echo ""
  echo -e "  ${RED}${BOLD}⚠  ${total_del} object(s) will be PERMANENTLY DELETED.${NC}"
  echo ""
  echo -en "  ${RED}${BOLD}Proceed with deletion? Type 'yes' to confirm: ${NC}"
  read -r answer
  echo ""

  if [[ "${answer}" != "yes" ]]; then
    echo -e "  ${YELLOW}Aborted. No objects were deleted.${NC}"
    echo -e "  ${GREY}Backup is retained at: ${BACKUP_DIR}/${NC}"
    echo -e "  ${GREY}Report is retained at: ${REPORT_FILE}${NC}"
    echo ""
    exit 0
  fi

  log_ok "Confirmed. Starting deletion ..."
}

# =============================================================================
# EXECUTION — DELETION HELPERS
# =============================================================================

# Delete namespaced objects (configmap | pvc) from a specific namespace.
# Usage: _exec_delete_namespaced  RTYPE  NAMESPACE  MAX_AGE  ENTRY...
_exec_delete_namespaced() {
  local rtype="$1" ns="$2" max_age="$3"
  shift 3
  local -a entries=("$@")

  if [[ ${#entries[@]} -eq 0 ]]; then
    log_warn "  No eligible ${rtype}s to delete in namespace '${ns}'."
    return
  fi

  local deleted=0 failed=0 total=${#entries[@]} idx=0

  for entry in "${entries[@]}"; do
    (( idx++ )) || true
    IFS='|' read -r name created age <<< "$entry"
    log_info "  [${idx}/${total}]  ${rtype}/${name}  (ns: ${ns}, age: ${age}d)"
    if kubectl delete "$rtype" "$name" -n "$ns" 2>/dev/null; then
      log_ok "  Deleted  ${rtype}/${name}  [${ns}]"
      (( deleted++ )) || true
    else
      log_error "  Failed   ${rtype}/${name}  [${ns}]"
      (( failed++ )) || true
    fi
    # Delay between objects, not after the last one
    if (( idx < total )); then countdown "$DELAY"; fi
  done

  echo ""
  echo -e "  ${BOLD}Result:${NC}  ${GREEN}${deleted} deleted${NC}  |  ${RED}${failed} failed${NC}  |  ${GREY}${SKIP_CNT[$rtype]} skipped (too recent)${NC}"
}

# Delete cluster-scoped PVs.
_exec_delete_pv() {
  local max_age="$1"

  if [[ ${#PV_DELETE[@]} -eq 0 ]]; then
    log_warn "  No eligible PVs to delete."
    return
  fi

  local deleted=0 failed=0 total=${#PV_DELETE[@]} idx=0

  for entry in "${PV_DELETE[@]}"; do
    (( idx++ )) || true
    IFS='|' read -r name created age <<< "$entry"
    log_info "  [${idx}/${total}]  pv/${name}  (cluster-scoped, age: ${age}d)"
    if kubectl delete pv "$name" 2>/dev/null; then
      log_ok "  Deleted  pv/${name}"
      (( deleted++ )) || true
    else
      log_error "  Failed   pv/${name}"
      (( failed++ )) || true
    fi
    if (( idx < total )); then countdown "$DELAY"; fi
  done

  echo ""
  echo -e "  ${BOLD}Result:${NC}  ${GREEN}${deleted} deleted${NC}  |  ${RED}${failed} failed${NC}  |  ${GREY}${SKIP_CNT[pv]} skipped (too recent)${NC}"
}

# Delete secrets across all namespaces.
_exec_delete_secrets() {
  local max_age="$1"

  if [[ ${#SECRET_DELETE[@]} -eq 0 ]]; then
    log_warn "  No eligible secrets to delete."
    return
  fi

  local deleted=0 failed=0 total=${#SECRET_DELETE[@]} idx=0

  for entry in "${SECRET_DELETE[@]}"; do
    (( idx++ )) || true
    IFS='|' read -r ns name created age <<< "$entry"
    log_info "  [${idx}/${total}]  secret/${name}  (ns: ${ns}, age: ${age}d)"
    if kubectl delete secret "$name" -n "$ns" 2>/dev/null; then
      log_ok "  Deleted  secret/${name}  [${ns}]"
      (( deleted++ )) || true
    else
      log_error "  Failed   secret/${name}  [${ns}]"
      (( failed++ )) || true
    fi
    if (( idx < total )); then countdown "$DELAY"; fi
  done

  echo ""
  echo -e "  ${BOLD}Result:${NC}  ${GREEN}${deleted} deleted${NC}  |  ${RED}${failed} failed${NC}  |  ${GREY}${SKIP_CNT[secret]} skipped (too recent)${NC}"
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
if ! command -v kubectl &>/dev/null; then
  log_error "kubectl not found in PATH. Aborting."
  exit 1
fi
if ! [[ "$DELAY" =~ ^[0-9]+$ ]]; then
  log_error "--delay must be a non-negative integer, got: '${DELAY}'"; exit 1
fi
if ! [[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]] || (( MAX_AGE_DAYS < 1 )); then
  log_error "--age-days must be a positive integer, got: '${MAX_AGE_DAYS}'"; exit 1
fi

# =============================================================================
# HEADER
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║             NFS Resource Cleanup Script                           ║${NC}"
echo -e "${CYAN}${BOLD}╠════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}${BOLD}║${NC}  Run timestamp       : ${YELLOW}${RUN_TS}${NC}"
echo -e "${CYAN}${BOLD}║${NC}  Target namespace    : ${YELLOW}${NAMESPACE}${NC}"
echo -e "${CYAN}${BOLD}║${NC}  ConfigMap pattern   : ${YELLOW}${CM_PATTERN}${NC}"
echo -e "${CYAN}${BOLD}║${NC}  PVC pattern         : ${YELLOW}${PVC_PATTERN}${NC}"
echo -e "${CYAN}${BOLD}║${NC}  PV pattern          : ${YELLOW}${PV_PATTERN}${NC}"
echo -e "${CYAN}${BOLD}║${NC}  Secret pattern      : ${YELLOW}${SECRET_PATTERN}${NC}"
echo -e "${CYAN}${BOLD}║${NC}  Min age (stale)     : ${YELLOW}${MAX_AGE_DAYS} days${NC}"
echo -e "${CYAN}${BOLD}║${NC}  Delay per deletion  : ${YELLOW}${DELAY}s${NC}"
echo -e "${CYAN}${BOLD}╠════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}${BOLD}║${NC}  Backup directory    : ${YELLOW}${BACKUP_DIR}/${NC}"
echo -e "${CYAN}${BOLD}║${NC}  Report file         : ${YELLOW}${REPORT_FILE}${NC}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════════╝${NC}"

# =============================================================================
# PRE-REQ 1 — BACKUP
# =============================================================================
run_backup

# =============================================================================
# PRE-REQ 2 — ANALYSE + STATISTICS
# =============================================================================
run_analyse
print_stats

# =============================================================================
# PRE-REQ 3 — DISPLAY + SAVE REPORT
# =============================================================================
write_and_display_report

# =============================================================================
# CONFIRMATION
# =============================================================================
confirm_deletion

# =============================================================================
# EXECUTION
# =============================================================================

log_section "Step 1/4  —  Delete ConfigMaps  (ns:${NAMESPACE}, pattern:${CM_PATTERN}, age>${MAX_AGE_DAYS}d)"
_exec_delete_namespaced "configmap" "$NAMESPACE" "$MAX_AGE_DAYS" \
  "${CM_DELETE[@]+"${CM_DELETE[@]}"}"

log_section "Step 2/4  —  Delete PVCs  (ns:${NAMESPACE}, pattern:${PVC_PATTERN}, age>${MAX_AGE_DAYS}d)"
_exec_delete_namespaced "pvc" "$NAMESPACE" "$MAX_AGE_DAYS" \
  "${PVC_DELETE[@]+"${PVC_DELETE[@]}"}"

log_section "Step 3/4  —  Delete PVs  (cluster-wide, pattern:${PV_PATTERN}, age>${MAX_AGE_DAYS}d)"
_exec_delete_pv "$MAX_AGE_DAYS"

log_section "Step 4/4  —  Delete Secrets  (all namespaces, pattern:${SECRET_PATTERN}, age>${MAX_AGE_DAYS}d)"
_exec_delete_secrets "$MAX_AGE_DAYS"

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Cleanup complete!                                                 ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════════╝${NC}"
echo -e "  Backup location  : ${YELLOW}${BACKUP_DIR}/${NC}"
echo -e "  Report file      : ${YELLOW}${REPORT_FILE}${NC}"
echo ""
