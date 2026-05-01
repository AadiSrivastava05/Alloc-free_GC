/* gc_bridge.c — connects the C runtime to the OCaml/OxCaml collector.
 *
 * Exposes:
 *   - run_collection() / start_gc_service(): used by runtime.c
 *   - ml_* primitives: noalloc externals callable from OCaml
 *
 * The C side owns the heap and root metadata. The OCaml side reads and
 * writes these through the ml_* primitives. The collector algorithm
 * itself lives in OCaml (one of gc_*.ml).
 */

#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <errno.h>
#include <sys/stat.h>

#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/callback.h>
#include <caml/threads.h>
#include <caml/alloc.h>

/* Re-declare just the runtime-side symbols we need, without picking up
 * runtime.h's Field/long2val macros (which collide with caml/mlvalues.h). */
#define HEAP_SIZE_BYTES (1L << 27)
#define ROOT_STACK_SIZE (1 << 18)
#define MAX_STATIC_ROOTS 1024
#define MAX_THREADS 128

typedef struct {
    long ***root_stack_ptr;
    long *stack_idx_ptr;
    long **gc_retval_ptr;
    atomic_bool is_active;
} ThreadRegistry;

extern ThreadRegistry registry[MAX_THREADS];
extern atomic_int registered_threads;
extern void *static_roots[MAX_STATIC_ROOTS];
extern atomic_int static_root_count;
extern long *from_heap;
extern long *to_heap;
extern long heap_sz;
extern long cur_heap_ptr;

/* ============================================================
 * Off-heap collector scratch state (used by zero_offheap variants)
 *
 * Storing these in C lets the OCaml collector hot-path access them
 * via noalloc primitives and avoid OCaml-heap bookkeeping.
 * ============================================================ */
long g_free_ptr = 0;   /* word offset into to_heap during collection */
long g_scan_ptr = 0;
long g_used_after_collect = 0;

/* ============================================================
 * Variant dispatch
 *
 * GC_VARIANT is set by the build system. We default to "normal".
 * For variant 5 (stack_threaded) the OCaml side runs a long-lived
 * service loop; for everything else we call a plain "gc_collect".
 * ============================================================ */
#ifndef GC_VARIANT_STACK_THREADED
#define GC_VARIANT_STACK_THREADED 0
#endif

#ifndef GC_VARIANT_PERSISTENT_THREAD
/* Variants 4 and 5 keep a persistent OCaml-aware GC thread. */
#define GC_VARIANT_PERSISTENT_THREAD 0
#endif

#ifndef GC_VARIANT_NAME
#define GC_VARIANT_NAME "unknown"
#endif

static void log_pause_ns(long ns) {
    char path[256];
    if (mkdir("benchmarking", 0777) != 0 && errno != EEXIST) {
        return;
    }
    snprintf(path, sizeof(path), "benchmarking/gc_pauses_%s.csv", GC_VARIANT_NAME);
    FILE *f = fopen(path, "a");
    if (f == NULL) return;
    fprintf(f, "%s,%ld,%.9f\n", GC_VARIANT_NAME, ns, (double)ns / 1000000000.0);
    fclose(f);
}

/* ============================================================
 * OCaml runtime startup (linked-in OCaml code).
 *
 * caml_startup() runs all OCaml module initialisers (which call
 * Callback.register) and returns. Provided by libasmrun.
 * ============================================================ */
extern void caml_startup(char **argv);
extern value caml_thread_initialize(value unit);

/* Called once by main() before anything else. */
__attribute__((constructor)) static void noop_ctor(void) {
    /* no-op; caml_startup is called explicitly from main */
}

void gc_bridge_startup(int argc, char **argv) {
    /* Build a NULL-terminated argv for OCaml's startup. */
    static char *fake_argv[2] = {"alloc_free_gc", NULL};
    (void)argc; (void)argv;
    caml_startup(fake_argv);
    (void)caml_thread_initialize(Val_unit);
    caml_release_runtime_system();
}

/* ============================================================
 * Persistent GC thread (variants 4 & 5)
 * ============================================================ */
static pthread_t gc_thread;
#if !GC_VARIANT_STACK_THREADED
static pthread_mutex_t gc_cmd_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  gc_cmd_cond = PTHREAD_COND_INITIALIZER;
static pthread_cond_t  gc_done_cond = PTHREAD_COND_INITIALIZER;
static int gc_cmd_pending = 0;   /* 1 = run a collection */
static int gc_cmd_done = 0;
static int gc_cmd_shutdown = 0;
#endif
static int gc_service_started = 0;

static void *gc_worker_main(void *unused) {
    (void)unused;
    /* Register this OS thread with the OCaml runtime so it may call
     * OCaml callbacks; it returns without holding the runtime lock. */
    if (!caml_c_thread_register()) {
        fprintf(stderr, "FATAL: caml_c_thread_register failed in GC worker\n");
        exit(1);
    }
    caml_acquire_runtime_system();

#if GC_VARIANT_STACK_THREADED
    /* Hand off to the OCaml service loop, which runs forever. */
    {
        const value *closure = caml_named_value("gc_service_run");
        if (closure == NULL) {
            fprintf(stderr, "FATAL: OCaml callback gc_service_run not registered\n");
            exit(1);
        }
        (void)caml_callback(*closure, Val_unit);
    }
#else
    /* Variant 4: simple per-collection callback in this thread. */
    const value *closure = caml_named_value("gc_collect");
    if (closure == NULL) {
        fprintf(stderr, "FATAL: OCaml callback gc_collect not registered\n");
        exit(1);
    }
    for (;;) {
        pthread_mutex_lock(&gc_cmd_lock);
        while (!gc_cmd_pending && !gc_cmd_shutdown) {
            /* Drop OCaml lock while sleeping so other threads using OCaml
             * (none here, but be safe) aren't blocked. */
            caml_release_runtime_system();
            pthread_cond_wait(&gc_cmd_cond, &gc_cmd_lock);
            pthread_mutex_unlock(&gc_cmd_lock);
            caml_acquire_runtime_system();
            pthread_mutex_lock(&gc_cmd_lock);
        }
        if (gc_cmd_shutdown) { pthread_mutex_unlock(&gc_cmd_lock); break; }
        gc_cmd_pending = 0;
        pthread_mutex_unlock(&gc_cmd_lock);

        (void)caml_callback(*closure, Val_unit);

        pthread_mutex_lock(&gc_cmd_lock);
        gc_cmd_done = 1;
        pthread_cond_broadcast(&gc_done_cond);
        pthread_mutex_unlock(&gc_cmd_lock);
    }
    caml_release_runtime_system();
    caml_c_thread_unregister();
#endif
    return NULL;
}

/* For variant 5 (stack_threaded): the OCaml service loop polls a
 * shared command flag exposed via the ml_service_* externals below. */
static volatile int service_cmd_pending = 0;
static volatile int service_cmd_done = 0;
static pthread_mutex_t service_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  service_cond = PTHREAD_COND_INITIALIZER;
static pthread_cond_t  service_done_cond = PTHREAD_COND_INITIALIZER;

void start_gc_service(void) {
#if GC_VARIANT_PERSISTENT_THREAD
    if (gc_service_started) return;
    gc_service_started = 1;
    if (pthread_create(&gc_thread, NULL, gc_worker_main, NULL) != 0) {
        perror("pthread_create gc_thread");
        exit(1);
    }
    /* Give the worker a chance to pick up the OCaml runtime lock and
     * (for variant 5) start its service loop. */
    pthread_mutex_lock(&service_lock);
    /* Variant 5: the OCaml service loop signals "ready" once. We just
     * wait until first poll, no explicit signal needed. */
    pthread_mutex_unlock(&service_lock);
#else
    (void)gc_thread; (void)gc_service_started;
#if !GC_VARIANT_STACK_THREADED
    (void)gc_cmd_lock; (void)gc_cmd_cond; (void)gc_done_cond;
    (void)gc_cmd_pending; (void)gc_cmd_done; (void)gc_cmd_shutdown;
#endif
    (void)gc_worker_main;
#endif
}

/* run_collection: invoked while the world is stopped. It must perform
 * the collection synchronously. */
void run_collection(void) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
#if GC_VARIANT_STACK_THREADED
    /* Signal the service loop and wait. */
    pthread_mutex_lock(&service_lock);
    service_cmd_done = 0;
    service_cmd_pending = 1;
    pthread_cond_broadcast(&service_cond);
    while (!service_cmd_done) {
        pthread_cond_wait(&service_done_cond, &service_lock);
    }
    pthread_mutex_unlock(&service_lock);
#elif GC_VARIANT_PERSISTENT_THREAD
    pthread_mutex_lock(&gc_cmd_lock);
    gc_cmd_done = 0;
    gc_cmd_pending = 1;
    pthread_cond_broadcast(&gc_cmd_cond);
    while (!gc_cmd_done) {
        pthread_cond_wait(&gc_done_cond, &gc_cmd_lock);
    }
    pthread_mutex_unlock(&gc_cmd_lock);
#else
    /* Synchronous: this calling thread enters OCaml. It may not be
     * registered yet. We register it temporarily. */
    int registered = caml_c_thread_register();
    caml_acquire_runtime_system();
    const value *closure = caml_named_value("gc_collect");
    if (closure == NULL) {
        fprintf(stderr, "FATAL: OCaml callback gc_collect not registered\n");
        exit(1);
    }
    (void)caml_callback(*closure, Val_unit);
    caml_release_runtime_system();
    if (registered) caml_c_thread_unregister();
#endif
    clock_gettime(CLOCK_MONOTONIC, &t1);
    long ns = (long)(t1.tv_sec - t0.tv_sec) * 1000000000L
            + (long)(t1.tv_nsec - t0.tv_nsec);
    log_pause_ns(ns);
}

/* ============================================================
 * OCaml-callable primitives (all noalloc).
 *
 * Addresses are passed as native ints (Long_val/Val_long round-trip).
 * Addresses come from malloc and easily fit in 63 bits on x86_64.
 * ============================================================ */

/* Heap pointers */
CAMLprim value ml_from_space_start(value unit) {
    (void)unit;
    return Val_long((long)from_heap);
}
CAMLprim value ml_from_space_end(value unit) {
    (void)unit;
    return Val_long((long)from_heap + heap_sz);
}
CAMLprim value ml_to_space_start(value unit) {
    (void)unit;
    return Val_long((long)to_heap);
}
CAMLprim value ml_heap_size_bytes(value unit) {
    (void)unit;
    return Val_long(heap_sz);
}

/* Word-level access. The OCaml side passes a raw byte address. */
CAMLprim value ml_word_at(value addr) {
    long a = Long_val(addr);
    return Val_long(*(long *)a);
}
CAMLprim value ml_set_word_at(value addr, value v) {
    long a = Long_val(addr);
    *(long *)a = Long_val(v);
    return Val_unit;
}
CAMLprim value ml_memcpy_words(value dst, value src, value words) {
    memcpy((void *)Long_val(dst), (void *)Long_val(src),
           (size_t)Long_val(words) * sizeof(long));
    return Val_unit;
}

/* Test whether a word represents a heap pointer (low bit 0, non-NULL,
 * and lies inside from_heap). */
CAMLprim value ml_is_from_ptr(value v) {
    long w = Long_val(v);
    if ((w & 1L) != 0) return Val_false;
    if (w == 0) return Val_false;
    long start = (long)from_heap;
    long end = start + heap_sz;
    return (w >= start && w < end) ? Val_true : Val_false;
}

/* Static roots */
CAMLprim value ml_static_root_count(value unit) {
    (void)unit;
    return Val_long(atomic_load(&static_root_count));
}
CAMLprim value ml_static_root_addr(value i) {
    long idx = Long_val(i);
    return Val_long((long)static_roots[idx]);
}

/* Thread-local roots */
CAMLprim value ml_thread_count(value unit) {
    (void)unit;
    return Val_long(atomic_load(&registered_threads));
}
CAMLprim value ml_thread_active(value tid) {
    long t = Long_val(tid);
    return atomic_load(&registry[t].is_active) ? Val_true : Val_false;
}
CAMLprim value ml_thread_retval_addr(value tid) {
    long t = Long_val(tid);
    return Val_long((long)registry[t].gc_retval_ptr);
}
CAMLprim value ml_thread_stack_size(value tid) {
    long t = Long_val(tid);
    return Val_long(*registry[t].stack_idx_ptr);
}
CAMLprim value ml_thread_root_addr(value tid, value j) {
    long t = Long_val(tid);
    long jj = Long_val(j);
    long ***rs = registry[t].root_stack_ptr;
    /* rs[jj] is a long** — a pointer to the user's root variable. */
    return Val_long((long)rs[jj]);
}

/* Heap finalisation: swap from/to and update used bytes. */
CAMLprim value ml_swap_spaces(value used_bytes) {
    long *tmp = from_heap;
    from_heap = to_heap;
    to_heap = tmp;
    cur_heap_ptr = Long_val(used_bytes);
    return Val_unit;
}

/* Off-heap scratch (variant 3, 4) */
CAMLprim value ml_get_g_free(value unit) { (void)unit; return Val_long(g_free_ptr); }
CAMLprim value ml_set_g_free(value v)   { g_free_ptr = Long_val(v); return Val_unit; }
CAMLprim value ml_get_g_scan(value unit) { (void)unit; return Val_long(g_scan_ptr); }
CAMLprim value ml_set_g_scan(value v)   { g_scan_ptr = Long_val(v); return Val_unit; }

/* Service-loop coordination (variant 5) */
CAMLprim value ml_service_wait(value unit) {
    (void)unit;
    /* Drop OCaml runtime lock while blocked so the program can shut
     * down cleanly. */
    caml_release_runtime_system();
    pthread_mutex_lock(&service_lock);
    while (!service_cmd_pending) {
        pthread_cond_wait(&service_cond, &service_lock);
    }
    service_cmd_pending = 0;
    pthread_mutex_unlock(&service_lock);
    caml_acquire_runtime_system();
    return Val_unit;
}
CAMLprim value ml_service_done(value unit) {
    (void)unit;
    pthread_mutex_lock(&service_lock);
    service_cmd_done = 1;
    pthread_cond_broadcast(&service_done_cond);
    pthread_mutex_unlock(&service_lock);
    return Val_unit;
}
