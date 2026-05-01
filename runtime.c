#include "runtime.h"
#include <string.h>

/* ============================================================
 * Per-thread state
 * ============================================================ */
__thread long **root_stack[ROOT_STACK_SIZE];
__thread long stack_idx;
__thread long current_frame_stack_sz[ROOT_STACK_SIZE];
__thread long current_frame = 0;
__thread long *gc_retval = NULL;

/* ============================================================
 * Stop-the-world coordination
 * ============================================================ */
STW_State stw_state = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
    .gc_off = PTHREAD_COND_INITIALIZER,
    .world_stopped = PTHREAD_COND_INITIALIZER,
    .resume_world = PTHREAD_COND_INITIALIZER,
    .num_threads = 1,
    .num_stopped = 0,
    .gc_requested = false,
    .world_has_stopped = false,
};

/* ============================================================
 * Thread registry & static roots
 * ============================================================ */
ThreadRegistry registry[MAX_THREADS];
atomic_int registered_threads = 0;

void *static_roots[MAX_STATIC_ROOTS];
atomic_int static_root_count = 0;

/* ============================================================
 * Heap
 * ============================================================ */
long *from_heap = NULL;
long *to_heap = NULL;
long heap_sz = 0;
long cur_heap_ptr = 0;

/* ============================================================
 * Init
 * ============================================================ */
void init_heap(void) {
    heap_sz = HEAP_SIZE_BYTES;
    from_heap = (long *)malloc(heap_sz);
    to_heap = (long *)malloc(heap_sz);
    if (!from_heap || !to_heap) {
        fprintf(stderr, "FATAL: heap allocation failed\n");
        exit(1);
    }
    cur_heap_ptr = 0;

    /* Bind main thread into registry */
    int id = atomic_fetch_add(&registered_threads, 1);
    registry[id].gc_retval_ptr = &gc_retval;
    registry[id].root_stack_ptr = (long ***)root_stack;
    registry[id].stack_idx_ptr = &stack_idx;
    atomic_store(&registry[id].is_active, true);

    start_gc_service();
}

/* ============================================================
 * Allocation
 * ============================================================ */
static void run_stw_collection(void);

long *gc_alloc(long len, long tag) {
    if (len <= 0) {
        fprintf(stderr, "FATAL: zero-length allocation\n");
        exit(1);
    }
    long bytes = (len + 1) * (long)sizeof(long);

    pthread_mutex_lock(&stw_state.lock);

    /* If a GC is currently in progress, participate in the protocol
     * and wait for it to finish before retrying allocation. */
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

    /* Heap exhausted? Trigger STW + GC. */
    if (cur_heap_ptr + bytes > heap_sz) {
        run_stw_collection();
        if (cur_heap_ptr + bytes > heap_sz) {
            pthread_mutex_unlock(&stw_state.lock);
            fprintf(stderr, "FATAL: out of memory after GC (%ld + %ld > %ld)\n",
                    cur_heap_ptr, bytes, heap_sz);
            exit(1);
        }
    }

    /* Bump-pointer allocation into from_heap */
    long *header_ptr = (long *)((uintptr_t)from_heap + cur_heap_ptr);
    long total_words = bytes / (long)sizeof(long);
    *header_ptr = (total_words << 10) | (tag & 0x3FF);
    long *body = header_ptr + 1;
    for (int i = 0; i < len; i++) body[i] = 1; /* tagged 0 */
    cur_heap_ptr += bytes;

    pthread_mutex_unlock(&stw_state.lock);
    return body;
}

/* Called with stw_state.lock held; performs full STW + collection. */
static void run_stw_collection(void) {
    stw_state.num_stopped++;
    stw_state.gc_requested = true;
    stw_state.world_has_stopped = false;
    if (stw_state.num_stopped == stw_state.num_threads) {
        stw_state.world_has_stopped = true;
    }
    while (!stw_state.world_has_stopped) {
        pthread_cond_wait(&stw_state.world_stopped, &stw_state.lock);
    }
    /* All mutators are parked. Drop the lock so the OCaml side can read
     * registry/heap state without contending; we are the sole runner. */
    pthread_mutex_unlock(&stw_state.lock);

    run_collection();

    pthread_mutex_lock(&stw_state.lock);
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

/* ============================================================
 * STW polling for non-allocation safe points
 * ============================================================ */
void poll_for_gc(void) {
    pthread_mutex_lock(&stw_state.lock);
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
    pthread_mutex_unlock(&stw_state.lock);
}

/* ============================================================
 * Domain (thread) management
 * ============================================================ */
typedef void (*user_func_t)(void);

static void *thread_entry(void *arg) {
    /* Bind this thread into the registry */
    int id = atomic_fetch_add(&registered_threads, 1);
    if (id >= MAX_THREADS) {
        fprintf(stderr, "FATAL: exceeded MAX_THREADS\n");
        exit(1);
    }
    registry[id].gc_retval_ptr = &gc_retval;
    registry[id].root_stack_ptr = (long ***)root_stack;
    registry[id].stack_idx_ptr = &stack_idx;
    atomic_store(&registry[id].is_active, true);

    user_func_t func = (user_func_t)arg;
    func();

    /* Unregister */
    atomic_store(&registry[id].is_active, false);

    pthread_mutex_lock(&stw_state.lock);
    stw_state.num_threads--;
    if (stw_state.gc_requested &&
        stw_state.num_stopped == stw_state.num_threads) {
        stw_state.world_has_stopped = true;
        pthread_cond_broadcast(&stw_state.world_stopped);
    }
    pthread_mutex_unlock(&stw_state.lock);

    return NULL;
}

pthread_t domain_spawn(void *function) {
    pthread_t pid;
    poll_for_gc();
    pthread_mutex_lock(&stw_state.lock);
    stw_state.num_threads++;
    pthread_mutex_unlock(&stw_state.lock);

    if (pthread_create(&pid, NULL, thread_entry, function) != 0) {
        pthread_mutex_lock(&stw_state.lock);
        stw_state.num_threads--;
        pthread_mutex_unlock(&stw_state.lock);
        perror("pthread_create");
        exit(1);
    }
    return pid;
}

void domain_join(pthread_t pid) {
    /* The joining thread blocks; remove it from the live count so a
     * GC requested while we're sleeping can still make progress. */
    poll_for_gc();
    pthread_mutex_lock(&stw_state.lock);
    stw_state.num_threads--;
    if (stw_state.gc_requested &&
        stw_state.num_stopped == stw_state.num_threads) {
        stw_state.world_has_stopped = true;
        pthread_cond_broadcast(&stw_state.world_stopped);
    }
    pthread_mutex_unlock(&stw_state.lock);

    pthread_join(pid, NULL);

    pthread_mutex_lock(&stw_state.lock);
    stw_state.num_threads++;
    pthread_mutex_unlock(&stw_state.lock);
    poll_for_gc();
}

/* ============================================================
 * Root registration
 * ============================================================ */
void make_static_root(long **ptr_to_var) {
    int idx = atomic_fetch_add(&static_root_count, 1);
    if (idx >= MAX_STATIC_ROOTS) {
        fprintf(stderr, "FATAL: exceeded MAX_STATIC_ROOTS\n");
        exit(1);
    }
    static_roots[idx] = ptr_to_var;
}

void make_root(long **ptr_to_var) {
    root_stack[stack_idx++] = ptr_to_var;
    current_frame_stack_sz[current_frame]++;
}

void make_return_root(long **ptr_to_var) {
    gc_retval = *ptr_to_var;
}

void alloc_free_new_frame(void) {
    current_frame++;
    current_frame_stack_sz[current_frame] = 0;
}

void alloc_free_return_handler(void) {
    (void)alloc_free_return_with_val(NULL);
}

long *alloc_free_return_with_val(long *val) {
    stack_idx -= current_frame_stack_sz[current_frame];
    current_frame--;
    poll_for_gc();
    long *ret = gc_retval;
    gc_retval = NULL;
    return ret ? ret : val;
}
