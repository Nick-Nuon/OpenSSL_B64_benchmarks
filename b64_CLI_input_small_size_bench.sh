#!/usr/bin/env bash
# Benchmark randomly generated files across small sizes using OpenSSL CLI + hyperfine
set -euo pipefail

# Usage: ./b64_CLI_input_small_size_bench.sh /path/to/openssl
# Tunables via env:
#   MIN=1 MAX=2000000 STEP=10000       # size sweep (bytes)
#   RUNS=300 WARMUP=100                # hyperfine params
#   MODE="-A"                          # e.g., "-A" (no newlines) or "" (PEM mode)
#   CSV_TAG="no_newlines"              # appended to CSV filename

OPENSSL_ROOT="${1:-}"
if [[ -z "$OPENSSL_ROOT" ]]; then
  echo "Usage: $0 /path/to/openssl" >&2; exit 2
fi
[[ -d "$OPENSSL_ROOT" ]] || { echo "❌ '$OPENSSL_ROOT' is not a directory"; exit 1; }
[[ "$(uname -s)" == "Linux" ]] || { echo "❌ Linux only"; exit 1; }
command -v hyperfine >/dev/null || { echo "❌ hyperfine not found"; exit 1; }

# Bench repo root (this script’s dir)
BENCH_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Params
MIN="${MIN:-1}"
MAX="${MAX:-2000000}"
STEP="${STEP:-10000}"
RUNS="${RUNS:-300}"
WARMUP="${WARMUP:-100}"
MODE="${MODE:--A}"
CSV_TAG="${CSV_TAG:-no_newlines}"

# Outputs (NO util/ paths)
LOGDIR="$BENCH_ROOT/benchmark_results"
DATADIR="$BENCH_ROOT/benchmark_data/scaling_test"
mkdir -p "$LOGDIR" "$DATADIR"

CSV="$LOGDIR/small_input_size_vs_time_${CSV_TAG}_$(date +'%Y-%m-%d_%H-%M-%S').csv"
echo "input_size_bytes,time_ms" > "$CSV"

echo "🔍 BENCH_ROOT   = $BENCH_ROOT"
echo "🔍 OPENSSL_ROOT = $OPENSSL_ROOT"
echo "🔍 DATA DIR     = $DATADIR"
echo "🔍 CSV          = $CSV"
echo "🔧 MODE         = '${MODE}'"
echo "📏 Range        = ${MIN}..${MAX} step ${STEP}"
echo "🏁 Hyperfine    = warmup:${WARMUP} runs:${RUNS}"

# Build OpenSSL
(
  cd "$OPENSSL_ROOT"
  echo "🛠️  Configuring and building OpenSSL (-march=native -mtune=native)…"
  make clean || true
  ./config -march=native -mtune=native
  make -j"$(nproc)"
)

# Ensure CLI links against the freshly built libcrypto
export LD_LIBRARY_PATH="$OPENSSL_ROOT:$OPENSSL_ROOT/lib"

# Generate test files (skip existing to save time)
echo "🧪 Generating test files (${MIN}..${MAX} step ${STEP})…"
for size in $(seq "$MIN" "$STEP" "$MAX"); do
  f="$DATADIR/file_${size}.bin"
  [[ -f "$f" ]] || head -c "$size" /dev/urandom > "$f"
done

# Helper: run hyperfine from inside OPENSSL_ROOT but reference absolute paths
bench_file() {
  local file="$1"
  (
    cd "$OPENSSL_ROOT"
    hyperfine --time-unit millisecond --style=basic \
      --warmup "$WARMUP" --runs "$RUNS" \
      "./apps/openssl enc -base64 ${MODE} -in \"$file\" > /dev/null"
  )
}

echo "🚀 Running benchmarks on varying input sizes…"
for file in "$DATADIR"/*.bin; do
  size=$(stat --format=%s "$file")
  mean_ms="$(
    bench_file "$file" 2>/dev/null \
      | grep -E 'Time \(mean' \
      | awk '{print $(NF-1)}' \
      | sed 's/ms//'
  )"
  [[ -n "${mean_ms:-}" ]] || mean_ms="NaN"
  echo "$size,$mean_ms" >> "$CSV"
done

echo "✅ Benchmark complete."
echo "📊 Data saved to: $CSV"
