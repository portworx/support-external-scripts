#!/usr/bin/env bash
#
# collect_px_kvdb_info.sh
#
# 1) Find etcdctl using: find / -type f | grep etcdctl
# 2) Select a non-leader, healthy KVDB node from `pxctl service kvdb members`
#    and derive an IP-based endpoint using `pxctl status` node-id → IP mapping
# 3) Get clusterID from `pxctl status | grep 'Cluster ID'`
# 4) Run etcdctl commands and save all outputs under /tmp/px_kvdb_bundle,
#    then tar.gz that directory.

set -euo pipefail

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BUNDLE_DIR="px_kvdb_bundle_${TIMESTAMP}"
OUTPUT_DIR="/tmp/${BUNDLE_DIR}"
ARCHIVE="${OUTPUT_DIR}.tar.gz"

mkdir ${OUTPUT_DIR}

echo "[INFO] Starting px KVDB bundle collection..."

############################################
# 1) Find etcdctl via filesystem search
############################################

echo "[INFO] Searching filesystem for etcdctl (this may take some time)..."
ETCDCTL_BIN="$(find / -type f 2>/dev/null | grep -m1 '/etcdctl$' || true)"

if [[ -z "${ETCDCTL_BIN}" ]]; then
  echo "[ERROR] etcdctl not found via 'find / -type f | grep etcdctl'."
  exit 1
fi

if [[ ! -x "${ETCDCTL_BIN}" ]]; then
  echo "[WARN] Found etcdctl at ${ETCDCTL_BIN} but it is not marked executable. Attempting to use it anyway."
fi

ETCDCTL_CMD="${ETCDCTL_BIN}"
echo "[INFO] Using etcdctl binary: ${ETCDCTL_CMD}"

# Ensure pxctl is present
if ! command -v pxctl >/dev/null 2>&1; then
  echo "[ERROR] pxctl not found in PATH. This script requires pxctl."
  exit 1
fi

############################################
# Prepare bundle directory
############################################

rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}"

############################################
# 2) Collect pxctl kvdb + status and select
#    a non-leader, healthy KVDB node
############################################

echo "[INFO] Collecting pxctl kvdb and status information..."

pxctl service kvdb members > "${BUNDLE_DIR}/pxctl_service_kvdb_members.txt" 2>&1 || true
pxctl status > "${BUNDLE_DIR}/pxctl_status.txt" 2>&1 || true

# Build node-id -> IP map from pxctl status
declare -A NODEID_TO_IP

# Example status line:
# 10.38.74.143    148380f2-adfb-4436-9a20-ef58af97c178    ip-10-38-74-143.pwx.purestorage.com ...
while read -r ip node_id _; do
  [[ -z "${ip}" || -z "${node_id}" ]] && continue
  NODEID_TO_IP["${node_id}"]="${ip}"
done < <(pxctl status 2>/dev/null | awk '$1 ~ /^[0-9.]+$/ && $2 ~ /-/ {print $1, $2}')

# From pxctl service kvdb members, select first non-leader & healthy row
# Example members table:
# ID                                      PEER URLs                               CLIENT URLs                             LEADER  HEALTHY DBSIZE
# 1483...  [http://portworx-1.internal.kvdb:9018]  [http://portworx-1.internal.kvdb:9019]  false   true    632 KiB
member_selection="$(pxctl service kvdb members 2>/dev/null \
  | awk 'NR>2 && $4=="false" && $5=="true" {print $1, $3; exit}')"

if [[ -z "${member_selection}" ]]; then
  echo "[ERROR] No non-leader, healthy KVDB member found."
  exit 1
fi

read -r member_id client_url_field <<< "${member_selection}"

# client_url_field is like: [http://portworx-1.internal.kvdb:9019]
# Strip square brackets
client_url="${client_url_field#[}"
client_url="${client_url%]}"

# Extract port from CLIENT URL (string after the last ':')
port="${client_url##*:}"

ip="${NODEID_TO_IP[${member_id}]:-}"
if [[ -z "${ip}" ]]; then
  echo "[ERROR] No IP mapping found in pxctl status for member-id ${member_id}."
  exit 1
fi

ENDPOINTS="http://${ip}:${port}"

echo "[INFO] Selected non-leader, healthy KVDB member: ${member_id} (${ip}:${port})"
echo "[INFO] Using ETCD endpoints: ${ENDPOINTS}"
echo "${ENDPOINTS}" > "${BUNDLE_DIR}/etcd_endpoints.txt"

############################################
# 3) Get clusterID from pxctl status
############################################

echo "[INFO] Extracting Cluster ID from pxctl status..."

clusterID="$(pxctl status 2>/dev/null | grep -m1 'Cluster ID' | awk -F':' '{print $2}' | xargs || true)"

if [[ -z "${clusterID}" ]]; then
  echo "[ERROR] Could not extract Cluster ID from pxctl status."
  exit 1
fi

echo "[INFO] Detected Cluster ID: ${clusterID}"
echo "${clusterID}" > "${BUNDLE_DIR}/cluster_id.txt"

############################################
# 4) Run etcdctl commands and store outputs
############################################

export ETCDCTL_API=3

echo "[INFO] Running etcdctl member list..."
"${ETCDCTL_CMD}" --endpoints="${ENDPOINTS}" member list \
  > "${OUTPUT_DIR}/etcdctl_member_list.txt" 2>&1 || true

echo "[INFO] Running etcdctl get --keys-only --prefix 'pwx'..."
"${ETCDCTL_CMD}" --endpoints="${ENDPOINTS}" get --keys-only --prefix 'pwx' \
  > "${OUTPUT_DIR}/etcdctl_get_pwx_keys_only.txt" 2>&1 || true

echo "[INFO] Running etcdctl get --prefix 'pwx/${clusterID}/cluster/database'..."
"${ETCDCTL_CMD}" --endpoints="${ENDPOINTS}" get --prefix "pwx/${clusterID}/cluster/database" \
  > "${OUTPUT_DIR}/etcdctl_get_cluster_database.txt" 2>&1 || true

############################################
# Archive the bundle
############################################

echo "[INFO] Creating tar.gz archive at ${ARCHIVE} ..."
tar -C /tmp -czf "${ARCHIVE}" "$(basename "${OUTPUT_DIR}")"

echo "[INFO] Completed. Bundle directory: ${OUTPUT_DIR}"
echo "[INFO] Archive created: ${ARCHIVE}"
