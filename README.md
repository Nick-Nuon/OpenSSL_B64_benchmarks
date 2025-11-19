# OpenSSL Base64 Encoding Benchmark Suite Usage guide.

Benchmarking framework for measuring and analyzing the performance of Base64 encoding in OpenSSL. 
It supports benchmarking both the OpenSSL API (EVP_EncodeUpdate + EVP_EncodeFinal in combination) and the OpenSSL command-line tool (openssl enc -base64), including comparisons against a control OpenSSL build (as of 11/14/25).

Recommended pre-requisites:
Linux
Python 3.10+ (It may work on older versions, but it has only been tested in that version) as well as matplotlib

## Installation

First, clone the benchmark tools themselves.

```
git clone https://github.com/Nick-Nuon/OpenSSL_B64_benchmarks/
```

It is recommended to have two different installation of openssl, one improved and 
and one to use as a control :

```
git clone https://github.com/Nick-Nuon/openssl /path/to/openssl_improved/
```
```
git clone https://github.com/openssl/openssl /path/to/openssl_control/
```


## Datasets

The benchmarks are hardcoded to use three datasets as reference (included in this repo):
-A subset of emails from the Enron Dataset
-A number of small jpeg images (Mula data)
-the .mobi version of "Pride and prejudice",a 24.2 mb file

## Benchmarking the Base64 Encoding API Functions

From there the suite has a number of tools. 

In order to benchmark the Base64 API functions, you may enter this command:

```
./b64_API.sh /path_to/improved_b64_openssl/ 
```

Add the argument "true" if you're benchmarking the original OpenSSL repository:

```
./b64_API.sh /path_to/control_openssl/ true 
```

This will output two logs: one for clang and one for gcc.
It benchmarks NO_NL mode, PEM mode with and without the SRP alphabet. 
There is an undocumented feature where with enough will, a developper can change the ctx->length variable to another value and insert newlines at diffirent intervals than default modes. It is benchmarked for completeness
with ctx-> length ranging from 1 to 80. 

## Benchmarking CLI Base64 Encoding

In order to benchmark the CLI functions, we use the  hyperfine library. We benchmark against the one single image, three datasets, but also in both NO_NL and PEM mode. We also benchmark against the large file in order to test the effect of setting the CLI's buffer size.

In order to run this benchmarking, you may run this command:

```
./b64_CLI_hyperf.sh /path/to/modifed_openssl
```

Add the argument "true" if you're benchmarking against the unmodified openssl: 

```
./b64_CLI_hyperf.sh /path/to/original_openssl true
```

## Benchmarking small size input in the CLI

In order to test the limits of our perf improvements with very small files, we generate a number of randomly generated files from 1 to 2,000,000 bytes in increments of 10,000 to benchmark against.

In order to run the benchmark, you may run:

```
./b64_CLI_small.sh /path/to/improved_openssl

```
As usual , add the argument "true" if you're benchmarking the control. 

```
./b64_CLI_small.sh /path/to/improved_openssl true

```

To better vizualize it, we run a linear regression against the outputs 
of both the modified and the original OpenSSL repo and create a graph out of it: 

```
python3 b64_CLI_small.sh
```

## Nicely Graphing the Logs for custom interval insertions

The logs are small enough to inspect manually, but if you want a birds-eye view, 
 you may create nice graphs of custom intervals scenarios using this command:

```
./run_all_interval_plots.sh
```


