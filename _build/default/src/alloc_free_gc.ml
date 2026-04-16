module Alloc_free_gc : Gc_sig.S = struct
  type handle = int

  exception Out_of_memory
  exception Invalid_handle

  let word_null = 0
  let header_shift = 20
  let tag_mask = (1 lsl header_shift) - 1

  (* Fixed footprint: all GC metadata and semispaces are static. *)
  let semispace_words = 262_144
  let max_roots = 4096

  let lock_word = Atomic.make 0
  let roots = Array.make max_roots word_null
  let from_space = Array.make semispace_words word_null
  let to_space = Array.make semispace_words word_null

  let active_from = Atomic.make true
  let alloc_ptr = Atomic.make 1
  let gc_free_ptr = Atomic.make 1
  let gc_scan_ptr = Atomic.make 1

  let encode_ptr i = i lsl 1
  let decode_ptr p = p lsr 1
  let is_immediate v = v land 1 = 1
  let is_ptr v = v <> 0 && (not (is_immediate v))
  let encode_int n = (n lsl 1) lor 1
  let decode_int v = v asr 1
  let make_header fields tag = (fields lsl header_shift) lor (tag land tag_mask)
  let header_fields hdr = hdr lsr header_shift

  let check_handle h =
    let i = decode_ptr h in
    if i <= 0 || i >= semispace_words then raise Invalid_handle

  let current_space () =
    if Atomic.get active_from then from_space else to_space

  let other_space () =
    if Atomic.get active_from then to_space else from_space

  let clear_array arr =
    for i = 0 to Array.length arr - 1 do
      arr.(i) <- word_null
    done

  let[@zero_alloc] rec lock_spin () =
    if Atomic.compare_and_set lock_word 0 1 then ()
    else (
      Domain.cpu_relax ();
      lock_spin ()
    )

  let[@zero_alloc] unlock_spin () = Atomic.set lock_word 0

  let reset () =
    lock_spin ();
    clear_array from_space;
    clear_array to_space;
    clear_array roots;
    Atomic.set active_from true;
    Atomic.set alloc_ptr 1;
    Atomic.set gc_free_ptr 1;
    Atomic.set gc_scan_ptr 1;
    unlock_spin ()

  let[@zero_alloc] rec copy_value froms tos v =
    if not (is_ptr v) then v
    else
      let src = decode_ptr v in
      if src <= 0 || src >= semispace_words then v
      else
        let header_or_fwd = froms.(src) in
        if header_or_fwd = word_null then froms.(src + 1)
        else
          let fields = header_fields header_or_fwd in
          let words = fields + 1 in
          let dest = Atomic.get gc_free_ptr in
          for i = 0 to words - 1 do
            tos.(dest + i) <- froms.(src + i)
          done;
          froms.(src) <- word_null;
          froms.(src + 1) <- encode_ptr dest;
          Atomic.set gc_free_ptr (dest + words);
          encode_ptr dest

  (* #[alloc_free] *)
  and[@zero_alloc] collect_unlocked () =
    let froms = current_space () in
    let tos = other_space () in
    clear_array tos;
    Atomic.set gc_free_ptr 1;
    for i = 0 to max_roots - 1 do
      let r = roots.(i) in
      if r <> word_null then roots.(i) <- copy_value froms tos r
    done;
    Atomic.set gc_scan_ptr 1;
    while Atomic.get gc_scan_ptr < Atomic.get gc_free_ptr do
      let scan = Atomic.get gc_scan_ptr in
      let hdr = tos.(scan) in
      let fields = header_fields hdr in
      for i = 1 to fields do
        tos.(scan + i) <- copy_value froms tos tos.(scan + i)
      done;
      Atomic.set gc_scan_ptr (scan + fields + 1)
    done;
    Atomic.set alloc_ptr (Atomic.get gc_free_ptr);
    Atomic.set active_from (not (Atomic.get active_from))

  (* #[alloc_free] *)
  let[@zero_alloc] alloc_object ~fields ~tag =
    if fields < 0 then raise Invalid_handle;
    lock_spin ();
    let needed = fields + 1 in
    if Atomic.get alloc_ptr + needed >= semispace_words then collect_unlocked ();
    if Atomic.get alloc_ptr + needed >= semispace_words then (
      unlock_spin ();
      raise Out_of_memory
    );
    let space = current_space () in
    let base = Atomic.get alloc_ptr in
    space.(base) <- make_header fields tag;
    for i = 1 to fields do
      space.(base + i) <- word_null
    done;
    Atomic.set alloc_ptr (base + needed);
    unlock_spin ();
    encode_ptr base

  let[@zero_alloc] alloc_object_rooted ~root_slot ~fields ~tag =
    if root_slot < 0 || root_slot >= max_roots then raise Invalid_handle;
    if fields < 0 then raise Invalid_handle;
    lock_spin ();
    let needed = fields + 1 in
    if Atomic.get alloc_ptr + needed >= semispace_words then collect_unlocked ();
    if Atomic.get alloc_ptr + needed >= semispace_words then (
      unlock_spin ();
      raise Out_of_memory
    );
    let space = current_space () in
    let base = Atomic.get alloc_ptr in
    space.(base) <- make_header fields tag;
    for i = 1 to fields do
      space.(base + i) <- word_null
    done;
    let h = encode_ptr base in
    roots.(root_slot) <- h;
    Atomic.set alloc_ptr (base + needed);
    unlock_spin ();
    h

  let set_root slot h =
    if slot < 0 || slot >= max_roots then raise Invalid_handle;
    lock_spin ();
    roots.(slot) <- h;
    unlock_spin ()

  let get_root slot =
    if slot < 0 || slot >= max_roots then raise Invalid_handle;
    lock_spin ();
    let h = roots.(slot) in
    unlock_spin ();
    h

  let clear_root slot =
    if slot < 0 || slot >= max_roots then raise Invalid_handle;
    lock_spin ();
    roots.(slot) <- word_null;
    unlock_spin ()

  let set_field h idx v =
    lock_spin ();
    check_handle h;
    let space = current_space () in
    let base = decode_ptr h in
    let hdr = space.(base) in
    let fields = header_fields hdr in
    if idx < 0 || idx >= fields then (
      unlock_spin ();
      raise Invalid_handle
    );
    space.(base + idx + 1) <- v;
    unlock_spin ()

  let get_field h idx =
    lock_spin ();
    check_handle h;
    let space = current_space () in
    let base = decode_ptr h in
    let hdr = space.(base) in
    let fields = header_fields hdr in
    if idx < 0 || idx >= fields then (
      unlock_spin ();
      raise Invalid_handle
    );
    let v = space.(base + idx + 1) in
    unlock_spin ();
    v

  let set_int_field h idx n = set_field h idx (encode_int n)
  let get_int_field h idx = decode_int (get_field h idx)

  let collect () =
    lock_spin ();
    collect_unlocked ();
    unlock_spin ()

  let used_words () = Atomic.get alloc_ptr
  let total_words () = semispace_words
end

include Alloc_free_gc
