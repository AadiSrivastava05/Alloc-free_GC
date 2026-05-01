# Benchmarking

This directory contains the benchmark harness and plotting tools for
`Alloc-free-gc`.

The benchmark target is `binary_tree_multithreaded_test`, an allocation-heavy
tree construction workload using the runtime API exposed by this project. Each
worker builds a stretch tree, a long-lived tree, and many temporary trees. This
creates a useful stress test for root scanning, object copying, and mutator
coordination.

## Run

From the project root:

```sh
./benchmarking/run_gc_benchmark.sh
```

By default, this runs:

- depths: `11 12 13 14`
- mutator threads: `1 2 3 4 5 6 7 8`
- repetitions: `1`
- variants: `zero zero_offheap zero_offheap_threaded zero_stack_threaded normal`

The output CSV is:

```text
benchmarking/benchmark_results.csv
```

## Configuration

The runner is controlled with environment variables:

```sh
REPEATS=10 \
DEPTHS="12 14 16" \
THREADS="1 2 4 8" \
./benchmarking/run_gc_benchmark.sh
```

Useful examples:

```sh
OUT_CSV=benchmarking/results/run.csv \
REPEATS=5 \
DEPTHS="8 10 12" \
THREADS="4 8" \
./benchmarking/run_gc_benchmark.sh

VARIANTS="zero_offheap normal" \
REPEATS=5 \
./benchmarking/run_gc_benchmark.sh

VARIANTS="zero_stack_threaded normal" \
REPEATS=5 \
./benchmarking/run_gc_benchmark.sh
```

Supported variants:

```text
zero
zero_offheap
zero_offheap_threaded
zero_stack_threaded
normal
```

## Plot

Generate summary CSVs and plots:

```sh
python3 benchmarking/plot_gc_benchmark.py \
  --csv benchmarking/benchmark_results.csv
```

Generated outputs:

```text
benchmarking/benchmark_plots/summary_stats.csv
benchmarking/benchmark_plots/normal_relative_speedup.csv
benchmarking/benchmark_plots/time_vs_threads_depth_<depth>.png
benchmarking/benchmark_plots/normal_relative_speedup.png
```

Use `--no-plot` to only validate and summarize a CSV:

```sh
python3 benchmarking/plot_gc_benchmark.py \
  --csv benchmarking/benchmark_results.csv \
  --no-plot
```

## Interpreting Results

`normal_relative_speedup.csv` reports `normal / variant`. Values above `1.0`
mean the variant is faster than the normal OCaml collector for that
configuration.

The checked-in default result set has one run per configuration, so it is useful
for directional analysis but not for strong statistical claims. For reportable
numbers, use at least 5 to 10 repetitions:

```sh
REPEATS=10 ./benchmarking/run_gc_benchmark.sh
```
