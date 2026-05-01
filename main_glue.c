/* main_glue.c — initialises the OCaml runtime before user code runs.
 *
 * The actual main() lives in the test programs (e.g.
 * tests/binary_tree_multithreaded.c); they call gc_bridge_startup()
 * once at the top of main, before init_heap(). */

#include "runtime.h"

extern void gc_bridge_startup(int argc, char **argv);

void alloc_free_gc_init(int argc, char **argv) {
    gc_bridge_startup(argc, argv);
    init_heap();
}
