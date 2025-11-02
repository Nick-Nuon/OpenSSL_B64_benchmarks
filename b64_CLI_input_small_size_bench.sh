#!/bin/bash
# Benchmark randomly generated files with sizes 1 → 2,000,000 bytes in steps of 10,000.
# Also benches PEM mode/disable newlines/etc. 
set -e

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "❌ This script must be run on Linux. Detected: $(uname -s)"
    exit 1
fi

echo "🛠️  Building OpenSSL with -march=native -mtune=native..."

LOGFILE="./util/benchmark_results/small_input_size_vs_time_$(date +'%Y-%m-%d_%H-%M-%S').csv"
mkdir -p "$(dirname "$LOGFILE")"
echo "input_size_bytes,time_ms" > "$LOGFILE"

./config -march=native -mtune=native
make clean
echo "🛠️  Building OpenSSL quietly..."
make -j"$(nproc)"

export LD_LIBRARY_PATH=$(pwd):$(pwd)/lib

# Create test directory and files
TEST_DIR="./util/benchmark_data/scaling_test"
mkdir -p "$TEST_DIR"

echo "🧪 Generating test files with increasing sizes..."
for size in $(seq 1 10000 2000000); do
    head -c "$size" /dev/urandom > "$TEST_DIR/file_${size}.bin"
done

echo "🚀 Running benchmarks on varying input sizes..."

for file in "$TEST_DIR"/*.bin; do
    size=$(stat --format=%s "$file")
    echo "📄 Benchmarking $file ($size bytes)..."

    # Run hyperfine and extract mean time in ms
    time_ms=$(hyperfine --warmup 100 --runs 300 \
        "./apps/openssl enc -base64 -A -bufsize 65536 -in \"$file\" > /dev/null" \
        --style=basic 2>/dev/null | \
        grep 'Time (mean' | awk '{print $5}')

    echo "$size,${time_ms:-NaN}" >> "$LOGFILE"
done


echo "✅ Benchmark complete."
echo "📊 Data saved to: $LOGFILE"
