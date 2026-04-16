module Dynamic_gc : Gc_sig.S = struct
  type handle = int

  exception Out_of_memory
  exception Invalid_handle

  let word_null = 0
  let header_shift = 20
  let tag_mask = (1 lsl header_shift) - 1
  let max_roots = 4096

  let roots = Array.make max_roots word_null

  type state = {
    mutable from_space : int array;
    mutable to_space : int array;
    mutable alloc_ptr : int;
  }

  let state = { from_space = Array.make 1 word_null; to_space = [||]; alloc_ptr = 1 }
  let lock = Mutex.create ()

  let encode_ptr i = i lsl 1
  let decode_ptr p = p lsr 1
  let is_immediate v = v land 1 = 1
  let is_ptr v = v <> 0 && (not (is_immediate v))
  let encode_int n = (n lsl 1) lor 1
  let decode_int v = v asr 1
  let make_header fields tag = (fields lsl header_shift) lor (tag land tag_mask)
  let header_fields hdr = hdr lsr header_shift

  let ensure_init () =
    if Array.length state.from_space <= 1 then (
      state.from_space <- Array.make 262_144 word_null;
      state.to_space <- Array.make 262_144 word_null;
      state.alloc_ptr <- 1
    )

  let reset () =
    Mutex.lock lock;
    ensure_init ();
    Array.fill state.from_space 0 (Array.length state.from_space) word_null;
    Array.fill state.to_space 0 (Array.length state.to_space) word_null;
    Array.fill roots 0 max_roots word_null;
    state.alloc_ptr <- 1;
    Mutex.unlock lock

  let check_handle h =
    let i = decode_ptr h in
    if i <= 0 || i >= Array.length state.from_space then raise Invalid_handle

  let rec copy_value froms tos free_ptr v =
    if not (is_ptr v) then (v, free_ptr)
    else
      let src = decode_ptr v in
      if src <= 0 || src >= Array.length froms then (v, free_ptr)
      else
        let header_or_fwd = froms.(src) in
        if header_or_fwd = word_null then (froms.(src + 1), free_ptr)
        else
          let fields = header_fields header_or_fwd in
          let words = fields + 1 in
          Array.blit froms src tos free_ptr words;
          froms.(src) <- word_null;
          froms.(src + 1) <- encode_ptr free_ptr;
          (encode_ptr free_ptr, free_ptr + words)

  and collect_unlocked () =
    ensure_init ();
    Array.fill state.to_space 0 (Array.length state.to_space) word_null;
    let free_ptr = ref 1 in
    for i = 0 to max_roots - 1 do
      let r = roots.(i) in
      if r <> word_null then (
        let v, next = copy_value state.from_space state.to_space !free_ptr r in
        roots.(i) <- v;
        free_ptr := next
      )
    done;
    let scan = ref 1 in
    while !scan < !free_ptr do
      let hdr = state.to_space.(!scan) in
      let fields = header_fields hdr in
      for i = 1 to fields do
        let v, next =
          copy_value state.from_space state.to_space !free_ptr state.to_space.(!scan + i)
        in
        state.to_space.(!scan + i) <- v;
        free_ptr := next
      done;
      scan := !scan + fields + 1
    done;
    let tmp = state.from_space in
    state.from_space <- state.to_space;
    state.to_space <- tmp;
    state.alloc_ptr <- !free_ptr

  let alloc_object ~fields ~tag =
    if fields < 0 then raise Invalid_handle;
    Mutex.lock lock;
    ensure_init ();
    let needed = fields + 1 in
    if state.alloc_ptr + needed >= Array.length state.from_space then collect_unlocked ();
    if state.alloc_ptr + needed >= Array.length state.from_space then (
      let next_size = (Array.length state.from_space * 2) + needed in
      state.from_space <- Array.append state.from_space (Array.make next_size word_null);
      state.to_space <- Array.make (Array.length state.from_space) word_null
    );
    let base = state.alloc_ptr in
    state.from_space.(base) <- make_header fields tag;
    for i = 1 to fields do
      state.from_space.(base + i) <- word_null
    done;
    state.alloc_ptr <- base + needed;
    Mutex.unlock lock;
    encode_ptr base

  let alloc_object_rooted ~root_slot ~fields ~tag =
    if root_slot < 0 || root_slot >= max_roots then raise Invalid_handle;
    let h = alloc_object ~fields ~tag in
    Mutex.lock lock;
    roots.(root_slot) <- h;
    Mutex.unlock lock;
    h

  let set_root slot h =
    if slot < 0 || slot >= max_roots then raise Invalid_handle;
    Mutex.lock lock;
    roots.(slot) <- h;
    Mutex.unlock lock

  let get_root slot =
    if slot < 0 || slot >= max_roots then raise Invalid_handle;
    Mutex.lock lock;
    let h = roots.(slot) in
    Mutex.unlock lock;
    h

  let clear_root slot =
    if slot < 0 || slot >= max_roots then raise Invalid_handle;
    Mutex.lock lock;
    roots.(slot) <- word_null;
    Mutex.unlock lock

  let set_field h idx v =
    Mutex.lock lock;
    check_handle h;
    let base = decode_ptr h in
    let fields = header_fields state.from_space.(base) in
    if idx < 0 || idx >= fields then (
      Mutex.unlock lock;
      raise Invalid_handle
    );
    state.from_space.(base + idx + 1) <- v;
    Mutex.unlock lock

  let get_field h idx =
    Mutex.lock lock;
    check_handle h;
    let base = decode_ptr h in
    let fields = header_fields state.from_space.(base) in
    if idx < 0 || idx >= fields then (
      Mutex.unlock lock;
      raise Invalid_handle
    );
    let v = state.from_space.(base + idx + 1) in
    Mutex.unlock lock;
    v

  let set_int_field h idx n = set_field h idx (encode_int n)
  let get_int_field h idx = decode_int (get_field h idx)

  let collect () =
    Mutex.lock lock;
    collect_unlocked ();
    Mutex.unlock lock

  let used_words () = state.alloc_ptr
  let total_words () = Array.length state.from_space
end

include Dynamic_gc
