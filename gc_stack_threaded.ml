(* gc_stack_threaded.ml — variant 5: a long-lived OxCaml service loop.

   The C side spawns a dedicated GC worker thread that calls into
   gc_service_run. That OCaml function runs forever, alternating
   between service_wait (blocks on a condvar) and a collection step.

   The loop body is entered through [exclave_] and keeps collector
   state in stack-resident [let mutable] slots inside the long-lived
   worker frame. This replaces the off-heap g_free/g_scan globals used
   by variants 3 and 4 while avoiding mutable-record/ref indirection in
   the hot path. *)

open Gc_prims

let[@zero_alloc] service_run () = exclave_
  let[@inline always] copy_into v free_ptr : #(int * int) =
    if not (is_from_ptr v) then #(v, free_ptr)
    else begin
      let header_addr = v - word_bytes in
      let header = word_at header_addr in
      if is_forwarded header then #(word_at v, free_ptr)
      else begin
        let total_words = header_total_words header in
        let bytes = total_words * word_bytes in
        let dst = free_ptr in
        memcpy_words dst header_addr total_words;
        let new_body_addr = dst + word_bytes in
        set_word_at header_addr 0;
        set_word_at v new_body_addr;
        #(new_body_addr, dst + bytes)
      end
    end
  in

  while true do
    service_wait ();

    let to_start = to_space_start () in
    let mutable free_ptr = to_start in
    let mutable scan_ptr = to_start in

    let nstatic = static_root_count () in
    for i = 0 to nstatic - 1 do
      let root_addr = static_root_addr i in
      let v = word_at root_addr in
      let #(v', fp) = copy_into v free_ptr in
      free_ptr <- fp;
      set_word_at root_addr v'
    done;

    let nthr = thread_count () in
    for t = 0 to nthr - 1 do
      if thread_active t then begin
        let rv_addr = thread_retval_addr t in
        let rv = word_at rv_addr in
        if rv <> 0 then begin
          let #(rv', fp) = copy_into rv free_ptr in
          free_ptr <- fp;
          set_word_at rv_addr rv'
        end;
        let sz = thread_stack_size t in
        for j = 0 to sz - 1 do
          let p_addr = thread_root_addr t j in
          let v = word_at p_addr in
          let #(v', fp) = copy_into v free_ptr in
          free_ptr <- fp;
          set_word_at p_addr v'
        done
      end
    done;

    while scan_ptr < free_ptr do
      let header = word_at scan_ptr in
      let total_words = header_total_words header in
      for i = 1 to total_words - 1 do
        let field_addr = scan_ptr + (i * word_bytes) in
        let v = word_at field_addr in
        let #(v', fp) = copy_into v free_ptr in
        free_ptr <- fp;
        set_word_at field_addr v'
      done;
      scan_ptr <- scan_ptr + (total_words * word_bytes)
    done;

    let used_bytes = free_ptr - to_start in
    swap_spaces used_bytes;
    service_done ()
  done

let () = Callback.register "gc_service_run" service_run
