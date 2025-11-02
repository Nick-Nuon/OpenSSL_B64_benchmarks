#!/usr/bin/env bash
set -euo pipefail

# Usage: ./run_full_rebuild_bench.sh /path/to/openssl
OPENSSL_ROOT="${1:-}"
if [[ -z "${OPENSSL_ROOT}" ]]; then
  read -rp "Path to OpenSSL source/build dir: " OPENSSL_ROOT
fi
if [[ ! -d "$OPENSSL_ROOT" ]]; then
  echo "❌ '$OPENSSL_ROOT' is not a directory"; exit 1
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "❌ This script must be run on Linux. Detected: $(uname -s)"; exit 1
fi

# Benchmark repo root (this script's directory)
BENCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
PERF_BIN="$BENCH_ROOT/perf_basic"

echo "🔍 BENCH_ROOT   = $BENCH_ROOT"
echo "🔍 OPENSSL_ROOT = $OPENSSL_ROOT"

# Datasets: prefer in bench repo, else fallback to OpenSSL tree
DATA_EMAIL="$BENCH_ROOT/benchmark_data/email_bin"
DATA_MULA="$BENCH_ROOT/benchmark_data/Mula_img"
[[ -d "$DATA_EMAIL" ]] || DATA_EMAIL="$OPENSSL_ROOT/util/benchmark_data/email_bin"
[[ -d "$DATA_MULA"  ]] || DATA_MULA="$OPENSSL_ROOT/util/benchmark_data/Mula_img"
if [[ ! -d "$DATA_EMAIL" || ! -d "$DATA_MULA" ]]; then
  echo "❌ Could not find datasets at:"
  echo "  $BENCH_ROOT/benchmark_data/{email_bin,Mula_img}"
  echo "  $OPENSSL_ROOT/util/benchmark_data/{email_bin,Mula_img}"
  exit 1
fi

# Sanity on sources we will include
for f in \
  "$OPENSSL_ROOT/crypto/evp/encode.c" \
  "$OPENSSL_ROOT/crypto/evp/enc_b64_scalar.c" \
  "$OPENSSL_ROOT/crypto/evp/enc_b64_avx2.c" \
  "$BENCH_ROOT/base64_encoding_benchmark.c"
do
  [[ -f "$f" ]] || { echo "❌ Missing: $f"; exit 1; }
done

# Log dirs (keep same style as before)
mkdir -p "$BENCH_ROOT/util/benchmark_results" "$BENCH_ROOT/benchmark_results"

build_phase() {
  local CC_NAME="$1"  # gcc or clang
  local LOGFILE="$BENCH_ROOT/benchmark_results/base64_benchmark_${CC_NAME}_$(date +'%Y-%m-%d_%H-%M-%S').log"

  echo
  echo "────────────────────────────────────────────────────────"
  echo "🔧 Phase: $CC_NAME"
  echo "📄 Log:   $LOGFILE"
  echo "────────────────────────────────────────────────────────"

  # Build OpenSSL with requested compiler
  ( cd "$OPENSSL_ROOT"
    make clean || true
    if [[ "$CC_NAME" == "clang" ]]; then
      CC=clang ./config -march=native -mtune=native
      make -j"$(nproc)" CC=clang > /dev/null 2>&1
    else
      ./config -march=native -mtune=native
      make -j"$(nproc)" > /dev/null 2>&1
    fi
  )

  # Generate a unity TU with absolute, quoted includes (no macro games)
  TU_DIR="$BENCH_ROOT/.tu"
  mkdir -p "$TU_DIR"
  TU_C="$TU_DIR/perf_basic_tu.c"

cat > "$TU_C" <<EOF
#ifndef OPENSSL_BUILDING_OPENSSL
#define OPENSSL_BUILDING_OPENSSL
#endif

// Only include encode.c here to avoid duplicate DEFINE_STACK_OF expansions.
#include "$OPENSSL_ROOT/crypto/evp/encode.c"

// Pull in your benchmark harness
#include "$BENCH_ROOT/base64_encoding_benchmark.c"
EOF

    "$CC_NAME" -O3 -mavx2 \
    -I"$OPENSSL_ROOT/include" \
    -I"$OPENSSL_ROOT" -I"$OPENSSL_ROOT/crypto/evp" \
    -DOPENSSL_BUILDING_OPENSSL \
    "$TU_C" \
    "$OPENSSL_ROOT/crypto/evp/enc_b64_scalar.c" \
    "$OPENSSL_ROOT/crypto/evp/enc_b64_avx2.c" \
    -L"$OPENSSL_ROOT" -Wl,-rpath,"$OPENSSL_ROOT" \
    -lcrypto \
    -o "$PERF_BIN"



  # Run and tee outputs to the log
  {
    echo "📝 Logging to $LOGFILE"
    echo "Benchmark started at $(date)"
    echo "========================================================"
    echo "📂 Dataset (email) : $DATA_EMAIL"
    sudo "$PERF_BIN" "$DATA_EMAIL"
    echo
    echo "🖼️ Dataset (images): $DATA_MULA"
    sudo "$PERF_BIN" "$DATA_MULA"
    echo
    echo "✅ ${CC_NAME} phase complete at $(date)"
  } | tee -a "$LOGFILE"

  # Clean OpenSSL tree for next phase
  ( cd "$OPENSSL_ROOT" && make clean > /dev/null 2>&1 || true )
}

build_phase gcc
build_phase clang

echo
echo "🎉 Done."
echo "  Binary: $PERF_BIN"
echo "  Logs:   $BENCH_ROOT/benchmark_results/base64_benchmark_{gcc,clang}_*.log"
echo "  Datasets used:"
echo "    EMAIL: $DATA_EMAIL"
echo "    MULA : $DATA_MULA"
