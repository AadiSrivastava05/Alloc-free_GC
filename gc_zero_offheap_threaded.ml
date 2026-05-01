(* gc_zero_offheap_threaded.ml — variant 4: same algorithm and off-heap
   scratch state as variant 3, but invoked from a persistent OCaml-aware
   GC worker thread (selected via the build-time GC_VARIANT_PERSISTENT_THREAD
   flag in gc_bridge.c). The OCaml side here is identical to variant 3;
   the persistence happens in the C bridge. *)

open Gc_prims

let[@zero_alloc] copy_into v =
  if not (is_from_ptr v) then v
  else begin
    let header_addr = v - word_bytes in
    let header = word_at header_addr in
    if is_forwarded header then word_at v
    else begin
      let total_words = header_total_words header in
      let bytes = total_words * word_bytes in
      let free_ptr = get_g_free () in
      memcpy_words free_ptr header_addr total_words;
      let new_body_addr = free_ptr + word_bytes in
      set_word_at header_addr 0;
      set_word_at v new_body_addr;
      set_g_free (free_ptr + bytes);
      new_body_addr
    end
  end

let[@zero_alloc] collect () =
  let to_start = to_space_start () in
  set_g_free to_start;
  set_g_scan to_start;

  let nstatic = static_root_count () in
  for i = 0 to nstatic - 1 do
    let root_addr = static_root_addr i in
    let v = word_at root_addr in
    let v' = copy_into v in
    set_word_at root_addr v'
  done;

  let nthr = thread_count () in
  for t = 0 to nthr - 1 do
    if thread_active t then begin
      let rv_addr = thread_retval_addr t in
      let rv = word_at rv_addr in
      if rv <> 0 then begin
        let rv' = copy_into rv in
        set_word_at rv_addr rv'
      end;
      let sz = thread_stack_size t in
      for j = 0 to sz - 1 do
        let p_addr = thread_root_addr t j in
        let v = word_at p_addr in
        let v' = copy_into v in
        set_word_at p_addr v'
      done
    end
  done;

  let mutable scan_ptr = get_g_scan () in
  let mutable free_ptr = get_g_free () in
  while scan_ptr < free_ptr do
    let header = word_at scan_ptr in
    let total_words = header_total_words header in
    for i = 1 to total_words - 1 do
      let field_addr = scan_ptr + (i * word_bytes) in
      let v = word_at field_addr in
      let v' = copy_into v in
      set_word_at field_addr v'
    done;
    scan_ptr <- scan_ptr + (total_words * word_bytes);
    free_ptr <- get_g_free ()
  done;

  let used_bytes = free_ptr - to_space_start () in
  swap_spaces used_bytes

let () = Callback.register "gc_collect" collect
