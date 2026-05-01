# Alloc-free-gc

> ## Project Video
>
> Watch the full project explanation here:
> **[Project video and walkthrough](https://drive.google.com/drive/folders/1czzkVebyv8pj0ziYPSLh13SqE3jmnHCB?usp=sharing)**

This repository contains a research mini-project on allocation-conscious garbage
collection in OxCaml. The project asks whether a semi-space copying collector
written with OxCaml's zero-allocation and stack-oriented features can outperform
a normal OCaml implementation of the same collector.

The runtime is deliberately controlled: all collector variants share the same C
heap, object representation, root registry, stop-the-world protocol, allocation
fast path, and benchmark workload. The only thing that changes is how collector
bookkeeping is represented and how the collector is invoked.

## Research Question

Does a semi-space copying collector written using OxCaml's zero-allocation and
stack-oriented features run faster than a normal OCaml collector when both share
the same C heap, allocation fast path, object layout, and benchmark workload?

A secondary question is whether any savings from allocation-free collector code
are large enough to overcome extra costs from noalloc FFI calls, C-side scratch
state, persistent worker threads, and synchronization.

## System Overview

The project implements a small managed runtime in C and links it with
OCaml/OxCaml collector implementations.

- The heap uses two 128 MiB semi-spaces allocated with `malloc`.
- Allocation is a bump-pointer fast path into the active from-space.
- Collection is stop-the-world and uses Cheney-style copying traversal.
- Objects have a one-word header followed by payload fields.
- Tagged integers use low bit `1`; heap pointers use low bit `0`.
- C code explicitly registers roots through thread-local root stacks.
- A global thread registry exposes active thread roots to the collector.
- Mutator threads synchronize at GC safe points using pthread mutexes and
  condition variables.

During collection, the collector copies all live objects into to-space, updates
roots in place, scans copied objects until the frontier is exhausted, then swaps
the two semi-spaces. Dead objects are left behind in the old space.

## Collector Variants

All five variants implement the same copying algorithm and root scan. They
differ only in collector bookkeeping and invocation strategy.

| Variant | Source | Purpose |
| --- | --- | --- |
| `normal` | `gc_normal.ml` | Baseline OCaml collector using refs and boxed pair returns. |
| `zero` | `gc.ml` | Direct zero-allocation OxCaml rewrite using `let mutable` and unboxed tuples. |
| `zero_offheap` | `gc_zero_offheap.ml` | Moves scan/free scratch state into C globals accessed through noalloc stubs. |
| `zero_offheap_threaded` | `gc_zero_offheap_threaded.ml` | Runs the off-heap collector on a persistent OCaml-aware worker thread. |
| `zero_stack_threaded` | `gc_stack_threaded.ml` | Uses a long-lived `exclave_` service loop with stack-local collector state. |

This sequence isolates several costs: ordinary OCaml allocation in collector
bookkeeping, OxCaml zero-allocation rewriting, extra FFI traffic from C-side
state, worker-thread handoff overhead, and stack-local state in a persistent
OxCaml service loop.

## Benchmark

The benchmark is `tests/binary_tree_multithreaded.c`. Each worker builds a
stretch tree, a long-lived tree, and many temporary balanced trees. It computes
checksums after allocation and collection, so failures in root tracking,
forwarding, or pointer updates typically show up as checksum mismatches or
crashes.

The latest benchmark grid used:

- depths `10`, `11`, `12`, `13`, and `14`;
- worker counts from `1` to `8`;
- all five collector variants;
- one run per configuration;
- wall-clock elapsed time and per-collection pause time.

There are 40 configurations per variant and 200 runs total. Because each
configuration currently has one run, the results should be read directionally:
thread scheduling, filesystem effects, and pause logging can add noise.

## Results Summary

The latest report results show that the normal OCaml collector is the aggregate
winner, while allocation-free variants win selected configurations.

| Variant | Mean wall time | Fastest configs |
| --- | ---: | ---: |
| `normal` | 2.133 s | 18 / 40 |
| `zero` | 2.204 s | 10 / 40 |
| `zero_offheap` | 2.348 s | 0 / 40 |
| `zero_offheap_threaded` | 2.231 s | 6 / 40 |
| `zero_stack_threaded` | 2.220 s | 6 / 40 |

GC pause means were close across variants:

| Variant | Mean pause | p50 | p99 |
| --- | ---: | ---: | ---: |
| `normal` | 15.20 ms | 13.81 ms | 39.53 ms |
| `zero` | 15.34 ms | 14.07 ms | 40.98 ms |
| `zero_offheap` | 16.61 ms | 15.20 ms | 47.09 ms |
| `zero_offheap_threaded` | 15.97 ms | 14.73 ms | 43.71 ms |
| `zero_stack_threaded` | 15.40 ms | 14.59 ms | 41.93 ms |

The main conclusion is that allocation-free collector code is feasible and can
be competitive, but it is not automatically faster. In this implementation,
object traversal, memory copying, FFI calls, runtime entry, and worker
synchronization often offset the savings from avoiding OCaml heap allocation in
collector-local bookkeeping.

## Repository Layout

- `runtime.c`, `runtime.h` - heap allocation, object layout, root stacks,
  thread registry, and stop-the-world coordination.
- `gc_bridge.c` - OCaml runtime startup, noalloc primitive definitions,
  collector dispatch, persistent worker support, and pause logging.
- `gc_prims.ml` - shared OxCaml external declarations for heap access, root
  iteration, off-heap state, and service-loop hooks.
- `gc_normal.ml`, `gc.ml`, `gc_zero_offheap.ml`,
  `gc_zero_offheap_threaded.ml`, `gc_stack_threaded.ml` - collector variants.
- `tests/binary_tree_multithreaded.c` - correctness and performance benchmark.
- `benchmarking/` - benchmark runner, result summaries, plots, and CSV data.
- `final_report/` - full LaTeX project report and figures.

## Build

Requirements:

- OxCaml-capable `ocamlopt`;
- C compiler;
- pthreads;
- OCaml native runtime libraries.

Build all variants:

```sh
make all
```

Build a single variant:

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

Each binary is written to `bin/bench_<variant>`.

Clean build outputs:

```sh
make clean
```

## Run

Run one benchmark binary:

```sh
bin/bench_normal 10 1
```

The benchmark arguments are:

```text
bin/bench_<variant> <tree-depth> <worker-threads>
```

Run the full benchmark grid:

```sh
./benchmarking/bench.sh
```

Summarize results:

```sh
python3 benchmarking/summarize.py benchmarking/results.csv
```

Generate plots:

```sh
python3 benchmarking/plot_benchmark.py
```

Generated plots and derived CSVs are written to
`benchmarking/benchmark_plots/`.

## Report

The detailed report is in `final_report/main.tex`. It describes the runtime
invariants, root-tracking protocol, stop-the-world synchronization, C/OxCaml
bridge, collector variants, benchmark methodology, results, limitations, and
conclusions.

If LaTeX is installed, build it with:

```sh
cd final_report
pdflatex main && bibtex main && pdflatex main && pdflatex main
```
