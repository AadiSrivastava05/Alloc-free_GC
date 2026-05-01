#ifndef RUNTIME_H
#define RUNTIME_H

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#define HEAP_SIZE_BYTES (1L << 27)   /* 128 MiB per semi-space */
#define ROOT_STACK_SIZE (1 << 18)
#define MAX_STATIC_ROOTS 1024
#define MAX_THREADS 128

/* OCaml-style tagging: low bit = 1 -> integer, low bit = 0 -> heap pointer.
 * Pointer points at object body; header is one word before the body. */
#define Field(ptr, off) ((long *)(ptr))[off]
#define long2val(x) ((((long)(x)) << 1) + 1)
#define val2long(x) (((long)(x)) >> 1)

/* Root frame helpers (used by user-level C code) */
#define alloc_free_frame alloc_free_new_frame()
#define alloc_free_return(x) \
    return (typeof(x))alloc_free_return_with_val((long *)(x))

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t gc_off;
    pthread_cond_t world_stopped;
    pthread_cond_t resume_world;
    long num_threads;
    long num_stopped;
    bool gc_requested;
    bool world_has_stopped;
} STW_State;

extern STW_State stw_state;

/* Per-thread state (defined in runtime.c) */
extern __thread long **root_stack[ROOT_STACK_SIZE];
extern __thread long stack_idx;
extern __thread long current_frame_stack_sz[ROOT_STACK_SIZE];
extern __thread long current_frame;
extern __thread long *gc_retval;

/* Thread-registry shared between runtime and gc_bridge */
typedef struct {
    long ***root_stack_ptr;
    long *stack_idx_ptr;
    long **gc_retval_ptr;
    atomic_bool is_active;
} ThreadRegistry;

extern ThreadRegistry registry[MAX_THREADS];
extern atomic_int registered_threads;

/* Static (global) roots */
extern void *static_roots[MAX_STATIC_ROOTS];
extern atomic_int static_root_count;

/* Heap */
extern long *from_heap;
extern long *to_heap;
extern long heap_sz;        /* per-semi-space size in bytes */
extern long cur_heap_ptr;   /* offset (bytes) into from_heap */

/* User-facing API */
void init_heap(void);
long *gc_alloc(long len, long tag);

pthread_t domain_spawn(void *function);
void domain_join(pthread_t pid);

void make_static_root(long **ptr_to_var);
void make_root(long **ptr_to_var);
void make_return_root(long **ptr_to_var);

void alloc_free_new_frame(void);
void alloc_free_return_handler(void);
long *alloc_free_return_with_val(long *val);

void poll_for_gc(void);

/* Implemented in gc_bridge.c: invoked by allocator on heap exhaustion
 * (assumes the world is already stopped). */
void run_collection(void);

/* Implemented in gc_bridge.c: starts long-lived OCaml service if a
 * variant requires one (no-op for variants that don't). */
void start_gc_service(void);

#endif
