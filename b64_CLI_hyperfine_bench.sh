#!/bin/bash
set -e

# Check if the OS is Linux
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "❌ This script must be run on Linux. Detected: $(uname -s)"
    exit 1
fi

echo "🛠️  Configuring and building OpenSSL with gcc and -march=native -mtune=native..."

# # === Setup log file ===
LOGFILE="./benchmark_results/base64_benchmark_CLI_gcc_$(date +'%Y-%m-%d_%H-%M-%S').log"
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

echo "📝 Logging to $LOGFILE"
echo "Benchmark started at $(date)"
echo "========================================================"

# # === Configure and build OpenSSL with gcc + native CPU tuning ===

# ./config linux-x86_64-gcc -march=native -mtune=native
./config -march=native -mtune=native
make clean
echo "🛠️  Building OpenSSL quietly..."
if ! make -j"$(nproc)" > /dev/null 2>&1; then
    echo "❌ Build failed!"
    exit 1
fi

# # === Build standalone benchmark binary ===
# echo "🧪 Compiling base64_encoding_benchmark.c with GCC..."
gcc -O3 -mavx2 -I./include \
    ./util/base64_encoding_benchmark.c \
    ./crypto/evp/encode.c \
    ./crypto/evp/enc_b64_scalar.c \
    ./crypto/evp/enc_b64_avx2.c \
    -o ./util/perf_basic -lcrypto
run_hyperfine_benchmark() {
  local label="$1"
  local dir="$2"
  local flag="$3"
  echo "$label"
  LD_LIBRARY_PATH=$(pwd):$(pwd)/lib \
  hyperfine --warmup 500 --min-runs 2000 \
    "for f in $dir/*; do [ -f \"\$f\" ] && ./apps/openssl enc -base64 $flag -in \"\$f\" > /dev/null; done"
}

run_benchmarks() {
  local mode_flag="$1"
  local mode_name="$2"

  echo "============== $mode_name ============================="

  echo "📏 Benchmark: Single file (lena_color_512.jpg)"
  LD_LIBRARY_PATH=$(pwd):$(pwd)/lib \
  hyperfine --warmup 1000 --min-runs 4000 \
    "./apps/openssl enc -base64 $mode_flag -in ./util/benchmark_data/Mula_img/lena_color_512.jpg > /dev/null"

  run_hyperfine_benchmark "📦 Benchmark: All files in Mula_img" "./util/benchmark_data/Mula_img" "$mode_flag"
  run_hyperfine_benchmark "📨 Benchmark: All files in email_bin" "./util/benchmark_data/email_bin" "$mode_flag"
  run_hyperfine_benchmark "📨 Benchmark: Pride and prejudice" "./util/benchmark_data/one_big_file" "$mode_flag"
}

# Run benchmarks with default flags
run_benchmarks "-A" "DISABLE NEWLINES MODE CLI"
run_benchmarks "" "PEM MODE CLI"

# Custom one-off test (FULL FILE BUFFER)
# mode_flag="-A -bufsize 25335028"
# mode_name="DISABLE NEWLINES MODE CLI with -bufsize"
# run_hyperfine_benchmark "📨 Benchmark: Pride and prejudice with full buffer" "./util/benchmark_data/one_big_file" "$mode_flag"

echo "🧪 Running custom benchmarks with various buffer sizes..."

for bsize in 1024 4096 8192 16384 65536 262144 1048576 4194304 16777216 25335028; do
  echo "📨 Benchmark: bufsize = $bsize"
  LD_LIBRARY_PATH=$(pwd):$(pwd)/lib \
  hyperfine --warmup 500 --min-runs 2000 \
    "./apps/openssl enc -base64 -A -bufsize $bsize -in ./util/benchmark_data/one_big_file/pg1342-images-kf8.mobi > /dev/null"
done


echo "✅ Benchmarks complete at $(date)"
echo "Results logged to: $LOGFILE"