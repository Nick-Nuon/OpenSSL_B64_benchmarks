#!/usr/bin/env bash
set -euo pipefail

# Usage: ./b64_enc_bench_core.sh /path/to/openssl is_control(optional)
OPENSSL_ROOT="${1:-}"
if [[ -z "${OPENSSL_ROOT}" ]]; then
  read -rp "Path to OpenSSL source/build dir: " OPENSSL_ROOT
fi
if [[ ! -d "$OPENSSL_ROOT" ]]; then
  echo "❌ '$OPENSSL_ROOT' is not a directory"; exit 1
fi

# --- parse is_control boolean (optional second arg) ---

IS_CONTROL="false"  # default

if [[ $# -ge 2 ]]; then
  case "$2" in
    1|true|TRUE|True|yes|YES|y|Y)
      IS_CONTROL="true"
      ;;
    0|false|FALSE|False|no|NO|n|N|"")
      IS_CONTROL="false"
      ;;
    *)
      echo "⚠️ Unknown is_control value '$2' (expected true/false or 1/0); defaulting to false."
      IS_CONTROL="false"
      ;;
  esac
fi


if [[ "$(uname -s)" != "Linux" ]]; then
  echo "❌ This script must be run on Linux. Detected: $(uname -s)"; exit 1
fi

# Benchmark repo root (this script's directory)
BENCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
PERF_BIN="$BENCH_ROOT/perf_basic"

echo "🔍 BENCH_ROOT   = $BENCH_ROOT"
echo "🔍 OPENSSL_ROOT = $OPENSSL_ROOT"
echo "🔍 IS_CONTROL   = $IS_CONTROL"

DATA_EMAIL="$BENCH_ROOT/benchmark_data/email_bin"
DATA_MULA="$BENCH_ROOT/benchmark_data/Mula_img"

if [[ ! -d "$DATA_EMAIL" || ! -d "$DATA_MULA" ]]; then
  echo "❌ Could not find datasets under BENCH_ROOT:"
  echo "   EMAIL: $DATA_EMAIL"
  echo "   MULA : $DATA_MULA"
  exit 1
fi


# encode.c + harness are always required
for f in \
  "$OPENSSL_ROOT/crypto/evp/encode.c" \
  "$BENCH_ROOT/base64_encoding_benchmark.c"
do
  [[ -f "$f" ]] || { echo "❌ Missing required source: $f"; exit 1; }
done

# extra implementations only for non-control builds
if [[ "$IS_CONTROL" == "false" ]]; then
  for f in \
    "$OPENSSL_ROOT/crypto/evp/enc_b64_scalar.c" \
    "$OPENSSL_ROOT/crypto/evp/enc_b64_avx2.c"
  do
    [[ -f "$f" ]] || { echo "❌ Missing experimental source: $f"; exit 1; }
  done
fi

# Log dirs (keep same style as before)
mkdir -p "$BENCH_ROOT/util/benchmark_results" "$BENCH_ROOT/benchmark_results"

build_phase() {
  local CC_NAME="$1"  # gcc or clang
  # local LOGFILE="$BENCH_ROOT/benchmark_results/base64_benchmark_${CC_NAME}_$(date +'%Y-%m-%d_%H-%M-%S').log"
  # Choose output dir based on whether this is a control run
  local OUT_DIR
  if [[ "$IS_CONTROL" == "true" ]]; then
      OUT_DIR="$BENCH_ROOT/OpenSSL_benchmark_control"
  else
      OUT_DIR="$BENCH_ROOT/benchmark_results"
  fi

  mkdir -p "$OUT_DIR"

  local LOGFILE="$OUT_DIR/base64_benchmark_${CC_NAME}_$(date +'%Y-%m-%d_%H-%M-%S').log"


  echo
  echo "────────────────────────────────────────────────────────"
  echo "🔧 Phase: $CC_NAME"
  echo "📄 Log:   $LOGFILE"
  echo "────────────────────────────────────────────────────────"

  # Build OpenSSL with requested compiler
  (
    cd "$OPENSSL_ROOT"
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

  # Compile perf_basic, optionally with extra experimental sources
  "$CC_NAME" -O3 -mavx2 \
    -I"$OPENSSL_ROOT/include" \
    -I"$OPENSSL_ROOT" -I"$OPENSSL_ROOT/crypto/evp" \
    -DOPENSSL_BUILDING_OPENSSL \
    "$TU_C" \
    "${EXTRA_SOURCES[@]}" \
    -L"$OPENSSL_ROOT" -Wl,-rpath,"$OPENSSL_ROOT" \
    -lcrypto \
    -o "$PERF_BIN"

  # Run and tee outputs to the log (no sudo → no root-owned files)
  {
    echo "📝 Logging to $LOGFILE"
    echo "Benchmark started at $(date)"
    echo "========================================================"
    echo "📂 Dataset (email) : $DATA_EMAIL"
    "$PERF_BIN" "$DATA_EMAIL"
    echo
    echo "🖼️ Dataset (images): $DATA_MULA"
    "$PERF_BIN" "$DATA_MULA"
    echo
    echo "✅ ${CC_NAME} phase complete at $(date)"
  } | tee -a "$LOGFILE"

  # Clean OpenSSL tree for next phase
  (
    cd "$OPENSSL_ROOT" &&
    make clean > /dev/null 2>&1 || true
  )
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


echo
echo "📂 Log directories:"
echo "  - Experimental (IS_CONTROL=false): $MAIN_LOG_DIR"
echo "  - Control      (IS_CONTROL=true) : $CONTROL_LOG_DIR"

echo
echo "📝 Summary:"
if [[ "$IS_CONTROL" == "true" ]]; then
  echo "  • CONTROL run: builds stock OpenSSL (encode.c only) and runs the perf harness."
  echo "  • Logs for this run are under: $CONTROL_LOG_DIR"
else
  echo "  • EXPERIMENTAL run: builds OpenSSL with your Base64 changes:"
  echo "      - crypto/evp/encode.c"
  echo "      - crypto/evp/enc_b64_scalar.c"
  echo "      - crypto/evp/enc_b64_avx2.c"
  echo "  • Logs for this run are under: $MAIN_LOG_DIR"
fi

echo "  • For each run, OpenSSL is rebuilt with both GCC and Clang (-march=native -mtune=native)."
echo "  • A unity translation unit (perf_basic_tu.c) includes encode.c and base64_encoding_benchmark.c,"
echo "    producing the 'perf_basic' binary."
echo "  • The benchmark harness runs on two datasets:"
echo "      - email_bin (email-like payloads)"
echo "      - Mula_img  (large binary image file)"
echo "  • The harness prints wall time, CPU cycles, instructions and throughput for each case."
echo