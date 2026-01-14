#!/bin/bash
# ================================================================
# Script: px_metrics_dump_exporter.sh
#
# Dumps Prometheus metrics from a given namespace using promtool.
# Supports explicit min/max times, relative days, optional match selectors,
# optional metric name prefixes, and automatic local file output.
#
# Usage:
#   px_metrics_dump_exporter.sh --prom-ns <namespace> [--since-days <days>] [--min-ms <epoch_ms>] [--max-ms <epoch_ms>] [--cli <kubectl/oc>]... [--match-prefix <prefix>]... [--output <filename>]
#
# Examples:
#   px_metrics_dump_exporter.sh ###(It prompts for needed inputs)
#   px_metrics_dump_exporter.sh --prom-ns portworx --since-days 3
#   px_metrics_dump_exporter.sh --prom-ns portworx --since-days 1 --match-prefix px
#   px_metrics_dump_exporter.sh --prom-ns portworx --min-ms 1730000000000 --max-ms 1730100000000 --match-prefix px --output metrics.om
#   px_metrics_dump_exporter.sh --prom-ns openshift-user-workload-monitoring --since-days 1 --match-prefix px --cli oc
#
# By default, saves to px_metrics_export_<YYYYMMDD>_<HHMMSS>.om if --output is not specified.
# Additionally creates <OUTPUT_FILE>.tar.gz containing the .om and the .log.
# ================================================================

set -euo pipefail

# --- Function: Show Help ---
show_help() {
cat << EOF
Usage: $(basename "$0") [OPTIONS]

Dump Prometheus metrics within a time range using promtool inside the Prometheus pod where PX metrics are scraped.

Required: Namespace
  --prom-ns <namespace>     Namespace where Prometheus with PX metrics is running

Required: Time range (choose exactly one):
  --since-days <N>          Use last N days to automatically set min/max time
  --min-ms <ms> [--max-ms <ms>]
                            Explicit minimum time (epoch ms), with optional max (defaults to now)

Optional:
  --match-prefix <prefix>   Metric name prefix; expands to --match '{__name__=~"(prefix)_.*"}'
                            Can be repeated. Defaults to px (i.e., px_*)
  --output <filename>       Save dump to a local file (default: px_metrics_export_<YYYYMMDD>_<HHMMSS>.om)
  --cli <kubectl|oc>        CLI to use (default: auto-detect; prefers kubectl, falls back to oc)
  -h, --help                Show this help message and exit

Notes:
  - If you provide multiple --match-prefix flags, they are OR'd into a single regex like (px|abc)_.*.
  - --since-days and --min-ms/--max-ms are mutually exclusive.

Examples:
  $(basename "$0") --prom-ns portworx --since-days 3
  $(basename "$0") --prom-ns portworx --min-ms 1730000000000 --max-ms 1730100000000 --match-prefix px --output metrics.om
  $(basename "$0") --prom-ns openshift-user-workload-monitoring --since-days 3 --match-prefix px --cli oc
EOF
}

# --- Defaults ---
PROM_NAMESPACE=""
SINCE_DAYS=""
MIN_MS=""
MAX_MS=""
OUTPUT_FILE=""
declare -a MATCH_PREFIXES=("px")
CLI_CHOICE=""

# --- Helper: to UTC string from epoch ms ---
to_utc() {
  local ms="$1"
  [[ "$ms" =~ ^[0-9]+$ ]] || { echo "N/A"; return; }
  local s=$(( ms / 1000 ))
  local frac
  frac=$(printf "%03d" $(( ms % 1000 )))

  # GNU date (Linux)
  if date -u -d "@$s" +%Y-%m-%dT%H:%M:%S >/dev/null 2>&1; then
    date -u -d "@$s" +"%Y-%m-%dT%H:%M:%S.${frac}Z"
    return
  fi
  # BSD date (macOS)
  if date -u -r "$s" +%Y-%m-%dT%H:%M:%S >/dev/null 2>&1; then
    date -u -r "$s" +"%Y-%m-%dT%H:%M:%S.${frac}Z"
    return
  fi
  echo "${s}.${frac}Z"
}

# --- Helper: perform analysis of output file ---
perform_analysis() {
  local f="$1"
  echo "Starting the validation of the exported metrics dump"
  if [[ ! -s "$f" ]]; then
    echo "Analysis: file is empty or missing."
    return
  fi

  # Counts unique metric names and extracts min/max timestamps.
  # Accepts timestamps as ints/floats/scientific notation in SECONDS (with decimals),
  # MILLISECONDS, or NANOSECONDS and normalizes to epoch milliseconds.
  read -r METRIC_COUNT MIN_MS_FOUND MAX_MS_FOUND < <(awk '
  function isnum(s) {
    return (s ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/)
  }
  function to_ms(ts,    abs_ts) {
    abs_ts = (ts < 0 ? -ts : ts)
    if (abs_ts >= 1e14)      return int(ts/1e6 + 0.5)   # ns -> ms
    else if (abs_ts >= 1e12) return int(ts + 0.5)       # ms
    else if (abs_ts >= 1e9)  return int(ts*1000 + 0.5)  # s -> ms
    else if (abs_ts >= 1e7)  return int(ts*1000 + 0.5)  # s small
    else                     return -1
  }
  BEGIN { min_ms=-1; max_ms=-1; names=0; }
  /^[[:space:]]*#/ { next }        # skip comments/OM metadata
  NF==0 { next }                   # skip blanks
  {
    name=$1
    lb=index(name,"{"); if (lb>0) name=substr(name,1,lb-1)
    if (!(name in seen)) { seen[name]=1; names++ }

    if (NF>=3 && isnum($3)) {
      ts=$3+0
      ms=to_ms(ts)
      if (ms>0) {
        if (min_ms<0 || ms<min_ms) min_ms=ms
        if (max_ms<0 || ms>max_ms) max_ms=ms
      }
    }
  }
  END { print names, (min_ms<0?"NA":min_ms), (max_ms<0?"NA":max_ms) }
  ' "$f")

  echo
  echo "===Validation Summary for presence of metrics on exported file==="
  echo "  - Total Metrics lines                       : $(wc -l < "$f")"
  echo "  - Total unique Metrics count                : ${METRIC_COUNT}"

  if [[ "$MIN_MS_FOUND" != "NA" ]]; then
    echo "  - Available PX metrics Start time (UTC)     : $(to_utc "$MIN_MS_FOUND")  [epoch_ms: $MIN_MS_FOUND]"
  else
    echo "  - Available PX metrics Start time (UTC)     : N/A (no timestamps detected)"
  fi

  if [[ "$MAX_MS_FOUND" != "NA" ]]; then
    echo "  - Available PX metrics End time (UTC)       : $(to_utc "$MAX_MS_FOUND")  [epoch_ms: $MAX_MS_FOUND]"
  else
    echo "  - Available PX metrics End time (UTC)       : N/A (no timestamps detected)"
  fi
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prom-ns)
      PROM_NAMESPACE="${2:-}"
      shift 2
      ;;
    --cli)
      CLI_CHOICE="${2:-}"
      shift 2
      ;;
    --since-days)
      SINCE_DAYS="${2:-}"
      shift 2
      ;;
    --min-ms)
      MIN_MS="${2:-}"
      shift 2
      ;;
    --max-ms)
      MAX_MS="${2:-}"
      shift 2
      ;;
    --match-prefix)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --match-prefix requires a prefix (e.g., px)."
        exit 1
      fi
      prefix="$2"
      if [[ ! "$prefix" =~ ^[A-Za-z_:][A-Za-z0-9_:]*$ ]]; then
        echo "Error: --match-prefix '$prefix' is not a valid Prometheus metric prefix. Allowed: ^[A-Za-z_:][A-Za-z0-9_:]*$"
        exit 1
      fi
      MATCH_PREFIXES+=("$prefix")
      shift 2
      ;;
    --output)
      OUTPUT_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Error: Unknown option '$1'"
      echo
      show_help
      exit 1
      ;;
  esac
done

# Prompt for namespace if not provided
if [[ -z "$PROM_NAMESPACE" ]]; then
  read -r -p "[USER-INPUT-1] Enter Prometheus namespace where PX metrics are exported (e.g., 'portworx' if px-built-in prometheus, 'openshift-user-workload-monitoring' if OCP Thanos-Prometheus): " PROM_NAMESPACE
  if [[ -z "$PROM_NAMESPACE" ]]; then
    echo "Error: Namespace cannot be empty."
    exit 1
  fi
fi

if [[ -z "$SINCE_DAYS" && -z "$MIN_MS" ]]; then
  read -r -p "[USER-INPUT-2] Enter past number of days to export px metrics (e.g., 7): " SINCE_DAYS
  if [[ -z "$SINCE_DAYS" ]]; then
    echo "Error: Time range is needed"
    exit 1
  fi
fi

# --- Validate Required Arguments ---
if [[ -z "$PROM_NAMESPACE" ]]; then
  echo "Error: --prom-ns <namespace> is required."
  echo
  show_help
  exit 1
fi

# Enforce required time range: exactly one of --since-days or --min-ms
if [[ -z "$SINCE_DAYS" && -z "$MIN_MS" ]]; then
  echo "Error: You must specify either --since-days <N> or --min-ms <ms> (with optional --max-ms)."
  exit 1
fi
if [[ -n "$SINCE_DAYS" && -n "$MIN_MS" ]]; then
  echo "Error: Do not combine --since-days with --min-ms/--max-ms. Choose one method."
  exit 1
fi
if [[ -n "$SINCE_DAYS" && -n "$MAX_MS" ]]; then
  echo "Error: Do not combine --since-days with --max-ms. --since-days sets both min/max automatically."
  exit 1
fi

# --- Validate Optional Numeric Inputs ---
if [[ -n "$SINCE_DAYS" && ! "$SINCE_DAYS" =~ ^[0-9]+$ ]]; then
  echo "Error: --since-days must be numeric."
  exit 1
fi
if [[ -n "$MIN_MS" && ! "$MIN_MS" =~ ^[0-9]+$ ]]; then
  echo "Error: --min-ms must be numeric."
  exit 1
fi
if [[ -n "$MAX_MS" && ! "$MAX_MS" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-ms must be numeric."
  exit 1
fi

# --- Resolve CLI (kubectl/oc) ---
CLI_BIN=""
if [[ -n "$CLI_CHOICE" ]]; then
  if [[ "$CLI_CHOICE" != "kubectl" && "$CLI_CHOICE" != "oc" ]]; then
    echo "Error: --cli must be either 'kubectl' or 'oc'."
    exit 1
  fi
  if ! command -v "$CLI_CHOICE" >/dev/null 2>&1; then
    echo "Error: '$CLI_CHOICE' not found in PATH."
    exit 1
  fi
  CLI_BIN="$CLI_CHOICE"
else
  if command -v kubectl >/dev/null 2>&1; then
    CLI_BIN="kubectl"
  elif command -v oc >/dev/null 2>&1; then
    CLI_BIN="oc"
  else
    echo "Error: Neither 'kubectl' nor 'oc' found in PATH. Install one or specify with --cli."
    exit 1
  fi
fi

# --- Calculate Time Range if --since-days is provided ---
if [[ -n "$SINCE_DAYS" && -z "$MIN_MS" && -z "$MAX_MS" ]]; then
  echo "Calculating time range for last $SINCE_DAYS day(s)..."
  CURRENT_MS=$(($(date +%s) * 1000))
  MIN_MS=$(($(date -d "-${SINCE_DAYS} days" +%s) * 1000))
  MAX_MS=$CURRENT_MS
fi

# --- Find Prometheus Pod ---
POD_NAME=$("$CLI_BIN" -n "$PROM_NAMESPACE" get pods -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$POD_NAME" ]]; then
  echo "Error: Could not find a Prometheus pod in namespace '$PROM_NAMESPACE'."
  echo "   Please check your namespace or modify the label selector in the script."
  exit 1
fi
echo "Found Prometheus pod: $POD_NAME"

# --- Build Command Dynamically ---
CMD=("$CLI_BIN" -n "$PROM_NAMESPACE" exec "$POD_NAME" -- promtool tsdb dump-openmetrics)

if [[ -n "$MIN_MS" ]]; then
  CMD+=(--min-time="$MIN_MS")
fi
if [[ -n "$MAX_MS" ]]; then
  CMD+=(--max-time="$MAX_MS")
fi

# Build a single OR-regex for all prefixes: (p1|p2|...|pn)_.*
if ((${#MATCH_PREFIXES[@]} > 0)); then
  # de-duplicate while preserving order
  declare -A seen_prefix
  unique_prefixes=()
  for p in "${MATCH_PREFIXES[@]}"; do
    if [[ -z "${seen_prefix[$p]:-}" ]]; then
      seen_prefix[$p]=1
      unique_prefixes+=("$p")
    fi
  done
  joined=$(printf "|%s" "${unique_prefixes[@]}")
  joined="${joined:1}"
  pattern="{__name__=~\"(${joined})_.*\"}"
  CMD+=(--match="$pattern")
fi

# Data directory inside Prometheus container
CMD+=("/prometheus")

# --- Set Default Output Filename ---
if [[ -z "$OUTPUT_FILE" ]]; then
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  OUTPUT_FILE="px_metrics_export_${TIMESTAMP}.om"
fi

# --- Logging: capture stdout+stderr to a log file named after the OUTPUT_FILE ---
LOG_FILE="${OUTPUT_FILE%.om}.log"
# Start logging from this point onward
exec > >(tee -a "$LOG_FILE") 2>&1

# Package artifacts helper (called on success and on error)
package_artifacts() {
  echo "Compressing the generated metrics file"
  local tar_name="${OUTPUT_FILE}.tar.gz"
  local files=()
  [[ -f "$OUTPUT_FILE" ]] && files+=("$OUTPUT_FILE")
  [[ -f "$LOG_FILE" ]] && files+=("$LOG_FILE")

  if ((${#files[@]} == 0)); then
    echo "No artifacts found to package."
    return 0
  fi

  tar -czf "$tar_name" "${files[@]}"
  echo
  echo "Packaged artifacts into: $(realpath "$tar_name" 2>/dev/null || echo "$tar_name")"
  echo
}

# If any command fails, package whatever we have so far
trap 'echo "An error occurred. Packaging partial artifacts..."; package_artifacts' ERR

# --- Execute Command ---
echo
echo "=======SUMMARY======"
echo "    Using CLI         : $CLI_BIN"
echo "    Min time          : $MIN_MS (UTC: $(to_utc "$MIN_MS"))"
echo "    Max time          : $MAX_MS (UTC: $(to_utc "$MAX_MS"))"
echo "    Getting from pod  : $POD_NAME (namespace: $PROM_NAMESPACE)"
echo "    Saving output to  : $OUTPUT_FILE"
echo
echo "Extracting PX metrics from $POD_NAME and saving at $(realpath "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")"
echo "Extraction In-Progress ... ..."
"${CMD[@]}" > "$OUTPUT_FILE"
echo
echo "Extraction completed. File saved at: $(realpath "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")"
echo
# --- Post-extraction analysis ---
perform_analysis "$OUTPUT_FILE"

# --- Package logs + output into tar.gz named after OUTPUT_FILE ---
package_artifacts

echo "Done."
