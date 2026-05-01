(* gc.ml — variant 2: zero-allocation OxCaml collector.

   Same algorithm as gc_normal.ml but the collection hot path is written
   to never allocate on the OCaml heap. Mutable state is held in
   stack-resident [let mutable] variables. The copy helper returns an
   unboxed pair (#(int * int)), so tupling the result also avoids
   heap allocation. *)

open Gc_prims

let[@zero_alloc] copy v free_ptr : #(int * int) =
  if not (is_from_ptr v) then #(v, free_ptr)
  else begin
    let header_addr = v - word_bytes in
    let header = word_at header_addr in
    if is_forwarded header then
      #(word_at v, free_ptr)
    else begin
      let total_words = header_total_words header in
      let bytes = total_words * word_bytes in
      memcpy_words free_ptr header_addr total_words;
      let new_body_addr = free_ptr + word_bytes in
      set_word_at header_addr 0;
      set_word_at v new_body_addr;
      #(new_body_addr, free_ptr + bytes)
    end
  end

let[@zero_alloc] collect () =
  let mutable free_ptr = to_space_start () in
  let mutable scan_ptr = to_space_start () in

  (* Static roots *)
  let nstatic = static_root_count () in
  for i = 0 to nstatic - 1 do
    let root_addr = static_root_addr i in
    let v = word_at root_addr in
    let #(v', fp) = copy v free_ptr in
    free_ptr <- fp;
    set_word_at root_addr v'
  done;

  (* Per-thread roots *)
  let nthr = thread_count () in
  for t = 0 to nthr - 1 do
    if thread_active t then begin
      let rv_addr = thread_retval_addr t in
      let rv = word_at rv_addr in
      if rv <> 0 then begin
        let #(rv', fp) = copy rv free_ptr in
        free_ptr <- fp;
        set_word_at rv_addr rv'
      end;
      let sz = thread_stack_size t in
      for j = 0 to sz - 1 do
        let p_addr = thread_root_addr t j in
        let v = word_at p_addr in
        let #(v', fp) = copy v free_ptr in
        free_ptr <- fp;
        set_word_at p_addr v'
      done
    end
  done;

  (* Cheney walk *)
  while scan_ptr < free_ptr do
    let header = word_at scan_ptr in
    let total_words = header_total_words header in
    for i = 1 to total_words - 1 do
      let field_addr = scan_ptr + (i * word_bytes) in
      let v = word_at field_addr in
      let #(v', fp) = copy v free_ptr in
      free_ptr <- fp;
      set_word_at field_addr v'
    done;
    scan_ptr <- scan_ptr + (total_words * word_bytes)
  done;

  let used_bytes = free_ptr - to_space_start () in
  swap_spaces used_bytes

let () = Callback.register "gc_collect" collect
