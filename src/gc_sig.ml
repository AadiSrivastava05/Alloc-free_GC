module type S = sig
  type handle = int

  exception Out_of_memory
  exception Invalid_handle

  val reset : unit -> unit
  val alloc_object : fields:int -> tag:int -> handle
  val alloc_object_rooted : root_slot:int -> fields:int -> tag:int -> handle
  val set_field : handle -> int -> handle -> unit
  val get_field : handle -> int -> handle
  val set_int_field : handle -> int -> int -> unit
  val get_int_field : handle -> int -> int

  val set_root : int -> handle -> unit
  val get_root : int -> handle
  val clear_root : int -> unit
  val collect : unit -> unit

  val used_words : unit -> int
  val total_words : unit -> int
end
