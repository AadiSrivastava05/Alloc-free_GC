# Alloc-free-gc

`Alloc-free-gc` is an experimental garbage-collection runtime for a small
OCaml-style language runtime. It evaluates how far a semi-space collector can be
pushed when the collection path is implemented in OCaml/OxCaml while allocation
and heap ownership remain in a compact C runtime layer.

The project is intentionally self-contained: the runtime interface, collector
variants, benchmark driver, and result plotting scripts live in this directory.
The benchmark programs use an OCaml-style tagged value representation and the
runtime API provided in this directory, so the collector implementation and
evaluation can be built and understood as a standalone project.

## What This Project Studies

The main question is whether allocation-conscious OxCaml implementations can be
competitive with a straightforward OCaml collector when embedded behind a C
runtime ABI.

The current variants are:

| Variant | Build selector | Purpose |
| --- | --- | --- |
| Zero-alloc | `GC=zero` | OxCaml collector with zero-allocation checks on the hot collection path. |
| Zero-alloc off-heap | `GC=zero_offheap` | Stores persistent collector metadata in malloc-backed memory outside the OCaml heap. |
| Threaded off-heap | `GC=zero_offheap_threaded` | Runs the off-heap collector through a persistent sleeping GC worker thread. |
| Stack-threaded | `GC=zero_stack_threaded` | Routes collection through a long-lived OxCaml service thread so stack-local collector state can live across repeated collections. |
| Normal OCaml | `GC=normal` | Baseline collector written in ordinary OCaml without zero-allocation annotations. |

All variants use the same C allocation fast path. The selected OCaml/OxCaml
module is responsible for collection after allocation failure, so benchmarks
compare collector/root-scanning implementation style rather than allocation FFI
overhead.

## Repository Layout

```text
.
├── Makefile
├── README.md
├── runtime.c / runtime.h
├── gc_ffi.c
├── gc.ml
├── gc_zero_offheap.ml
├── gc_stack_threaded.ml
├── gc_normal.ml
├── mmtk-bindings/include/mmtk.h
├── smoke_test.c
├── benchmarks/
│   ├── README.md
│   ├── binary_tree.c
│   └── binary_tree_multithreaded.c
├── benchmarking/
│   ├── README.md
│   ├── run_gc_benchmark.sh
│   ├── plot_gc_benchmark.py
│   ├── benchmark_results.csv
│   └── benchmark_plots/
├── docs/
│   ├── architecture.md
│   └── results.md
```

Important files:

- `runtime.c` / `runtime.h`: C runtime surface, value representation, root
  stack, mutator lifecycle, allocation entry point, and stop-the-world
  coordination.
- `gc_ffi.c`: C ABI shim that embeds the OCaml/OxCaml runtime, exposes the
  `mmtk_*` functions consumed by `runtime.c`, and owns the shared semi-space
  heap and bump allocation state.
- `gc.ml`: zero-allocation OxCaml semi-space collector with OCaml-managed
  persistent metadata.
- `gc_zero_offheap.ml`: zero-allocation OxCaml collector with persistent
  metadata stored outside the OCaml heap.
- `gc_stack_threaded.ml`: stack-threaded collector service loop.
- `gc_normal.ml`: ordinary OCaml collector baseline.
- `benchmarking/`: benchmark runner, plotting script, current result CSVs, and
  generated plots.
- `benchmarks/`: standalone benchmark programs built by the project Makefile.
- `docs/`: architecture and result summaries.
- `smoke_test.c`: compact runtime smoke test used by the default `make` target.

## Requirements

- Linux or WSL with `gcc`, `make`, and POSIX threads.
- OxCaml / OCaml compiler available as `ocamlopt.opt`.
- The project has been developed with the `5.2.0+ox` switch.
- Python 3 for plotting.
- `matplotlib` for plot generation.

## Build

Build the default zero-allocation collector and smoke test:

```sh
make
./test
```

Build a specific collector variant:

```sh
make GC=zero test
make GC=zero_offheap test
make GC=zero_offheap_threaded test
make GC=zero_stack_threaded test
make GC=normal test
```

Build and run the binary-tree benchmark targets:

```sh
make GC=zero_offheap binary_tree_test binary_tree_multithreaded_test
./binary_tree_test 16
./binary_tree_multithreaded_test 14 4
```

## Benchmark

Run the full benchmark matrix:

```sh
./benchmarking/run_gc_benchmark.sh
```

Generate plots and summary CSVs:

```sh
python3 benchmarking/plot_gc_benchmark.py \
  --csv benchmarking/benchmark_results.csv
```

See [`benchmarking/README.md`](benchmarking/README.md) for configurable depths,
thread counts, repetitions, and variant subsets.

## Current Results

The checked-in benchmark artifacts show a modest but useful signal:

- `zero_offheap` has the best aggregate mean in the current benchmark matrix.
- `zero_stack_threaded` and `zero_offheap_threaded` are competitive on larger
  depth/thread configurations.
- Differences among OxCaml variants are small enough that repeated runs are
  required before making strong claims.

Useful artifacts:

- `benchmarking/benchmark_results.csv`
- `benchmarking/benchmark_plots/summary_stats.csv`
- `benchmarking/benchmark_plots/normal_relative_speedup.csv`
- `benchmarking/benchmark_plots/*.png`

## Design Notes

The runtime uses a semi-space heap with explicit root registration. Mutator
threads push addresses of local pointer variables onto a thread-local root
stack. During collection, the collector scans static roots, active mutator root
stacks, and return-value roots, then performs Cheney-style traversal over
objects copied into to-space.

OxCaml zero-allocation annotations are used to keep bounded collector hot paths
from allocating in the OCaml heap. The off-heap and stack-threaded variants
experiment with reducing long-lived metadata pressure and making stack-local
collector state practical across repeated collections.

## Cleaning

Remove local build products:

```sh
make clean
```

The `.gitignore` file excludes compiler outputs and local benchmark binaries so
future commits can focus on source, documentation, scripts, and intentionally
published result artifacts.
