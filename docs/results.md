# Results Summary

This project currently includes two benchmark result sets:

- `benchmarking/benchmark_results.csv`: current five-variant benchmark matrix.
- `benchmarking/results/gc_benchmark_summary.csv`: older pilot benchmark
  comparing only `normal` and `zero`.

## Current Matrix

The current matrix covers depths `11 12 13 14`, mutator thread counts `1..8`,
and five variants:

- `normal`
- `zero`
- `zero_offheap`
- `zero_offheap_threaded`
- `zero_stack_threaded`

Aggregate mean over the 32 configurations in the checked-in CSV:

| Variant | Mean time (s) |
| --- | ---: |
| `normal` | 5.127 |
| `zero` | 5.038 |
| `zero_offheap` | 4.914 |
| `zero_offheap_threaded` | 4.919 |
| `zero_stack_threaded` | 5.013 |

The strongest directional result is that `zero_offheap` and
`zero_stack_threaded` are often competitive with or faster than `normal`, but
the differences are small. Since the checked-in matrix has one run per
configuration, these numbers should be treated as directional rather than
statistically conclusive.

## Plot Artifacts

Generated plots are stored under:

```text
benchmarking/benchmark_plots/
```

Important files:

- `time_vs_threads_depth_11.png`
- `time_vs_threads_depth_12.png`
- `time_vs_threads_depth_13.png`
- `time_vs_threads_depth_14.png`
- `normal_relative_speedup.png`

## Recommendation for Stronger Measurements

For report-quality measurements, rerun with repeated samples:

```sh
REPEATS=10 ./benchmarking/run_gc_benchmark.sh
python3 benchmarking/plot_gc_benchmark.py \
  --csv benchmarking/benchmark_results.csv
```

This will make the generated `summary_stats.csv` useful for comparing variance,
not just mean runtime.
