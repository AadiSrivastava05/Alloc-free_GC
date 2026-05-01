OCAMLOPT ?= ocamlopt.opt
OCAMLC ?= ocamlc
CC ?= gcc

OCAML_WHERE := $(shell $(OCAMLC) -where)
CFLAGS := -Wall -Wextra -O2 -pthread -I. -I$(OCAML_WHERE)
RUNTIME_CFLAGS := $(CFLAGS) -Dcaml_alloc=toycaml_alloc
LDLIBS := $(OCAML_WHERE)/threads/threads.a -L$(OCAML_WHERE) -lthreadsnat_stubs -lasmrun -lm -ldl -lpthread
GC ?= zero
GC_FFI_OBJECT := gc_ffi.o

ifeq ($(GC),zero)
GC_OBJECT := gc_zero_ml.o
else ifeq ($(GC),zero_offheap)
GC_OBJECT := gc_zero_offheap_ml.o
else ifeq ($(GC),zero_offheap_threaded)
GC_OBJECT := gc_zero_offheap_ml.o
GC_FFI_OBJECT := gc_ffi_threaded.o
else ifeq ($(GC),zero_stack_threaded)
GC_OBJECT := gc_stack_threaded_ml.o
GC_FFI_OBJECT := gc_ffi_stack_threaded.o
else ifeq ($(GC),normal)
GC_OBJECT := gc_normal_ml.o
else
$(error GC must be one of zero, zero_offheap, zero_offheap_threaded, zero_stack_threaded, normal)
endif

.PHONY: all clean test zero zero_offheap zero_offheap_threaded zero_stack_threaded normal binary_tree_test binary_tree_multithreaded_test

all: test

gc_zero_ml.o: gc.ml
	$(OCAMLOPT) -zero-alloc-check all -output-obj -o $@ $<

gc_zero_offheap_ml.o: gc_zero_offheap.ml
	$(OCAMLOPT) -zero-alloc-check all -output-obj -o $@ $<

gc_stack_threaded_ml.o: gc_stack_threaded.ml
	$(OCAMLOPT) -zero-alloc-check all -output-obj -o $@ $<

gc_normal_ml.o: gc_normal.ml
	$(OCAMLOPT) -output-obj -o $@ $<

gc_ffi.o: gc_ffi.c runtime.h mmtk-bindings/include/mmtk.h
	$(CC) $(CFLAGS) -c -o $@ $<

gc_ffi_threaded.o: gc_ffi.c runtime.h mmtk-bindings/include/mmtk.h
	$(CC) $(CFLAGS) -DGC_THREAD_RUNTIME -c -o $@ $<

gc_ffi_stack_threaded.o: gc_ffi.c runtime.h mmtk-bindings/include/mmtk.h
	$(CC) $(CFLAGS) -DGC_STACK_THREAD_RUNTIME -c -o $@ $<

runtime.o: runtime.c runtime.h mmtk-bindings/include/mmtk.h
	$(CC) $(RUNTIME_CFLAGS) -c -o $@ $<

smoke_test.o: smoke_test.c runtime.h
	$(CC) $(RUNTIME_CFLAGS) -c -o $@ $<

test: $(GC_OBJECT) $(GC_FFI_OBJECT) runtime.o smoke_test.o
	$(CC) -o $@ $^ $(LDLIBS)

zero:
	$(MAKE) GC=zero test

zero_offheap:
	$(MAKE) GC=zero_offheap test

zero_offheap_threaded:
	$(MAKE) GC=zero_offheap_threaded test

zero_stack_threaded:
	$(MAKE) GC=zero_stack_threaded test

normal:
	$(MAKE) GC=normal test

binary_tree.o: benchmarks/binary_tree.c runtime.h
	$(CC) $(RUNTIME_CFLAGS) -c -o $@ $<

binary_tree_test: $(GC_OBJECT) $(GC_FFI_OBJECT) runtime.o binary_tree.o
	$(CC) -o $@ $^ $(LDLIBS)

binary_tree_multithreaded.o: benchmarks/binary_tree_multithreaded.c runtime.h
	$(CC) $(RUNTIME_CFLAGS) -c -o $@ $<

binary_tree_multithreaded_test: $(GC_OBJECT) $(GC_FFI_OBJECT) runtime.o binary_tree_multithreaded.o
	$(CC) -o $@ $^ $(LDLIBS)

clean:
	rm -f test binary_tree_test binary_tree_multithreaded_test *.o *.cmx *.cmi *.cmti *.cmt
	rm -f benchmarking/alloc_free_gc_zero benchmarking/alloc_free_gc_zero_offheap benchmarking/alloc_free_gc_zero_offheap_threaded benchmarking/alloc_free_gc_zero_stack_threaded benchmarking/alloc_free_gc_normal
	rm -rf _build
