#include <pthread.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "mmtk-bindings/include/mmtk.h"

#define ROOT_STACK_SIZE (1 << 20)
#define MAX_STATIC_ROOTS 1024
#define MAX_THREADS 128

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

extern __thread long **root_stack[ROOT_STACK_SIZE];
extern __thread long stack_idx;
extern __thread long *gc_retval;
extern STW_State stw_state;

#ifdef GC_STACK_THREAD_RUNTIME
static const value *cb_worker_loop;
#else
static const value *cb_init;
static const value *cb_bind_mutator;
static const value *cb_destroy_mutator;
static const value *cb_alloc_fast;
static const value *cb_used_bytes;
static const value *cb_free_bytes;
static const value *cb_total_bytes;
static const value *cb_register_global_root;
static const value *cb_collect;
#endif

static __thread int ocaml_thread_registered;

static size_t c_heap_size;
static char *c_from_heap;
static char *c_to_heap;
static size_t c_cur_heap_ptr;

#ifdef GC_STACK_THREAD_RUNTIME
enum {
    GC_CMD_NONE = 0,
    GC_CMD_COLLECT = 1,
    GC_CMD_SHUTDOWN = 2
};

static pthread_t gc_stack_worker_thread;
static pthread_mutex_t gc_service_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gc_service_available = PTHREAD_COND_INITIALIZER;
static pthread_cond_t gc_service_finished = PTHREAD_COND_INITIALIZER;
static pthread_cond_t gc_service_ready_cond = PTHREAD_COND_INITIALIZER;
static int gc_service_cmd;
static long gc_service_result;
static bool gc_service_done;
static bool gc_service_ready;

static long c_static_roots[MAX_STATIC_ROOTS];
static long c_static_root_count;
static long c_root_stack_ptrs[MAX_THREADS];
static long c_stack_idx_ptrs[MAX_THREADS];
static long c_gc_retval_ptrs[MAX_THREADS];
static bool c_active_threads[MAX_THREADS];
static long c_registered_threads;

static void start_gc_stack_worker_thread(void);
static void stop_gc_stack_worker_thread(void);
static long gc_service_call(int cmd);
#endif

#ifdef GC_THREAD_RUNTIME
static pthread_t gc_worker_thread;
static pthread_cond_t gc_work_available = PTHREAD_COND_INITIALIZER;
static pthread_cond_t gc_work_finished = PTHREAD_COND_INITIALIZER;
static bool gc_work_pending;
static bool gc_work_done;

static void start_gc_worker_thread(void);
#endif

extern void caml_thread_initialize(void);

static void fail_if_exception(value result, const char *name)
{
    if (Is_exception_result(result)) {
        fprintf(stderr, "FATAL: OxCaml callback %s raised an exception.\n", name);
        exit(1);
    }
}

#ifndef GC_STACK_THREAD_RUNTIME
static value call0(const value *closure, const char *name)
{
    caml_acquire_runtime_system();
    value result = caml_callback_exn(*closure, Val_unit);
    fail_if_exception(result, name);
    caml_release_runtime_system();
    return result;
}

static value call1(const value *closure, value arg0, const char *name)
{
    caml_acquire_runtime_system();
    value result = caml_callback_exn(*closure, arg0);
    fail_if_exception(result, name);
    caml_release_runtime_system();
    return result;
}

static value call3(const value *closure, value arg0, value arg1, value arg2, const char *name)
{
    value args[3] = {arg0, arg1, arg2};
    caml_acquire_runtime_system();
    value result = caml_callbackN_exn(*closure, 3, args);
    fail_if_exception(result, name);
    caml_release_runtime_system();
    return result;
}
#endif

static void require_callback(const value **slot, const char *name)
{
    *slot = caml_named_value(name);
    if (*slot == NULL) {
        fprintf(stderr, "FATAL: missing OxCaml callback %s.\n", name);
        exit(1);
    }
}

static void ensure_ocaml_thread_registered(void)
{
    if (!ocaml_thread_registered) {
        caml_c_thread_register();
        ocaml_thread_registered = 1;
    }
}

#ifdef GC_STACK_THREAD_RUNTIME
static void *gc_stack_worker_loop(void *unused)
{
    (void)unused;
    ensure_ocaml_thread_registered();

    caml_acquire_runtime_system();
    value result = caml_callback_exn(*cb_worker_loop, Val_unit);
    fail_if_exception(result, "oxcaml_gc_worker_loop");
    caml_release_runtime_system();
    return NULL;
}

static void start_gc_stack_worker_thread(void)
{
    if (pthread_create(&gc_stack_worker_thread, NULL, gc_stack_worker_loop, NULL) != 0) {
        perror("Failed to spawn OxCaml stack GC worker thread");
        exit(1);
    }
}

static void stop_gc_stack_worker_thread(void)
{
    gc_service_call(GC_CMD_SHUTDOWN);
    pthread_join(gc_stack_worker_thread, NULL);
}

static void wait_until_gc_service_ready(void)
{
    pthread_mutex_lock(&gc_service_lock);
    while (!gc_service_ready) {
        pthread_cond_wait(&gc_service_ready_cond, &gc_service_lock);
    }
    pthread_mutex_unlock(&gc_service_lock);
}

static long gc_service_call(int cmd)
{
    wait_until_gc_service_ready();

    pthread_mutex_lock(&gc_service_lock);
    while (gc_service_cmd != GC_CMD_NONE) {
        pthread_cond_wait(&gc_service_finished, &gc_service_lock);
    }

    gc_service_done = false;
    gc_service_cmd = cmd;
    pthread_cond_signal(&gc_service_available);

    while (!gc_service_done) {
        pthread_cond_wait(&gc_service_finished, &gc_service_lock);
    }

    long result = gc_service_result;
    pthread_mutex_unlock(&gc_service_lock);
    return result;
}

value oxcaml_gc_service_wait(value unit)
{
    (void)unit;
    pthread_mutex_lock(&gc_service_lock);
    gc_service_ready = true;
    pthread_cond_broadcast(&gc_service_ready_cond);

    while (gc_service_cmd == GC_CMD_NONE) {
        pthread_cond_wait(&gc_service_available, &gc_service_lock);
    }

    int cmd = gc_service_cmd;
    pthread_mutex_unlock(&gc_service_lock);
    return Val_long(cmd);
}

value oxcaml_gc_service_arg(value idx)
{
    (void)idx;
    return Val_long(0);
}

value oxcaml_gc_service_reply(value result)
{
    pthread_mutex_lock(&gc_service_lock);
    gc_service_result = Long_val(result);
    gc_service_cmd = GC_CMD_NONE;
    gc_service_done = true;
    pthread_cond_broadcast(&gc_service_finished);
    pthread_mutex_unlock(&gc_service_lock);
    return Val_unit;
}
#endif

#ifdef GC_THREAD_RUNTIME
static void *gc_worker_loop(void *unused)
{
    (void)unused;
    ensure_ocaml_thread_registered();

    pthread_mutex_lock(&stw_state.lock);
    for (;;) {
        while (!gc_work_pending) {
            pthread_cond_wait(&gc_work_available, &stw_state.lock);
        }

        gc_work_pending = false;
        call0(cb_collect, "oxcaml_gc_collect");
        gc_work_done = true;
        pthread_cond_signal(&gc_work_finished);
    }

    pthread_mutex_unlock(&stw_state.lock);
    return NULL;
}

static void start_gc_worker_thread(void)
{
    if (pthread_create(&gc_worker_thread, NULL, gc_worker_loop, NULL) != 0) {
        perror("Failed to spawn OxCaml GC worker thread");
        exit(1);
    }
    pthread_detach(gc_worker_thread);
}
#endif

__attribute__((constructor))
static void start_ocaml_runtime(void)
{
    char *argv[] = {"alloc-free-gc", NULL};
    caml_startup(argv);
    caml_thread_initialize();
    ocaml_thread_registered = 1;

#ifdef GC_STACK_THREAD_RUNTIME
    require_callback(&cb_worker_loop, "oxcaml_gc_worker_loop");
#else
    require_callback(&cb_init, "oxcaml_gc_init");
    require_callback(&cb_bind_mutator, "oxcaml_gc_bind_mutator");
    require_callback(&cb_destroy_mutator, "oxcaml_gc_destroy_mutator");
    require_callback(&cb_alloc_fast, "oxcaml_gc_alloc_fast");
    require_callback(&cb_used_bytes, "oxcaml_gc_used_bytes");
    require_callback(&cb_free_bytes, "oxcaml_gc_free_bytes");
    require_callback(&cb_total_bytes, "oxcaml_gc_total_bytes");
    require_callback(&cb_register_global_root, "oxcaml_gc_register_global_root");
    require_callback(&cb_collect, "oxcaml_gc_collect");
#endif

    caml_release_runtime_system();

#ifdef GC_STACK_THREAD_RUNTIME
    start_gc_stack_worker_thread();
    atexit(stop_gc_stack_worker_thread);
#endif

#ifdef GC_THREAD_RUNTIME
    start_gc_worker_thread();
#endif
}

value oxcaml_gc_malloc(value bytes)
{
    return Val_long((intptr_t)malloc((size_t)Long_val(bytes)));
}

value oxcaml_gc_memcpy(value dst, value src, value bytes)
{
    memcpy((void *)(intptr_t)Long_val(dst),
           (const void *)(intptr_t)Long_val(src),
           (size_t)Long_val(bytes));
    return Val_unit;
}

value oxcaml_gc_load_word(value base, value word_offset)
{
    long *ptr = (long *)(intptr_t)Long_val(base);
    return Val_long(ptr[Long_val(word_offset)]);
}

value oxcaml_gc_store_word(value base, value word_offset, value word)
{
    long *ptr = (long *)(intptr_t)Long_val(base);
    ptr[Long_val(word_offset)] = Long_val(word);
    return Val_unit;
}

value oxcaml_gc_debug_collection_started(value used_bytes)
{
    printf("\n[GC] Collection Started. Used bytes: %zu\n", (size_t)Long_val(used_bytes));
    return Val_unit;
}

value oxcaml_gc_debug_collection_finished(value used_bytes)
{
    printf("[GC] Collection Finished. Used bytes after compaction: %zu\n", (size_t)Long_val(used_bytes));
    return Val_unit;
}

value oxcaml_gc_c_heap_size(value unit)
{
    (void)unit;
    return Val_long((long)c_heap_size);
}

value oxcaml_gc_c_from_heap(value unit)
{
    (void)unit;
    return Val_long((intptr_t)c_from_heap);
}

value oxcaml_gc_c_to_heap(value unit)
{
    (void)unit;
    return Val_long((intptr_t)c_to_heap);
}

value oxcaml_gc_c_cur_heap_ptr(value unit)
{
    (void)unit;
    return Val_long((long)c_cur_heap_ptr);
}

value oxcaml_gc_c_finish_collection(value used_bytes)
{
    char *old_from_heap = c_from_heap;
    c_from_heap = c_to_heap;
    c_to_heap = old_from_heap;
    c_cur_heap_ptr = (size_t)Long_val(used_bytes);
    return Val_unit;
}

#ifdef GC_STACK_THREAD_RUNTIME
value oxcaml_gc_c_static_root_count(value unit)
{
    (void)unit;
    return Val_long(c_static_root_count);
}

value oxcaml_gc_c_static_root(value idx)
{
    return Val_long(c_static_roots[Long_val(idx)]);
}

value oxcaml_gc_c_registered_threads(value unit)
{
    (void)unit;
    return Val_long(c_registered_threads);
}

value oxcaml_gc_c_active_thread(value idx)
{
    return Val_bool(c_active_threads[Long_val(idx)]);
}

value oxcaml_gc_c_root_stack_ptr(value idx)
{
    return Val_long(c_root_stack_ptrs[Long_val(idx)]);
}

value oxcaml_gc_c_stack_idx_ptr(value idx)
{
    return Val_long(c_stack_idx_ptrs[Long_val(idx)]);
}

value oxcaml_gc_c_gc_retval_ptr(value idx)
{
    return Val_long(c_gc_retval_ptrs[Long_val(idx)]);
}
#endif

void mmtk_init(uint32_t heap_size, char *plan)
{
    (void)plan;
    c_heap_size = (size_t)heap_size;
    c_from_heap = malloc(c_heap_size);
    c_to_heap = malloc(c_heap_size);
    c_cur_heap_ptr = 0;
    if (c_from_heap == NULL || c_to_heap == NULL) {
        fprintf(stderr, "FATAL: Heap init allocation failed.\n");
        exit(1);
    }
#ifdef GC_STACK_THREAD_RUNTIME
    c_static_root_count = 0;
    c_registered_threads = 0;
#else
    ensure_ocaml_thread_registered();
    value ok = call1(cb_init, Val_long((long)heap_size), "oxcaml_gc_init");
    if (Long_val(ok) == 0) {
        fprintf(stderr, "FATAL: Heap init allocation failed.\n");
        exit(1);
    }
#endif
}

MMTk_Mutator mmtk_bind_mutator(void *tls)
{
    (void)tls;
#ifdef GC_STACK_THREAD_RUNTIME
    long mutator_id = c_registered_threads;
    if (mutator_id < MAX_THREADS) {
        c_registered_threads++;
        c_root_stack_ptrs[mutator_id] = (long)(intptr_t)root_stack;
        c_stack_idx_ptrs[mutator_id] = (long)(intptr_t)&stack_idx;
        c_gc_retval_ptrs[mutator_id] = (long)(intptr_t)&gc_retval;
        c_active_threads[mutator_id] = true;
    }
#else
    ensure_ocaml_thread_registered();
    value id = call3(cb_bind_mutator,
                     Val_long((intptr_t)root_stack),
                     Val_long((intptr_t)&stack_idx),
                     Val_long((intptr_t)&gc_retval),
                     "oxcaml_gc_bind_mutator");
    long mutator_id = Long_val(id);
#endif
    if (mutator_id < 0) {
        fprintf(stderr, "FATAL: Exceeded MAX_THREADS in OxCaml GC.\n");
        exit(1);
    }
    return (MMTk_Mutator)(intptr_t)mutator_id;
}

void mmtk_destroy_mutator(MMTk_Mutator mutator)
{
#ifdef GC_STACK_THREAD_RUNTIME
    long mutator_id = (long)(intptr_t)mutator;
    if (mutator_id >= 0 && mutator_id < c_registered_threads) {
        c_active_threads[mutator_id] = false;
    }
#else
    ensure_ocaml_thread_registered();
    call1(cb_destroy_mutator, Val_long((intptr_t)mutator), "oxcaml_gc_destroy_mutator");
#endif
}

static void wait_while_gc_requested(void)
{
    if (stw_state.gc_requested) {
        stw_state.num_stopped++;

        if (stw_state.num_stopped == stw_state.num_threads) {
            stw_state.world_has_stopped = true;
            pthread_cond_broadcast(&stw_state.world_stopped);
        }

        while (stw_state.gc_requested) {
            pthread_cond_wait(&stw_state.gc_off, &stw_state.lock);
        }

        stw_state.num_stopped--;
        if (stw_state.num_stopped == 0) {
            stw_state.world_has_stopped = false;
            pthread_cond_broadcast(&stw_state.resume_world);
        } else {
            while (stw_state.world_has_stopped) {
                pthread_cond_wait(&stw_state.resume_world, &stw_state.lock);
            }
        }
    }
}

static void collect_with_world_stopped(void)
{
    stw_state.num_stopped++;
    stw_state.gc_requested = true;
    stw_state.world_has_stopped = false;

    if (stw_state.num_stopped == stw_state.num_threads) {
        stw_state.world_has_stopped = true;
    }

    while (!stw_state.world_has_stopped) {
        pthread_cond_wait(&stw_state.world_stopped, &stw_state.lock);
    }

#ifdef GC_STACK_THREAD_RUNTIME
    gc_service_call(GC_CMD_COLLECT);
#elif defined(GC_THREAD_RUNTIME)
    gc_work_done = false;
    gc_work_pending = true;
    pthread_cond_signal(&gc_work_available);
    while (!gc_work_done) {
        pthread_cond_wait(&gc_work_finished, &stw_state.lock);
    }
#else
    call0(cb_collect, "oxcaml_gc_collect");
#endif

    stw_state.gc_requested = false;
    pthread_cond_broadcast(&stw_state.gc_off);

    stw_state.num_stopped--;
    if (stw_state.num_stopped == 0) {
        stw_state.world_has_stopped = false;
        pthread_cond_broadcast(&stw_state.resume_world);
    } else {
        while (stw_state.world_has_stopped) {
            pthread_cond_wait(&stw_state.resume_world, &stw_state.lock);
        }
    }
}

void *mmtk_alloc(MMTk_Mutator mutator, size_t size, size_t align, size_t offset, int allocator)
{
    (void)mutator;
    (void)align;
    (void)offset;
    (void)allocator;

    pthread_mutex_lock(&stw_state.lock);
    wait_while_gc_requested();

    long ptr = 0;
    if (c_cur_heap_ptr + size <= c_heap_size) {
        ptr = (long)(intptr_t)(c_from_heap + c_cur_heap_ptr);
        c_cur_heap_ptr += size;
    }
    if (ptr == 0) {
        collect_with_world_stopped();
        if (c_cur_heap_ptr + size <= c_heap_size) {
            ptr = (long)(intptr_t)(c_from_heap + c_cur_heap_ptr);
            c_cur_heap_ptr += size;
        }
        if (ptr == 0) {
            stw_state.num_threads--;
            pthread_mutex_unlock(&stw_state.lock);
            fprintf(stderr, "FATAL: Out of Memory after GC.\n");
            exit(1);
        }
    }

    pthread_mutex_unlock(&stw_state.lock);
    return (void *)(intptr_t)ptr;
}

void mmtk_post_alloc(MMTk_Mutator mutator, void *refer, int bytes, int tag, int allocator)
{
    (void)mutator;
    (void)allocator;
    long total_words = bytes / (int)sizeof(long);
    ((long *)refer)[0] = (total_words << 10) | (tag & 0x3FF);
}

size_t mmtk_used_bytes(void)
{
    return c_cur_heap_ptr;
}

size_t mmtk_free_bytes(void)
{
    return c_heap_size - c_cur_heap_ptr;
}

size_t mmtk_total_bytes(void)
{
    return c_heap_size;
}

void mmtk_register_global_root(void *ref)
{
#ifdef GC_STACK_THREAD_RUNTIME
    if (c_static_root_count >= MAX_STATIC_ROOTS) {
        fprintf(stderr, "ERROR: Exceeded MAX_STATIC_ROOTS in OxCaml GC.\n");
        exit(1);
    }
    c_static_roots[c_static_root_count++] = (long)(intptr_t)ref;
#else
    ensure_ocaml_thread_registered();
    value ok = call1(cb_register_global_root,
                     Val_long((intptr_t)ref),
                     "oxcaml_gc_register_global_root");
    if (Long_val(ok) == 0) {
        fprintf(stderr, "ERROR: Exceeded MAX_STATIC_ROOTS in OxCaml GC.\n");
        exit(1);
    }
#endif
}
