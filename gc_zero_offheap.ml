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

let heap_size_slot = 0
let from_heap_slot = 1
let to_heap_slot = 2
let cur_heap_ptr_slot = 3
let static_root_count_slot = 4
let registered_threads_slot = 5
let state_words = 6

let static_roots_offset = state_words
let root_stack_ptrs_offset = static_roots_offset + max_static_roots
let stack_idx_ptrs_offset = root_stack_ptrs_offset + max_threads
let gc_retval_ptrs_offset = stack_idx_ptrs_offset + max_threads
let active_threads_offset = gc_retval_ptrs_offset + max_threads
let metadata_words = active_threads_offset + max_threads

let metadata = malloc (metadata_words * word_size)

let[@zero_alloc] meta_load slot =
  load_word metadata slot

let[@zero_alloc] meta_store slot value =
  store_word metadata slot value

let[@zero_alloc] heap_size () = c_heap_size ()
let[@zero_alloc] from_heap () = c_from_heap ()
let[@zero_alloc] to_heap () = c_to_heap ()
let[@zero_alloc] cur_heap_ptr () = c_cur_heap_ptr ()
let[@zero_alloc] static_root_count () = meta_load static_root_count_slot
let[@zero_alloc] registered_threads () = meta_load registered_threads_slot

let[@zero_alloc] set_heap_size value = meta_store heap_size_slot value
let[@zero_alloc] set_from_heap value = meta_store from_heap_slot value
let[@zero_alloc] set_to_heap value = meta_store to_heap_slot value
let[@zero_alloc] set_cur_heap_ptr value = meta_store cur_heap_ptr_slot value
let[@zero_alloc] set_static_root_count value = meta_store static_root_count_slot value
let[@zero_alloc] set_registered_threads value = meta_store registered_threads_slot value

let[@zero_alloc] static_roots_slot idx = static_roots_offset + idx
let[@zero_alloc] root_stack_ptrs_slot idx = root_stack_ptrs_offset + idx
let[@zero_alloc] stack_idx_ptrs_slot idx = stack_idx_ptrs_offset + idx
let[@zero_alloc] gc_retval_ptrs_slot idx = gc_retval_ptrs_offset + idx
let[@zero_alloc] active_threads_slot idx = active_threads_offset + idx

let[@zero_alloc] is_heap_ptr value =
  value <> 0 && value land 1 = 0

let[@zero_alloc] in_from_heap value =
  value >= from_heap () && value < from_heap () + heap_size ()

let[@zero_alloc] init heap_bytes =
  ignore heap_bytes;
  if metadata = 0 then 0
  else begin
    set_static_root_count 0;
    set_registered_threads 0;
    1
  end

let[@zero_alloc] bind_mutator root_stack_ptr stack_idx_ptr gc_retval_ptr =
  if metadata = 0 then -1
  else
    let id = registered_threads () in
    if id >= max_threads then -1
    else begin
      set_registered_threads (id + 1);
      meta_store (root_stack_ptrs_slot id) root_stack_ptr;
      meta_store (stack_idx_ptrs_slot id) stack_idx_ptr;
      meta_store (gc_retval_ptrs_slot id) gc_retval_ptr;
      meta_store (active_threads_slot id) 1;
      id
    end

let[@zero_alloc] destroy_mutator id =
  if id >= 0 && id < registered_threads () then meta_store (active_threads_slot id) 0

let[@zero_alloc] alloc_fast _size = 0

let[@zero_alloc] used_bytes () = cur_heap_ptr ()
let[@zero_alloc] free_bytes () = heap_size () - cur_heap_ptr ()
let[@zero_alloc] total_bytes () = heap_size ()

let[@zero_alloc] register_global_root root =
  let idx = static_root_count () in
  if idx >= max_static_roots then 0
  else begin
    meta_store (static_roots_slot idx) root;
    set_static_root_count (idx + 1);
    1
  end

let[@zero_alloc] copy value free_ptr =
  if not (is_heap_ptr value && in_from_heap value) then #(value, free_ptr)
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
  debug_collection_started (cur_heap_ptr ());
  let mutable free_ptr = to_heap () in
  let mutable scan_ptr = to_heap () in

  for i = 0 to static_root_count () - 1 do
    let root_addr = meta_load (static_roots_slot i) in
    let root_value = load_word root_addr 0 in
    let #(new_root, next_free_ptr) = copy root_value free_ptr in
    free_ptr <- next_free_ptr;
    store_word root_addr 0 new_root
  done;

  for i = 0 to registered_threads () - 1 do
    if meta_load (active_threads_slot i) <> 0 then begin
      let retval_addr = meta_load (gc_retval_ptrs_slot i) in
      let retval = load_word retval_addr 0 in
      if retval <> 0 then begin
        let #(new_retval, next_free_ptr) = copy retval free_ptr in
        free_ptr <- next_free_ptr;
        store_word retval_addr 0 new_retval
      end;

      let root_stack = meta_load (root_stack_ptrs_slot i) in
      let stack_idx = load_word (meta_load (stack_idx_ptrs_slot i)) 0 in
      for j = 0 to stack_idx - 1 do
        let root_addr = load_word root_stack j in
        let root_value = load_word root_addr 0 in
        let #(new_root, next_free_ptr) = copy root_value free_ptr in
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
        let #(new_field, next_free_ptr) = copy field free_ptr in
        free_ptr <- next_free_ptr;
        store_word object_base i new_field
      end
    done;
    scan_ptr <- object_base + (total_words * word_size)
  done;

  let new_used_bytes = free_ptr - to_heap () in
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
