[@@@alert "-unsafe_multidomain"]

let max_static_roots = 1024
let max_threads = 128
let word_size = Sys.word_size / 8

external malloc : int -> int = "oxcaml_gc_malloc" [@@noalloc]
external memcpy : int -> int -> int -> unit = "oxcaml_gc_memcpy" [@@noalloc]
external load_word : int -> int -> int = "oxcaml_gc_load_word" [@@noalloc]
external store_word : int -> int -> int -> unit = "oxcaml_gc_store_word" [@@noalloc]
external debug_collection_started : int -> unit = "oxcaml_gc_debug_collection_started" [@@noalloc]
external debug_collection_finished : int -> unit = "oxcaml_gc_debug_collection_finished" [@@noalloc]
external c_heap_size : unit -> int = "oxcaml_gc_c_heap_size" [@@noalloc]
external c_from_heap : unit -> int = "oxcaml_gc_c_from_heap" [@@noalloc]
external c_to_heap : unit -> int = "oxcaml_gc_c_to_heap" [@@noalloc]
external c_cur_heap_ptr : unit -> int = "oxcaml_gc_c_cur_heap_ptr" [@@noalloc]
external c_finish_collection : int -> unit = "oxcaml_gc_c_finish_collection" [@@noalloc]

let static_roots = Array.make max_static_roots 0
let static_root_count = ref 0

let root_stack_ptrs = Array.make max_threads 0
let stack_idx_ptrs = Array.make max_threads 0
let gc_retval_ptrs = Array.make max_threads 0
let active_threads = Array.make max_threads false
let registered_threads = ref 0

let[@zero_alloc] is_heap_ptr value =
  value <> 0 && value land 1 = 0

let[@zero_alloc] in_from_heap from_heap heap_size value =
  value >= from_heap && value < from_heap + heap_size

let[@zero_alloc] init heap_bytes =
  ignore heap_bytes;
  static_root_count := 0;
  registered_threads := 0;
  1

let[@zero_alloc] bind_mutator root_stack_ptr stack_idx_ptr gc_retval_ptr =
  let id = !registered_threads in
  if id >= max_threads then -1
  else begin
    registered_threads := id + 1;
    root_stack_ptrs.(id) <- root_stack_ptr;
    stack_idx_ptrs.(id) <- stack_idx_ptr;
    gc_retval_ptrs.(id) <- gc_retval_ptr;
    active_threads.(id) <- true;
    id
  end

let[@zero_alloc] destroy_mutator id =
  if id >= 0 && id < !registered_threads then active_threads.(id) <- false

let[@zero_alloc] alloc_fast _size = 0

let[@zero_alloc] used_bytes () = c_cur_heap_ptr ()
let[@zero_alloc] free_bytes () = c_heap_size () - c_cur_heap_ptr ()
let[@zero_alloc] total_bytes () = c_heap_size ()

let[@zero_alloc] register_global_root root =
  let idx = !static_root_count in
  if idx >= max_static_roots then 0
  else begin
    static_roots.(idx) <- root;
    static_root_count := idx + 1;
    1
  end

let[@zero_alloc] copy from_heap heap_size value free_ptr =
  if not (is_heap_ptr value && in_from_heap from_heap heap_size value) then #(value, free_ptr)
  else
    let object_base = value - word_size in
    let header = load_word object_base 0 in
    if header = 0 then #(load_word object_base 1, free_ptr)
    else
      let total_words = header lsr 10 in
      let bytes = total_words * word_size in
      let new_base = free_ptr in
      let next_free_ptr = free_ptr + bytes in
      memcpy new_base object_base bytes;
      let new_body = new_base + word_size in
      store_word object_base 0 0;
      store_word object_base 1 new_body;
      #(new_body, next_free_ptr)

let[@zero_alloc] collect () =
  let from_heap = c_from_heap () in
  let heap_size = c_heap_size () in
  let to_heap = c_to_heap () in
  let used_bytes = c_cur_heap_ptr () in
  debug_collection_started used_bytes;
  let mutable free_ptr = to_heap in
  let mutable scan_ptr = to_heap in

  for i = 0 to !static_root_count - 1 do
    let root_addr = static_roots.(i) in
    let root_value = load_word root_addr 0 in
    let #(new_root, next_free_ptr) = copy from_heap heap_size root_value free_ptr in
    free_ptr <- next_free_ptr;
    store_word root_addr 0 new_root
  done;

  for i = 0 to !registered_threads - 1 do
    if active_threads.(i) then begin
      let retval_addr = gc_retval_ptrs.(i) in
      let retval = load_word retval_addr 0 in
      if retval <> 0 then begin
        let #(new_retval, next_free_ptr) = copy from_heap heap_size retval free_ptr in
        free_ptr <- next_free_ptr;
        store_word retval_addr 0 new_retval
      end;

      let root_stack = root_stack_ptrs.(i) in
      let stack_idx = load_word stack_idx_ptrs.(i) 0 in
      for j = 0 to stack_idx - 1 do
        let root_addr = load_word root_stack j in
        let root_value = load_word root_addr 0 in
        let #(new_root, next_free_ptr) = copy from_heap heap_size root_value free_ptr in
        free_ptr <- next_free_ptr;
        store_word root_addr 0 new_root
      done
    end
  done;

  while scan_ptr < free_ptr do
    let object_base = scan_ptr in
    let header = load_word object_base 0 in
    let total_words = header lsr 10 in
    for i = 1 to total_words - 1 do
      let field = load_word object_base i in
      if is_heap_ptr field then begin
        let #(new_field, next_free_ptr) = copy from_heap heap_size field free_ptr in
        free_ptr <- next_free_ptr;
        store_word object_base i new_field
      end
    done;
    scan_ptr <- object_base + (total_words * word_size)
  done;

  let new_used_bytes = free_ptr - to_heap in
  c_finish_collection new_used_bytes;
  debug_collection_finished new_used_bytes

let () =
  Callback.register "oxcaml_gc_init" init;
  Callback.register "oxcaml_gc_bind_mutator" bind_mutator;
  Callback.register "oxcaml_gc_destroy_mutator" destroy_mutator;
  Callback.register "oxcaml_gc_alloc_fast" alloc_fast;
  Callback.register "oxcaml_gc_used_bytes" used_bytes;
  Callback.register "oxcaml_gc_free_bytes" free_bytes;
  Callback.register "oxcaml_gc_total_bytes" total_bytes;
  Callback.register "oxcaml_gc_register_global_root" register_global_root;
  Callback.register "oxcaml_gc_collect" collect
