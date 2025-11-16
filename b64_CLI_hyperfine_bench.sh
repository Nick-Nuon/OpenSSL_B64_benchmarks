#!/usr/bin/env bash
set -euo pipefail

# Usage: ./b64_CLI_hyperfine_bench.sh /path/to/openssl
OPENSSL_ROOT="${1:-}"
if [[ -z "$OPENSSL_ROOT" ]]; then
  echo "Usage: $0 /path/to/openssl" >&2
  exit 2
fi
if [[ ! -d "$OPENSSL_ROOT" ]]; then
  echo "❌ '$OPENSSL_ROOT' is not a directory"; exit 1
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "❌ This script must be run on Linux. Detected: $(uname -s)"; exit 1
fi
command -v hyperfine >/dev/null || { echo "❌ hyperfine not found. Install it first."; exit 1; }

# ---------- Parse optional CONTROL flag ----------
IS_CONTROL="false"
if [[ $# -ge 2 ]]; then
  case "$2" in
    1|true|TRUE|yes|YES|y|Y)
      IS_CONTROL="true"
      ;;
    0|false|FALSE|no|NO|n|N|"")
      IS_CONTROL="false"
      ;;
    *)
      echo "⚠️ Unknown is_control value '$2' → defaulting to false."
      IS_CONTROL="false"
      ;;
  esac
fi

# Bench repo root (this script’s dir)
BENCH_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Datasets: prefer in bench repo; else fallback to OpenSSL tree
DATA_EMAIL="$BENCH_ROOT/benchmark_data/email_bin"
DATA_MULA="$BENCH_ROOT/benchmark_data/Mula_img"
DATA_ONEBIG="$BENCH_ROOT/benchmark_data/one_big_file"

if [[ ! -d "$DATA_EMAIL" || ! -d "$DATA_MULA" || ! -d "$DATA_ONEBIG" ]]; then
  echo "❌ Could not find datasets at:"
  echo "  $BENCH_ROOT/benchmark_data/{email_bin,Mula_img,one_big_file}"
  exit 1
fi

# Logs/results live in the benchmark repo
# LOGDIR="$BENCH_ROOT/benchmark_results"

# ---------- Output directories (switch based on control flag) ----------
if [[ "$IS_CONTROL" == "true" ]]; then
  LOGDIR="$BENCH_ROOT/CLI_hyperfine_control"
else
  LOGDIR="$BENCH_ROOT/CLI_hyperfine_results"
fi
mkdir -p "$LOGDIR"

LOGFILE="$LOGDIR/base64_benchmark_CLI_gcc_$(date +'%Y-%m-%d_%H-%M-%S').log"
: > "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

echo "📝 Logging to $LOGFILE"
echo "🔍 BENCH_ROOT   = $BENCH_ROOT"
echo "🔍 OPENSSL_ROOT = $OPENSSL_ROOT"
echo "🔍 DATA_EMAIL   = $DATA_EMAIL"
echo "🔍 DATA_MULA    = $DATA_MULA"
echo "🔍 DATA_ONEBIG  = $DATA_ONEBIG"
echo "Started at $(date)"
echo "========================================================"

# Build OpenSSL (gcc, native tune)
echo "🛠️  Configuring and building OpenSSL with gcc (-march=native -mtune=native)…"
(
  cd "$OPENSSL_ROOT"
  make clean || true
  ./config -march=native -mtune=native
  echo "🛠️  Building OpenSSL…"
  make -j"$(nproc)"
)

# Run hyperfine from inside OPENSSL_ROOT but use absolute dataset paths
run_hf_dir() {
  local label="$1"; shift
  local dir="$1"; shift
  local flag="$1"; shift

  echo "$label"
  (
    cd "$OPENSSL_ROOT"
    # ensure we use freshly built libcrypto
    LD_LIBRARY_PATH="$OPENSSL_ROOT:$OPENSSL_ROOT/lib" \
    hyperfine --warmup 500 --min-runs 2000 \
      "for f in \"$dir\"/*; do [ -f \"\$f\" ] && ./apps/openssl enc -base64 $flag -in \"\$f\" > /dev/null; done"
  )
}

run_hf_one() {
  local label="$1"; shift
  local file="$1"; shift
  local flag="$1"; shift

  echo "$label"
  (
    cd "$OPENSSL_ROOT"
    LD_LIBRARY_PATH="$OPENSSL_ROOT:$OPENSSL_ROOT/lib" \
    hyperfine --warmup 1000 --min-runs 4000 \
      "./apps/openssl enc -base64 $flag -in \"$file\" > /dev/null"
  )
}

run_benchmarks() {
  local mode_flag="$1"
  local mode_name="$2"

  echo
  echo "============== $mode_name ============================="

  # A single canonical file
  local lena="$DATA_MULA/lena_color_512.jpg"
  if [[ -f "$lena" ]]; then
    run_hf_one "📏 Benchmark: Single file (lena_color_512.jpg)" "$lena" "$mode_flag"
  else
    echo "⚠️  Missing $lena — skipping single-file test"
  fi

  run_hf_dir "📦 Benchmark: All files in Mula_img"   "$DATA_MULA"   "$mode_flag"
  run_hf_dir "📨 Benchmark: All files in email_bin" "$DATA_EMAIL"  "$mode_flag"

  # Pride and Prejudice big file
  local big="$DATA_ONEBIG/pg1342-images-kf8.mobi"
  if [[ -f "$big" ]]; then
    echo "📨 Benchmark: Pride and Prejudice (one_big_file)"
    (
      cd "$OPENSSL_ROOT"
      LD_LIBRARY_PATH="$OPENSSL_ROOT:$OPENSSL_ROOT/lib" \
      hyperfine --warmup 500 --min-runs 2000 \
        "./apps/openssl enc -base64 $mode_flag -in \"$big\" > /dev/null"
    )
  else
    echo "⚠️  Missing $big — skipping one_big_file test"
  fi
}

# Run: -A (no newlines) and default PEM mode
run_benchmarks "-A" "DISABLE NEWLINES MODE (CLI)"
run_benchmarks ""   "PEM MODE (CLI)"

echo
echo "🧪 Buffer-size sweep on the big file (no newlines)…"
BIGFILE="$DATA_ONEBIG/pg1342-images-kf8.mobi"
if [[ -f "$BIGFILE" ]]; then
  for bsize in 1024 4096 8192 16384 65536 262144 1048576 4194304 16777216 25335028; do
    echo "📨 Benchmark: -bufsize $bsize"
    (
      cd "$OPENSSL_ROOT"
      LD_LIBRARY_PATH="$OPENSSL_ROOT:$OPENSSL_ROOT/lib" \
      hyperfine --warmup 500 --min-runs 2000 \
        "./apps/openssl enc -base64 -A -bufsize $bsize -in \"$BIGFILE\" > /dev/null"
    )
  done
else
  echo "⚠️  Missing $BIGFILE — skipping buffer-size sweep"
fi

echo
echo "✅ Benchmarks complete at $(date)"
echo "Logs: $LOGFILE"
