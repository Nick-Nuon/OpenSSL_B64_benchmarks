#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./run_all_interval_plots.sh
# or:
#   MAIN_LOG=path/to/main.log CONTROL_LOG=path/to/control.log ./run_all_interval_plots.sh

# Directories containing API results & control logs
RESULTS_DIR="${RESULTS_DIR:-API_results}"
CONTROL_DIR="${CONTROL_DIR:-API_control}"

# Allow override via env vars MAIN_LOG / CONTROL_LOG
if [[ -n "${MAIN_LOG:-}" && -n "${CONTROL_LOG:-}" ]]; then
  main_log="$MAIN_LOG"
  control_log="$CONTROL_LOG"
else
  shopt -s nullglob

  result_logs=("$RESULTS_DIR"/base64_benchmark_gcc_*.log)
  control_logs=("$CONTROL_DIR"/base64_benchmark_gcc_*.log)

  if (( ${#result_logs[@]} == 0 )); then
    echo "❌ No result logs matching '$RESULTS_DIR/base64_benchmark_gcc_*.log'" >&2
    exit 1
  fi
  if (( ${#control_logs[@]} == 0 )); then
    echo "❌ No control logs matching '$CONTROL_DIR/base64_benchmark_gcc_*.log'" >&2
    exit 1
  fi

  # Pick latest by filename (timestamps are in the name)
  IFS=$'\n' sorted_results=($(printf '%s\n' "${result_logs[@]}" | sort))
  IFS=$'\n' sorted_controls=($(printf '%s\n' "${control_logs[@]}" | sort))
  unset IFS

  main_log="${sorted_results[-1]}"
  control_log="${sorted_controls[-1]}"
fi

echo "Using main   log: $main_log"
echo "Using control log: $control_log"
echo

alphabets=(STD SRP)
ranges=(ge32 ge16-32 non4)

for alpha in "${alphabets[@]}"; do
  for range in "${ranges[@]}"; do
    echo "▶ Running: alphabet=$alpha, range=$range"
    python3 plot_intervals.py "$main_log" "$control_log" "$alpha" "$range"
    echo
  done
done

echo "✅ All plots generated."
