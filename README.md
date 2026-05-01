# Alloc-free-gc

Allocation-conscious semi-space garbage collection in OxCaml.

This project implements a small C runtime with a stop-the-world semi-space heap
and five OCaml/OxCaml collector variants. The goal is to compare ordinary OCaml
collector bookkeeping against progressively allocation-free, C-side, threaded,
and stack-threaded designs while keeping the heap, object layout, root tracking,
and benchmark workload fixed.

## Layout

- `runtime.c`, `runtime.h` - C runtime, heap allocation, roots, thread registry, stop-the-world coordination.
- `gc_bridge.c` - C/OxCaml bridge, noalloc primitives, collector dispatch, worker-thread coordination.
- `gc_prims.ml` - shared noalloc external declarations and helper functions.
- `gc_normal.ml` - baseline OCaml collector using refs and boxed tuple returns.
- `gc.ml` - zero-allocation OxCaml collector using `let mutable` and unboxed tuples.
- `gc_zero_offheap.ml` - zero-allocation collector with C-side scratch state.
- `gc_zero_offheap_threaded.ml` - off-heap collector invoked by a persistent worker thread.
- `gc_stack_threaded.ml` - long-lived `exclave_` service-loop collector with stack-local state.
- `tests/binary_tree_multithreaded.c` - correctness and performance benchmark.
- `benchmarking/` - benchmark, summary, and plotting scripts plus current results.
- `Report_Template/` - project report source and figures.

## Build

Requires an OxCaml-capable `ocamlopt`, a C compiler, and pthreads.

```sh
make all
```

Build one variant:

```sh
make GC=zero_stack_threaded
```

Available variants:

```text
normal
zero
zero_offheap
zero_offheap_threaded
zero_stack_threaded
```

Clean generated binaries and objects:

```sh
make clean
```

## Run

Smoke test:

```sh
bin/bench_normal 8 1
```

Full benchmark grid:

```sh
./benchmarking/bench.sh
```

Summarize current results:

```sh
python3 benchmarking/summarize.py benchmarking/results.csv
```

Generate plots:

```sh
python3 benchmarking/plot_benchmark.py
```

Plots and derived CSVs are written to `benchmarking/benchmark_plots/`.

## Report

The report source is in `Report_Template/main.tex`.

If LaTeX is installed:

```sh
cd Report_Template
pdflatex main && bibtex main && pdflatex main && pdflatex main
```

## Notes

Generated build products, benchmark run logs, pause logs, and LaTeX build files
are ignored via `.gitignore`. The committed benchmark artifacts are the compact
CSV/plot outputs needed by the report and presentation.
