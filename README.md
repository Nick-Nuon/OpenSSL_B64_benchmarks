# OpenSSL Base64 Benchmark Suite

Benchmarking framework for measuring and analyzing the performance of Base64 encoding in OpenSSL. 
It supports benchmarking both the OpenSSL API (EVP_EncodeUpdate + EVP_EncodeFinal in combination) and the OpenSSL command-line tool (openssl enc -base64),
including comparisons against a control OpenSSL build (as of 11/14/25).

Recommended pre-requisites:
Be on Linux! 
Python 3.10+

Installation is simple:

First, clone the benchmark tools themselves.

```
git clone https://github.com/Nick-Nuon/OpenSSL_B64_benchmarks/
```

From there, it is recommended to have two different installation of openssl:

```
git clone https://github.com/openssl/openssl /path/to/control_openssl/
```

```
https://github.com/Nick-Nuon/openssl /path/to/improved_b64_openssl/
```

From there the suite has a number of tools. 

In order to benchmark the Base64 API , you may enter this command to output two logs (one for clang and one for gcc) to the benchmark_results folder:
```
./b64_enc_bench_core.sh /path_to/improved_b64_openssl/ 
```

Add the argument "true" if you're benchmarking the original OpenSSL function to output the same logs to the OpenSSL_benchmark_control folder:
```
./b64_enc_bench_core.sh /path_to/control_openssl/ true 
```

Other tools:

CLI benchmarks using hyperfine
Input-size scaling models (linear regression)
Utilities for generating CSV logs and plots

To be continued...
