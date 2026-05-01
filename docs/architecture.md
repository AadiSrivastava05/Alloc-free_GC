# Architecture

`Alloc-free-gc` is split into three layers:

1. A small C runtime surface for allocation, root registration, thread startup,
   and stop-the-world coordination.
2. A C FFI shim that owns the semi-space heap and embeds OCaml/OxCaml.
3. One selected OCaml/OxCaml collector implementation.

This layout keeps the allocation fast path identical across collector variants.
The benchmark therefore compares collection and root-scanning implementation
style instead of measuring unrelated allocation ABI differences.

## Value Representation

The runtime uses an OCaml-style tagged-word representation:

- integers have low bit `1`;
- heap pointers have low bit `0`;
- object bodies are returned to the mutator;
- each object header is stored one word before the body pointer.

The object header stores the object size in words and the tag. During copying,
the old header is overwritten with a forwarding marker and the first payload
slot stores the forwarded body pointer.

## Root Management

Root tracking is explicit. Each mutator owns:

- a thread-local root stack;
- a stack index;
- a return-value root slot;
- an active/inactive flag in collector metadata.

Local pointer variables are registered by address. During collection, the
collector updates those addresses in place after copying any referenced object.

## Stop-the-world Protocol

Collection is triggered when the C allocation fast path cannot satisfy a
request from the current semi-space. The requesting mutator:

1. marks GC as requested;
2. waits until active mutators reach a polling/allocation point;
3. invokes the selected collector implementation;
4. clears the GC request; and
5. wakes stopped mutators.

The collector itself is still stop-the-world. The project experiments with how
the stopped-world collection logic should be implemented, not with concurrent
collection.

## Collector Variants

### `normal`

Ordinary OCaml implementation of the semi-space collector. It is the baseline
for measuring whether zero-allocation-oriented code is worthwhile.

### `zero`

OxCaml implementation with zero-allocation checks on the hot path. It avoids
ordinary OCaml allocation in the collector loop but keeps persistent metadata in
OCaml arrays.

### `zero_offheap`

Moves persistent collector metadata to malloc-backed memory. The collector uses
no-allocation C stubs to load and store metadata.

### `zero_offheap_threaded`

Uses the same off-heap collector but runs collection through a persistent GC
worker thread. Allocation failure wakes the worker after the mutator world is
stopped.

### `zero_stack_threaded`

Routes collection through a long-lived OxCaml service-thread loop. C owns the
mutator metadata, while the OxCaml worker performs only the collection logic.
This makes stack-local collector state practical across repeated collection
cycles.
