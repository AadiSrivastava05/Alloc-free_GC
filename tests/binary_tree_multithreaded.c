/* binary_tree_multithreaded.c — GC stress benchmark.
 *
 * Each worker thread builds a stretch tree, holds a long-lived tree of
 * the maximum depth, and then in a sweep over decreasing depths
 * allocates many short-lived trees. The combination exercises:
 *   - root updates after copying (mutator's local pointers fix-up),
 *   - return-value root survival across collections,
 *   - long-lived reachability, and
 *   - resumed-mutator pointer validity.
 *
 * Usage: ./bench <max_depth> <num_workers>
 */

#include <stdio.h>
#include <stdlib.h>
#include "../runtime.h"

extern void alloc_free_gc_init(int argc, char **argv);

#define TAG_NODE 0
#define TAG_DATA 0
#define EMPTY ((long *)0)

/* Allocate a small "data payload" the same way every variant sees. */
static long *mk_data(void) {
    alloc_free_frame;
    long *arr = gc_alloc(8, TAG_DATA);
    for (int i = 0; i < 8; i++) Field(arr, i) = long2val(i);
    make_return_root(&arr);
    alloc_free_return(arr);
}

/* Build a balanced binary tree of depth d. */
static long *make(int d) {
    alloc_free_frame;
    if (d == 0) {
        long *data = mk_data();
        make_root(&data);
        long *node = gc_alloc(3, TAG_NODE);
        Field(node, 0) = (long)EMPTY;
        Field(node, 1) = (long)data;
        Field(node, 2) = (long)EMPTY;
        make_return_root(&node);
        alloc_free_return(node);
    } else {
        long *left = make(d - 1);
        make_root(&left);
        long *data = mk_data();
        make_root(&data);
        long *right = make(d - 1);
        make_root(&right);
        long *node = gc_alloc(3, TAG_NODE);
        Field(node, 0) = (long)left;
        Field(node, 1) = (long)data;
        Field(node, 2) = (long)right;
        make_return_root(&node);
        alloc_free_return(node);
    }
}

static int check(long *tree) {
    if (tree == EMPTY) return 0;
    return 1
        + check((long *)Field(tree, 0))
        + check((long *)Field(tree, 2));
}

static int g_min_depth = 4;
static int g_max_depth;
static int g_stretch_depth;

static void worker(void) {
    alloc_free_frame;

    /* Stretch tree (immediately discarded). */
    {
        alloc_free_frame;
        long *stretch = make(g_stretch_depth);
        make_root(&stretch);
        int c = check(stretch);
        printf("[T] stretch depth %d check %d\n", g_stretch_depth, c);
        alloc_free_return_handler();
    }

    /* Long-lived tree. */
    long *long_lived = make(g_max_depth);
    make_root(&long_lived);

    /* Iterations across decreasing depths. */
    for (int d = g_min_depth; d <= g_max_depth; d += 2) {
        int niter = 1 << (g_max_depth - d + g_min_depth);
        int sum = 0;
        for (int i = 1; i <= niter; i++) {
            alloc_free_frame;
            long *t = make(d);
            make_root(&t);
            sum += check(t);
            alloc_free_return_handler();
        }
        printf("[T] %d trees of depth %d check %d\n", niter, d, sum);
    }

    printf("[T] long-lived depth %d check %d\n",
           g_max_depth, check(long_lived));
    alloc_free_return_handler();
}

int main(int argc, char **argv) {
    int n = (argc > 1) ? atoi(argv[1]) : 11;
    int nw = (argc > 2) ? atoi(argv[2]) : 2;

    alloc_free_gc_init(argc, argv);

    g_max_depth = (n > g_min_depth + 2) ? n : g_min_depth + 2;
    g_stretch_depth = g_max_depth + 1;

    printf("max_depth=%d stretch=%d workers=%d\n",
           g_max_depth, g_stretch_depth, nw);

    pthread_t *threads = (pthread_t *)malloc(sizeof(pthread_t) * nw);
    for (int i = 0; i < nw; i++) threads[i] = domain_spawn(worker);
    for (int i = 0; i < nw; i++) domain_join(threads[i]);
    free(threads);

    printf("done\n");
    return 0;
}
