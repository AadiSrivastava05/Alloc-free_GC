#ifndef TOYCAML_OXCAML_MMTK_H
#define TOYCAML_OXCAML_MMTK_H

#include <stddef.h>
#include <stdint.h>

typedef void *MMTk_Mutator;

void mmtk_init(uint32_t heap_size, char *plan);
MMTk_Mutator mmtk_bind_mutator(void *tls);
void mmtk_destroy_mutator(MMTk_Mutator mutator);

void *mmtk_alloc(MMTk_Mutator mutator,
                 size_t size,
                 size_t align,
                 size_t offset,
                 int allocator);
void mmtk_post_alloc(MMTk_Mutator mutator,
                     void *refer,
                     int bytes,
                     int tag,
                     int allocator);

size_t mmtk_used_bytes(void);
size_t mmtk_free_bytes(void);
size_t mmtk_total_bytes(void);

void mmtk_register_global_root(void *ref);

#endif
