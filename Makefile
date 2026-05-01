# Makefile — builds the benchmark for any of the five GC variants.
#
# Usage:   make GC=normal           # variant 1
#          make GC=zero             # variant 2
#          make GC=zero_offheap     # variant 3
#          make GC=zero_offheap_threaded   # variant 4
#          make GC=zero_stack_threaded     # variant 5
#          make all                 # build all five into bin/<variant>
#
# Each variant produces a binary at bin/bench_<variant>.

GC          ?= normal

OCAMLOPT     := ocamlopt
OCAML_LIBDIR := $(shell $(OCAMLOPT) -where)
CC           ?= cc
CFLAGS       ?= -O2 -Wall -Wno-unused-parameter -pthread -I$(OCAML_LIBDIR)
LDFLAGS      ?= -lpthread -lm -ldl
OCAML_RUNTIME_LIBS := $(OCAML_LIBDIR)/libasmrun.a \
                      $(OCAML_LIBDIR)/libthreadsnat_stubs.a

BIN_DIR  := bin
BUILD_DIR := build

VARIANTS := normal zero zero_offheap zero_offheap_threaded zero_stack_threaded

# Map variant name to OCaml source file.
ML_normal                := gc_normal.ml
ML_zero                  := gc.ml
ML_zero_offheap          := gc_zero_offheap.ml
ML_zero_offheap_threaded := gc_zero_offheap_threaded.ml
ML_zero_stack_threaded   := gc_stack_threaded.ml

# Per-variant CFLAGS for gc_bridge.c.
BRIDGE_FLAGS_normal                :=
BRIDGE_FLAGS_zero                  :=
BRIDGE_FLAGS_zero_offheap          :=
BRIDGE_FLAGS_zero_offheap_threaded := -DGC_VARIANT_PERSISTENT_THREAD=1
BRIDGE_FLAGS_zero_stack_threaded   := -DGC_VARIANT_PERSISTENT_THREAD=1 -DGC_VARIANT_STACK_THREADED=1

# Default target builds the variant given by GC=.
.PHONY: default all clean
default: $(BIN_DIR)/bench_$(GC)

all: $(addprefix $(BIN_DIR)/bench_,$(VARIANTS))

$(BIN_DIR) $(BUILD_DIR):
	@mkdir -p $@

# Pattern: build/<variant>/native.o is the linked-in OCaml code.
# We compile gc_prims.ml plus the variant source via ocamlopt -output-complete-obj.
.SECONDEXPANSION:
$(BUILD_DIR)/%/native.o: $$(ML_%) gc_prims.ml | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/$*
	$(OCAMLOPT) -output-complete-obj -extension layouts -extension small_numbers \
	    -extension let_mutable -extension mode \
	    -O3 -opaque \
	    -I $(BUILD_DIR)/$* \
	    -o $@ \
	    gc_prims.ml $(ML_$*)

# Per-variant gc_bridge object.
$(BUILD_DIR)/%/gc_bridge.o: gc_bridge.c runtime.h | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/$*
	$(CC) $(CFLAGS) $(BRIDGE_FLAGS_$*) -DGC_VARIANT_NAME=\"$*\" -c gc_bridge.c -o $@

$(BUILD_DIR)/runtime.o: runtime.c runtime.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c runtime.c -o $@

$(BUILD_DIR)/main_glue.o: main_glue.c runtime.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c main_glue.c -o $@

$(BUILD_DIR)/binary_tree_multithreaded.o: tests/binary_tree_multithreaded.c runtime.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c tests/binary_tree_multithreaded.c -o $@

# Link the final binary.
$(BIN_DIR)/bench_%: $(BUILD_DIR)/%/native.o $(BUILD_DIR)/%/gc_bridge.o \
                    $(BUILD_DIR)/runtime.o $(BUILD_DIR)/main_glue.o \
                    $(BUILD_DIR)/binary_tree_multithreaded.o | $(BIN_DIR)
	$(CC) $(CFLAGS) $^ \
	    $(OCAML_RUNTIME_LIBS) \
	    $(LDFLAGS) \
	    -o $@

clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)
