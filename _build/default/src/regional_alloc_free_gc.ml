module Regional_alloc_free_gc = struct
  type handle = int

  exception Out_of_memory
  exception Invalid_handle

  let word_null = 0
  let header_shift = 20
  let tag_mask = (1 lsl header_shift) - 1

  type runtime = {
    from_space : int array;
    to_space : int array;
    roots : int array;
    mutable active_from : bool;
    mutable alloc_ptr : int;
    mutable gc_free_ptr : int;
    mutable gc_scan_ptr : int;
  }

  let encode_ptr i = i lsl 1
  let decode_ptr p = p lsr 1
  let is_immediate v = v land 1 = 1
  let is_ptr v = v <> 0 && (not (is_immediate v))
  let encode_int n = (n lsl 1) lor 1
  let decode_int v = v asr 1
  let make_header fields tag = (fields lsl header_shift) lor (tag land tag_mask)
  let header_fields hdr = hdr lsr header_shift

  let current_space (rt : runtime) = if rt.active_from then rt.from_space else rt.to_space
  let other_space (rt : runtime) = if rt.active_from then rt.to_space else rt.from_space
  let semispace_words (rt : runtime) = Array.length rt.from_space
  let root_slots (rt : runtime) = Array.length rt.roots

  let clear_array arr =
    for i = 0 to Array.length arr - 1 do
      arr.(i) <- word_null
    done

  (* Build a runtime in the caller's region. *)
  let make_runtime
      (from_space @ local)
      (to_space @ local)
      (roots @ local)
      =
    if Array.length from_space <> Array.length to_space then
      invalid_arg "from_space and to_space must have equal size";
    exclave_ stack_ {
      from_space;
      to_space;
      roots;
      active_from = true;
      alloc_ptr = 1;
      gc_free_ptr = 1;
      gc_scan_ptr = 1;
    }

  let reset (rt : runtime) =
    clear_array rt.from_space;
    clear_array rt.to_space;
    clear_array rt.roots;
    rt.active_from <- true;
    rt.alloc_ptr <- 1;
    rt.gc_free_ptr <- 1;
    rt.gc_scan_ptr <- 1

  let check_handle (rt : runtime) h =
    let i = decode_ptr h in
    if i <= 0 || i >= semispace_words rt then raise Invalid_handle

  let[@zero_alloc] copy_value (rt : runtime) froms tos v =
    if not (is_ptr v) then v
    else
      let src = decode_ptr v in
      if src <= 0 || src >= semispace_words rt then v
      else
        let header_or_fwd = froms.(src) in
        if header_or_fwd = word_null then froms.(src + 1)
        else
          let fields = header_fields header_or_fwd in
          let words = fields + 1 in
          let dest = rt.gc_free_ptr in
          for i = 0 to words - 1 do
            tos.(dest + i) <- froms.(src + i)
          done;
          froms.(src) <- word_null;
          froms.(src + 1) <- encode_ptr dest;
          rt.gc_free_ptr <- dest + words;
          encode_ptr dest

  let[@zero_alloc] collect (rt : runtime) =
    let froms = current_space rt in
    let tos = other_space rt in
    clear_array tos;
    rt.gc_free_ptr <- 1;
    for i = 0 to root_slots rt - 1 do
      let r = rt.roots.(i) in
      if r <> word_null then rt.roots.(i) <- copy_value rt froms tos r
    done;
    rt.gc_scan_ptr <- 1;
    while rt.gc_scan_ptr < rt.gc_free_ptr do
      let scan = rt.gc_scan_ptr in
      let hdr = tos.(scan) in
      let fields = header_fields hdr in
      for i = 1 to fields do
        tos.(scan + i) <- copy_value rt froms tos tos.(scan + i)
      done;
      rt.gc_scan_ptr <- scan + fields + 1
    done;
    rt.alloc_ptr <- rt.gc_free_ptr;
    rt.active_from <- not rt.active_from

  let[@zero_alloc] alloc_object_rooted (rt : runtime) ~root_slot ~fields ~tag =
    if root_slot < 0 || root_slot >= root_slots rt then raise Invalid_handle;
    if fields < 0 then raise Invalid_handle;
    let needed = fields + 1 in
    if rt.alloc_ptr + needed >= semispace_words rt then collect rt;
    if rt.alloc_ptr + needed >= semispace_words rt then raise Out_of_memory;
    let space = current_space rt in
    let base = rt.alloc_ptr in
    space.(base) <- make_header fields tag;
    for i = 1 to fields do
      space.(base + i) <- word_null
    done;
    let h = encode_ptr base in
    rt.roots.(root_slot) <- h;
    rt.alloc_ptr <- base + needed;
    h

  let set_root (rt : runtime) slot h =
    if slot < 0 || slot >= root_slots rt then raise Invalid_handle;
    rt.roots.(slot) <- h

  let get_root (rt : runtime) slot =
    if slot < 0 || slot >= root_slots rt then raise Invalid_handle;
    rt.roots.(slot)

  let clear_root (rt : runtime) slot =
    if slot < 0 || slot >= root_slots rt then raise Invalid_handle;
    rt.roots.(slot) <- word_null

  let set_field (rt : runtime) h idx v =
    check_handle rt h;
    let space = current_space rt in
    let base = decode_ptr h in
    let hdr = space.(base) in
    let fields = header_fields hdr in
    if idx < 0 || idx >= fields then raise Invalid_handle;
    space.(base + idx + 1) <- v

  let get_field (rt : runtime) h idx =
    check_handle rt h;
    let space = current_space rt in
    let base = decode_ptr h in
    let hdr = space.(base) in
    let fields = header_fields hdr in
    if idx < 0 || idx >= fields then raise Invalid_handle;
    space.(base + idx + 1)

  let set_int_field rt h idx n = set_field rt h idx (encode_int n)
  let get_int_field rt h idx = decode_int (get_field rt h idx)

  let used_words (rt : runtime) = rt.alloc_ptr
  let total_words (rt : runtime) = semispace_words rt
end

include Regional_alloc_free_gc
