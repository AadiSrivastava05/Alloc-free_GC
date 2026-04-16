# allocation_free_gc

Pure OxCaml implementation of two semi-space copying collectors:

- `Alloc_free_gc`: fixed-footprint, zero-dynamic-allocation collector runtime.
- `Dynamic_gc`: baseline collector that allows dynamic growth/allocation.

All GC logic is implemented in OxCaml/OCaml modules (no C GC implementation).

---

## 1) Project goal

This project studies whether a semi-space collector can be made operationally allocation-free in its runtime path:

- user object allocation, GC tracing, and copy/forwarding run from pre-reserved metadata and arenas,
- synchronization avoids `Mutex` allocation-sensitive paths,
- collector correctness holds for cycles and concurrent mutators,
- a dynamic baseline exists for fair throughput comparison.

---

## 2) Theory summary

### 2.1 Semi-space copying model

Heap memory is split into two equal logical regions:

- **from-space**: currently active allocation region
- **to-space**: destination during collection

Allocation is bump-pointer in from-space.  
Collection:

1. copy all roots from from-space to to-space,
2. breadth-first scan copied objects,
3. copy transitively reachable children,
4. flip spaces and continue allocation in the new from-space.

### 2.2 Forwarding invariant

For an object at source index `i`:

- before moved: `from_space[i]` contains header,
- after moved: `from_space[i] = 0` and `from_space[i+1] = new_ptr`.

This gives idempotent copying and constant-time forwarding checks.

### 2.3 Tagged value encoding

The runtime uses OCaml-style tagging:

- odd values = immediate integers,
- even non-zero values = heap handles (encoded pointers).

This prevents confusing integers with managed references while tracing.

### 2.4 Why rooted allocation matters under concurrency

In a moving GC, a freshly allocated object that is not yet rooted can be moved by a concurrent collection before the mutator publishes it.  
To avoid this, the API includes `alloc_object_rooted`, which allocates and installs the object in a root slot as one critical operation.

---

## 3) Allocation-free runtime design (`Alloc_free_gc`)

### 3.1 Fixed footprint

The allocation-free variant uses fixed arrays allocated once at startup:

- `from_space`
- `to_space`
- `roots`

No per-collection vectors, queues, or lists are allocated.

### 3.2 Locking without `Mutex`

`Alloc_free_gc` uses a spin lock based on atomics:

- lock word: `Atomic.t int`
- acquire: CAS loop
- release: atomic store

This avoids `Mutex.lock/unlock` calls that fail `[@zero_alloc]` checks in OxCaml.

### 3.3 `[@zero_alloc]` checked hot paths

The core collector path is annotated and checked:

- `copy_value`
- `collect_unlocked`
- lock primitives
- allocation fast path (`alloc_object` / rooted variant)

If a checked function calls a potentially allocating primitive, OxCaml reports it at compile time.

### 3.4 Root protocol

Root slots are explicit and bounded.  
Mutators must keep live handles in roots across potential collection points.

API highlights:

- `alloc_object`
- `alloc_object_rooted`
- `set_root` / `get_root` / `clear_root`
- `collect`

---

## 4) Dynamic baseline (`Dynamic_gc`)

`Dynamic_gc` uses the same object model and collection semantics, but allows dynamic heap growth and standard lock usage.  
It is intentionally less constrained and serves as a benchmark/control variant.

---

## 5) “Stack heap” clarification

You asked for “heap simulated in stack if possible”.

In pure OxCaml/OCaml, a long-lived global collector arena cannot literally live on a function stack frame (it must outlive stack scopes).  
What this project does instead is the nearest runtime-equivalent:

- **fixed preallocated arena with stack-like bump discipline**
- **no dynamic resizing in allocation-free variant**
- **collector metadata and semispace traversal state kept in fixed memory**

So the behavior is “stack-style region allocation” over a fixed static runtime arena.

---

## 6) Correctness invariants

At all times:

1. `alloc_ptr` points to first free word in active space.
2. all root handles are either `0` or valid encoded pointers.
3. during collection, `scan_ptr <= free_ptr`.
4. each copied object is copied exactly once (forwarding invariant).
5. after flip, only to-space data is considered live.

---

## 7) Repository layout

- `src/gc_sig.ml` - shared collector interface
- `src/alloc_free_gc.ml` - fixed-footprint allocation-free collector
- `src/dynamic_gc.ml` - dynamic baseline collector
- `src/regional_alloc_free_gc.ml` - locality-based regional collector API (`local`/`exclave_`)
- `src/runtime_alloc_free.ml` - runtime wrapper for allocation-free variant
- `src/runtime_dynamic.ml` - runtime wrapper for baseline variant
- `test/test_gc.ml` - cycle, concurrency, exhaustion tests
- `bench/bench_gc.ml` - throughput benchmark (1/2/4/8 domains)

### 7.1 Regional local-runtime variant

`Regional_alloc_free_gc` is a second allocation-free design where the runtime state is created by `make_runtime` with `exclave_ stack_` and used via an explicit runtime parameter.

- Intended use: keep GC state in an enclosing region rather than module-global mutable state.
- API style: `alloc_object_rooted rt ...`, `collect rt`, `set_field rt ...`.
- This demonstrates OxCaml locality semantics for cross-frame local values (callee allocates into caller region).

---

## 8) Build and run (WSL + OxCaml)

Create switch:

```bash
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam install dune
```

Build:

```bash
opam exec --switch=5.2.0+ox -- dune build
```

Tests:

```bash
opam exec --switch=5.2.0+ox -- dune exec ./test/test_gc.exe
```

Benchmark:

```bash
opam exec --switch=5.2.0+ox -- dune exec ./bench/bench_gc.exe
```

CSV output columns:

- `collector`
- `threads`
- `seconds`
- `throughput_ops_per_sec`

---

## 9) Current trade-offs

- allocation-free variant is bounded by fixed arena size.
- explicit rooting is required for correctness across collection points.
- spin locking is simple and allocation-safe, but may waste CPU under heavy contention.
- dynamic variant is usually more flexible, sometimes faster at high thread counts.
