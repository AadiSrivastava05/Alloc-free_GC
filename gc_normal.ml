(* gc_normal.ml — baseline semi-space collector.

   Uses ordinary OCaml refs, arrays, and tuples for all bookkeeping.
   Allocation in collector hot paths is allowed and not annotated. *)

open Gc_prims

(* copy: if [v] points into from-space, copy the object to to-space at
   [free_ptr], install a forwarding marker, and return both the new
   pointer and the updated free pointer. Otherwise return [v] unchanged.

   In the baseline this returns a tuple (the OCaml-allocating choice). *)
let copy v free_ptr =
  if not (is_from_ptr v) then (v, free_ptr)
  else begin
    let header_addr = v - word_bytes in
    let header = word_at header_addr in
    if is_forwarded header then
      (word_at v, free_ptr)
    else begin
      let total_words = header_total_words header in
      let bytes = total_words * word_bytes in
      let new_header_addr = free_ptr in
      memcpy_words new_header_addr header_addr total_words;
      let new_body_addr = new_header_addr + word_bytes in
      (* Install forwarding *)
      set_word_at header_addr 0;
      set_word_at v new_body_addr;
      (new_body_addr, free_ptr + bytes)
    end
  end

let collect () =
  let free_ptr = ref (to_space_start ()) in
  let scan_ptr = ref (to_space_start ()) in

  (* 1. Static roots *)
  let nstatic = static_root_count () in
  for i = 0 to nstatic - 1 do
    let root_addr = static_root_addr i in
    let v = word_at root_addr in
    let v', fp = copy v !free_ptr in
    free_ptr := fp;
    set_word_at root_addr v'
  done;

  (* 2. Per-thread roots *)
  let nthr = thread_count () in
  for t = 0 to nthr - 1 do
    if thread_active t then begin
      (* return value root *)
      let rv_addr = thread_retval_addr t in
      let rv = word_at rv_addr in
      if rv <> 0 then begin
        let rv', fp = copy rv !free_ptr in
        free_ptr := fp;
        set_word_at rv_addr rv'
      end;
      (* stack roots *)
      let sz = thread_stack_size t in
      for j = 0 to sz - 1 do
        let p_addr = thread_root_addr t j in
        let v = word_at p_addr in
        let v', fp = copy v !free_ptr in
        free_ptr := fp;
        set_word_at p_addr v'
      done
    end
  done;

  (* 3. Cheney walk *)
  while !scan_ptr < !free_ptr do
    let header = word_at !scan_ptr in
    let total_words = header_total_words header in
    for i = 1 to total_words - 1 do
      let field_addr = !scan_ptr + (i * word_bytes) in
      let v = word_at field_addr in
      let v', fp = copy v !free_ptr in
      free_ptr := fp;
      set_word_at field_addr v'
    done;
    scan_ptr := !scan_ptr + (total_words * word_bytes)
  done;

  let used_bytes = !free_ptr - to_space_start () in
  swap_spaces used_bytes

let () = Callback.register "gc_collect" collect
