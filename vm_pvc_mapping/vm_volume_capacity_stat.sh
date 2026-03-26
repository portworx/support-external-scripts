#!/usr/bin/env bash
# Usage: ./sum_volumes.sh SpringHill_vm_pvc_details_17Mar20261212ist.csv.csv

if [ $# -ne 1 ]; then
  echo "Usage: $0 <csv_file>"
  exit 1
fi

file="$1"

awk -F',' '
NR == 1 { next }  # skip header
{
  # Volume Size is 3rd from the end, Volume Usage is 2nd from the end
  size_field  = $(NF-2)
  usage_field = $(NF-1)

  # trim leading/trailing spaces
  gsub(/^ +| +$/, "", size_field)
  gsub(/^ +| +$/, "", usage_field)

  # ---- handle Volume Size ----
  if (size_field != "") {
    n = split(size_field, a, " ")
    if (n >= 2) {
      val  = a[1] + 0
      unit = a[2]
      if (unit ~ /GiB/) {
        total_size += val / 1024
      } else if (unit ~ /TiB/) {
        total_size += val
      }
    }
  }

  # ---- handle Volume Usage ----
  if (usage_field != "") {
    m = split(usage_field, b, " ")
    if (m >= 2) {
      val  = b[1] + 0
      unit = b[2]
      if (unit ~ /GiB/) {
        total_usage += val / 1024
      } else if (unit ~ /TiB/) {
        total_usage += val
      }
    }
  }
}
END {
  printf "Total Volume Size:  %.2f TiB\n", total_size
  printf "Total Volume Usage: %.2f TiB\n", total_usage
}
' "$file"
