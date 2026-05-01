# Benchmarks

This directory contains the benchmark programs used by `Alloc-free-gc`.

- `binary_tree.c`: single-threaded allocation and collection stress test.
- `binary_tree_multithreaded.c`: multi-threaded version used by the benchmark
  runner.

Both programs use the public runtime API from `runtime.h` and are built through
the project `Makefile`.
