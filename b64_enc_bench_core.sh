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
DATA_BIG="$BENCH_ROOT/benchmark_data/one_big_file"

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

  # Generate a unity TU directly under BENCH_ROOT
  TU_DIR="$BENCH_ROOT"
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

    # Compile perf_basic (control vs experimental)
  if [[ "$IS_CONTROL" == "true" ]]; then
    # CONTROL: only encode.c + harness (in TU)
    "$CC_NAME" -O3 -mavx2 \
      -I"$OPENSSL_ROOT/include" \
      -I"$OPENSSL_ROOT" -I"$OPENSSL_ROOT/crypto/evp" \
      -DOPENSSL_BUILDING_OPENSSL \
      "$TU_C" \
      -L"$OPENSSL_ROOT" -Wl,-rpath,"$OPENSSL_ROOT" \
      -lcrypto \
      -o "$PERF_BIN"
  else
    # EXPERIMENTAL: add scalar + AVX2 implementations
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
  fi


  # Run and tee outputs to the log
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
    echo "📖 Dataset (pride and prejudice): $DATA_BIG"
    "$PERF_BIN" "$DATA_BIG"
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
echo "    MULA IMAGES: $DATA_MULA"
echo "    PRIDE AND PREJUDICE: $DATA_BIG"