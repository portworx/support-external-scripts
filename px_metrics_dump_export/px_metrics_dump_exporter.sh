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
#   px_metrics_dump_exporter.sh --prom-ns portworx --since-days 1 --match-prefix px,node,kube
#   px_metrics_dump_exporter.sh --prom-ns portworx --since-days 1 --match-prefix '*'
#   px_metrics_dump_exporter.sh --prom-ns portworx --min-ms 1730000000000 --max-ms 1730100000000 --match-prefix px --output metrics.om
#   px_metrics_dump_exporter.sh --prom-ns openshift-user-workload-monitoring --since-days 1 --match-prefix px --cli oc
#   px_metrics_dump_exporter.sh --prom-ns portworx --since-days 7 --chunk-hours 6 --chunk-sleep 5
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
  --match-prefix <prefix>   Metric name prefix filter. Defaults to px (i.e., px_*).
                            The first explicit --match-prefix REPLACES the default px;
                            repeat the flag or use a comma list to combine prefixes.
                            Use '*' to dump ALL metrics (no filter applied).
                            Examples:
                              --match-prefix node              (node_* only)
                              --match-prefix px,node           (px_* and node_*)
                              --match-prefix px --match-prefix node  (same as above)
                              --match-prefix '*'               (everything)
  --chunk-hours <N>         Split the time range into N-hour windows and dump one chunk
                            at a time to reduce peak memory/CPU on the Prometheus pod.
                            (default: 6; use 0 to disable chunking)
  --chunk-sleep <N>         Seconds to sleep between chunks, giving the pod time to
                            garbage-collect before the next window. (default: 2)
  --output <filename>       Save dump to a local file (default: px_metrics_export_<YYYYMMDD>_<HHMMSS>.om)
  --cli <kubectl|oc>        CLI to use (default: auto-detect; prefers kubectl, falls back to oc)
  -h, --help                Show this help message and exit

Notes:
  - Without --match-prefix the script defaults to capturing only px_* metrics.
  - The first --match-prefix flag replaces the default 'px'; subsequent flags (or
    additional comma-separated tokens) are OR'd together.
  - Use '*' to skip the --match filter entirely and export every metric.
  - --since-days and --min-ms/--max-ms are mutually exclusive.
  - Chunked dumps append to a single output file; the final result is identical to a
    non-chunked dump but with a much lower peak memory footprint on the pod.

Examples:
  $(basename "$0") --prom-ns portworx --since-days 3
  $(basename "$0") --prom-ns portworx --since-days 1 --match-prefix px,node,kube
  $(basename "$0") --prom-ns portworx --since-days 1 --match-prefix '*'
  $(basename "$0") --prom-ns portworx --min-ms 1730000000000 --max-ms 1730100000000 --match-prefix px --output metrics.om
  $(basename "$0") --prom-ns portworx --since-days 7 --chunk-hours 6 --chunk-sleep 5
  $(basename "$0") --prom-ns openshift-user-workload-monitoring --since-days 3 --match-prefix px --cli oc
EOF
}

# --- Defaults ---
PROM_NAMESPACE=""
SINCE_DAYS=""
MIN_MS=""
MAX_MS=""
OUTPUT_FILE=""
declare -a MATCH_PREFIXES=("px")   # default; cleared on first explicit --match-prefix
MATCH_ALL=false
PREFIX_EXPLICITLY_SET=false        # tracks whether user gave any --match-prefix
CLI_CHOICE=""
CHUNK_HOURS=6
CHUNK_SLEEP=2

# --- Helper: portable realpath (macOS may not have GNU realpath) ---
abs_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null || echo "$p"
  else
    # Pure bash fallback: resolve relative paths against $PWD
    case "$p" in
      /*) echo "$p" ;;
      *)  echo "$PWD/$p" ;;
    esac
  fi
}

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
        echo "Error: --match-prefix requires a value (e.g., px  or  px,node,kube  or  '*')."
        exit 1
      fi
      raw_prefix="$2"
      # '*' means dump everything — no --match filter
      if [[ "$raw_prefix" == "*" ]]; then
        MATCH_ALL=true
        MATCH_PREFIXES=()
        PREFIX_EXPLICITLY_SET=true
      else
        # First explicit --match-prefix clears the built-in "px" default so that
        # e.g. --match-prefix node captures ONLY node_* (not px_* too).
        # Repeat the flag or use a comma list to combine: --match-prefix px,node
        if [[ "$PREFIX_EXPLICITLY_SET" == false ]]; then
          MATCH_PREFIXES=()
          PREFIX_EXPLICITLY_SET=true
        fi
        # Split comma-separated list and validate each token
        IFS=',' read -ra _tokens <<< "$raw_prefix"
        for _tok in "${_tokens[@]}"; do
          _tok="${_tok// /}"   # strip any accidental spaces
          if [[ -z "$_tok" ]]; then continue; fi
          if [[ ! "$_tok" =~ ^[A-Za-z_:][A-Za-z0-9_:]*$ ]]; then
            echo "Error: --match-prefix '$_tok' is not a valid Prometheus metric prefix. Allowed: ^[A-Za-z_:][A-Za-z0-9_:]*$"
            exit 1
          fi
          MATCH_PREFIXES+=("$_tok")
        done
      fi
      shift 2
      ;;
    --chunk-hours)
      CHUNK_HOURS="${2:-}"
      shift 2
      ;;
    --chunk-sleep)
      CHUNK_SLEEP="${2:-}"
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
if [[ ! "$CHUNK_HOURS" =~ ^[0-9]+$ ]]; then
  echo "Error: --chunk-hours must be a non-negative integer."
  exit 1
fi
if [[ ! "$CHUNK_SLEEP" =~ ^[0-9]+$ ]]; then
  echo "Error: --chunk-sleep must be a non-negative integer."
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
  # Portable: pure arithmetic avoids GNU date -d / BSD date -v differences
  MIN_MS=$(( ($(date +%s) - SINCE_DAYS * 86400) * 1000 ))
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

# --- Build Base Command (without time flags — those are added per-chunk) ---
CMD_BASE=("$CLI_BIN" -n "$PROM_NAMESPACE" exec "$POD_NAME" -- promtool tsdb dump-openmetrics)

# Build a single OR-regex for all prefixes: (p1|p2|...|pn)_.*
# Skip entirely when MATCH_ALL=true (i.e. --match-prefix '*' was given)
MATCH_ARG=""
if [[ "$MATCH_ALL" == false ]] && ((${#MATCH_PREFIXES[@]} > 0)); then
  # de-duplicate while preserving order
  # Uses a string sentinel instead of declare -A so it works on bash 3.2 (macOS default)
  unique_prefixes=()
  seen_str=" "
  for p in "${MATCH_PREFIXES[@]}"; do
    if [[ "$seen_str" != *" $p "* ]]; then
      seen_str="$seen_str$p "
      unique_prefixes+=("$p")
    fi
  done
  joined=$(printf "|%s" "${unique_prefixes[@]}")
  joined="${joined:1}"
  MATCH_ARG="{__name__=~\"(${joined})_.*\"}"
fi

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
  echo "Packaged artifacts into: $(abs_path "$tar_name")"
  echo
}

# If any command fails, package whatever we have so far
trap 'echo "An error occurred. Packaging partial artifacts..."; package_artifacts' ERR

# --- Compute effective chunk size in milliseconds ---
# CHUNK_HOURS=0 disables chunking (single shot, original behaviour)
if (( CHUNK_HOURS > 0 )); then
  CHUNK_MS=$(( CHUNK_HOURS * 3600 * 1000 ))
else
  CHUNK_MS=0
fi

# --- Execute Command (chunked or single shot) ---
echo
echo "=======SUMMARY======"
echo "    Using CLI         : $CLI_BIN"
echo "    Min time          : $MIN_MS (UTC: $(to_utc "$MIN_MS"))"
echo "    Max time          : $MAX_MS (UTC: $(to_utc "$MAX_MS"))"
echo "    Getting from pod  : $POD_NAME (namespace: $PROM_NAMESPACE)"
echo "    Saving output to  : $OUTPUT_FILE"
if (( CHUNK_MS > 0 )); then
  TOTAL_MS=$(( MAX_MS - MIN_MS ))
  TOTAL_CHUNKS=$(( (TOTAL_MS + CHUNK_MS - 1) / CHUNK_MS ))
  echo "    Chunk size        : ${CHUNK_HOURS}h (${TOTAL_CHUNKS} chunk(s) total)"
  echo "    Sleep between     : ${CHUNK_SLEEP}s"
else
  echo "    Chunking          : disabled (single shot)"
fi
echo
echo "Extracting PX metrics from $POD_NAME and saving at $(abs_path "$OUTPUT_FILE")"
echo "Extraction In-Progress ... ..."

# Helper: print a command array as a single readable line
echo_cmd() {
  local arg
  local out=""
  for arg in "$@"; do
    # Shell-quote any argument that contains spaces or special characters
    if [[ "$arg" =~ [[:space:]\'\"\{\}\|\*\?] ]]; then
      out="$out '${arg//\'/\'\\\'\'}'"
    else
      out="$out $arg"
    fi
  done
  echo "  Running: ${out# }"
}

# Helper: run one promtool dump for a given [start, end) window and append to OUTPUT_FILE
run_chunk() {
  local t_start="$1"
  local t_end="$2"
  local chunk_cmd=("${CMD_BASE[@]}" --min-time="$t_start" --max-time="$t_end")
  [[ -n "$MATCH_ARG" ]] && chunk_cmd+=(--match="$MATCH_ARG")
  chunk_cmd+=("/prometheus")
  echo_cmd "${chunk_cmd[@]}"
  "${chunk_cmd[@]}" >> "$OUTPUT_FILE"
}

if (( CHUNK_MS > 0 )); then
  chunk_start=$MIN_MS
  chunk_num=0
  while (( chunk_start < MAX_MS )); do
    chunk_end=$(( chunk_start + CHUNK_MS ))
    (( chunk_end > MAX_MS )) && chunk_end=$MAX_MS
    chunk_num=$(( chunk_num + 1 ))
    echo "  Chunk ${chunk_num}/${TOTAL_CHUNKS}: $(to_utc "$chunk_start") -> $(to_utc "$chunk_end")"
    run_chunk "$chunk_start" "$chunk_end"
    chunk_start=$chunk_end
    # Sleep between chunks (skip after the last one)
    if (( chunk_start < MAX_MS && CHUNK_SLEEP > 0 )); then
      sleep "$CHUNK_SLEEP"
    fi
  done
else
  # Single-shot (original behaviour when chunking is disabled)
  chunk_cmd=("${CMD_BASE[@]}")
  [[ -n "$MIN_MS" ]] && chunk_cmd+=(--min-time="$MIN_MS")
  [[ -n "$MAX_MS" ]] && chunk_cmd+=(--max-time="$MAX_MS")
  [[ -n "$MATCH_ARG" ]] && chunk_cmd+=(--match="$MATCH_ARG")
  chunk_cmd+=("/prometheus")
  echo_cmd "${chunk_cmd[@]}"
  "${chunk_cmd[@]}" >> "$OUTPUT_FILE"
fi

echo
echo "Extraction completed. File saved at: $(abs_path "$OUTPUT_FILE")"
echo
# --- Post-extraction analysis ---
perform_analysis "$OUTPUT_FILE"

# --- Package logs + output into tar.gz named after OUTPUT_FILE ---
package_artifacts

echo "Done."
