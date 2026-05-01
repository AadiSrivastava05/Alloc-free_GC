(* gc_prims.ml — common noalloc primitive declarations used by every GC
   variant. Addresses are passed as plain OCaml ints; this round-trips
   safely on x86_64 because user-space addresses fit in 63 bits.

   None of these primitives allocate on the OCaml heap. *)

external from_space_start : unit -> int = "ml_from_space_start" [@@noalloc]
external from_space_end   : unit -> int = "ml_from_space_end"   [@@noalloc]
external to_space_start   : unit -> int = "ml_to_space_start"   [@@noalloc]
external heap_size_bytes  : unit -> int = "ml_heap_size_bytes"  [@@noalloc]

external word_at      : int -> int        = "ml_word_at"      [@@noalloc]
external set_word_at  : int -> int -> unit = "ml_set_word_at" [@@noalloc]
external memcpy_words : int -> int -> int -> unit = "ml_memcpy_words" [@@noalloc]

external is_from_ptr  : int -> bool = "ml_is_from_ptr" [@@noalloc]

external static_root_count : unit -> int = "ml_static_root_count" [@@noalloc]
external static_root_addr  : int -> int  = "ml_static_root_addr"  [@@noalloc]

external thread_count        : unit -> int = "ml_thread_count" [@@noalloc]
external thread_active       : int -> bool = "ml_thread_active" [@@noalloc]
external thread_retval_addr  : int -> int  = "ml_thread_retval_addr" [@@noalloc]
external thread_stack_size   : int -> int  = "ml_thread_stack_size"  [@@noalloc]
external thread_root_addr    : int -> int -> int = "ml_thread_root_addr" [@@noalloc]

external swap_spaces : int -> unit = "ml_swap_spaces" [@@noalloc]

(* Off-heap scratch state (variants 3, 4) *)
external get_g_free : unit -> int = "ml_get_g_free" [@@noalloc]
external set_g_free : int -> unit = "ml_set_g_free" [@@noalloc]
external get_g_scan : unit -> int = "ml_get_g_scan" [@@noalloc]
external set_g_scan : int -> unit = "ml_set_g_scan" [@@noalloc]

(* Service-loop hooks (variant 5) *)
external service_wait : unit -> unit = "ml_service_wait" [@@noalloc]
external service_done : unit -> unit = "ml_service_done" [@@noalloc]

(* Word size in bytes — constant, so no allocation. *)
let word_bytes = 8

(* Header layout: total_words << 10 | tag (low 10 bits). *)
let[@zero_alloc] [@inline always] header_total_words h = h lsr 10

(* Forwarded marker: header == 0 and field 0 (the second word) holds
   the new body address. *)
let[@zero_alloc] [@inline always] is_forwarded header = header = 0
