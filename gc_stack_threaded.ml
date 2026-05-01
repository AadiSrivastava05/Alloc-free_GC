[@@@alert "-unsafe_multidomain"]

let word_size = Sys.word_size / 8
let cmd_collect = 1
let cmd_shutdown = 2

external memcpy : int -> int -> int -> unit = "oxcaml_gc_memcpy" [@@noalloc]
external load_word : int -> int -> int = "oxcaml_gc_load_word" [@@noalloc]
external store_word : int -> int -> int -> unit = "oxcaml_gc_store_word" [@@noalloc]
external debug_collection_started : int -> unit = "oxcaml_gc_debug_collection_started" [@@noalloc]
external debug_collection_finished : int -> unit = "oxcaml_gc_debug_collection_finished" [@@noalloc]

external service_wait : unit -> int = "oxcaml_gc_service_wait"
external service_reply : int -> unit = "oxcaml_gc_service_reply" [@@noalloc]

external c_heap_size : unit -> int = "oxcaml_gc_c_heap_size" [@@noalloc]
external c_from_heap : unit -> int = "oxcaml_gc_c_from_heap" [@@noalloc]
external c_to_heap : unit -> int = "oxcaml_gc_c_to_heap" [@@noalloc]
external c_cur_heap_ptr : unit -> int = "oxcaml_gc_c_cur_heap_ptr" [@@noalloc]
external c_finish_collection : int -> unit = "oxcaml_gc_c_finish_collection" [@@noalloc]
external c_static_root_count : unit -> int = "oxcaml_gc_c_static_root_count" [@@noalloc]
external c_static_root : int -> int = "oxcaml_gc_c_static_root" [@@noalloc]
external c_registered_threads : unit -> int = "oxcaml_gc_c_registered_threads" [@@noalloc]
external c_active_thread : int -> bool = "oxcaml_gc_c_active_thread" [@@noalloc]
external c_root_stack_ptr : int -> int = "oxcaml_gc_c_root_stack_ptr" [@@noalloc]
external c_stack_idx_ptr : int -> int = "oxcaml_gc_c_stack_idx_ptr" [@@noalloc]
external c_gc_retval_ptr : int -> int = "oxcaml_gc_c_gc_retval_ptr" [@@noalloc]

let[@zero_alloc] is_heap_ptr value =
  value <> 0 && value land 1 = 0

let[@zero_alloc] in_from_heap from_heap heap_size value =
  value >= from_heap && value < from_heap + heap_size

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

  for i = 0 to c_static_root_count () - 1 do
    let root_addr = c_static_root i in
    let root_value = load_word root_addr 0 in
    let #(new_root, next_free_ptr) = copy from_heap heap_size root_value free_ptr in
    free_ptr <- next_free_ptr;
    store_word root_addr 0 new_root
  done;

  for i = 0 to c_registered_threads () - 1 do
    if c_active_thread i then begin
      let retval_addr = c_gc_retval_ptr i in
      let retval = load_word retval_addr 0 in
      if retval <> 0 then begin
        let #(new_retval, next_free_ptr) = copy from_heap heap_size retval free_ptr in
        free_ptr <- next_free_ptr;
        store_word retval_addr 0 new_retval
      end;

      let root_stack = c_root_stack_ptr i in
      let stack_idx = load_word (c_stack_idx_ptr i) 0 in
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

let worker_loop () =
  let local_ running = ref true in
  while !running do
    let cmd = service_wait () in
    if cmd = cmd_collect then begin
      collect ();
      service_reply 0
    end else if cmd = cmd_shutdown then begin
      running := false;
      service_reply 0
    end else service_reply 0
  done

let () =
  Callback.register "oxcaml_gc_worker_loop" worker_loop
