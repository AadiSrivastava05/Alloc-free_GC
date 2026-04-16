module Runtime_dynamic = struct
  module Gc = Dynamic_gc

  let init () = Gc.reset ()
  let alloc_object ~fields ~tag = Gc.alloc_object ~fields ~tag
  let alloc_object_rooted ~root_slot ~fields ~tag =
    Gc.alloc_object_rooted ~root_slot ~fields ~tag
  let set_ref = Gc.set_field
  let get_ref = Gc.get_field
  let set_int = Gc.set_int_field
  let get_int = Gc.get_int_field
  let set_root = Gc.set_root
  let get_root = Gc.get_root
  let clear_root = Gc.clear_root
  let collect = Gc.collect
  let used_words = Gc.used_words
  let total_words = Gc.total_words
end

include Runtime_dynamic
