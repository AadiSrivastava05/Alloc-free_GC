module type G = Allocation_free_gc.Gc_sig.S

let assert_true msg cond =
  if not cond then failwith msg

let cycle_test (module M : G) =
  M.reset ();
  let a = M.alloc_object ~fields:2 ~tag:1 in
  let b = M.alloc_object ~fields:2 ~tag:1 in
  M.set_root 0 a;
  M.set_root 1 b;
  M.set_field a 0 b;
  M.set_field b 0 a;
  M.set_int_field a 1 41;
  M.set_int_field b 1 42;
  M.collect ();
  let b_after = M.get_root 1 in
  assert_true "cycle root payload preserved" (M.get_int_field (M.get_field b_after 0) 1 = 41);
  M.clear_root 0;
  M.clear_root 1;
  M.collect ();
  assert_true "all garbage should be reclaimed" (M.used_words () = 1)

let concurrent_test (module M : G) =
  M.reset ();
  let workers = 4 in
  let iters = 30_000 in
  let tasks =
    Array.init workers (fun tid ->
        Domain.spawn (fun () ->
            let root_slot = tid * 4 in
            let rec loop i =
              if i = iters then ()
              else
                let _obj = M.alloc_object_rooted ~root_slot ~fields:1 ~tag:tid in
                if i mod 2000 = 0 then M.collect ();
                loop (i + 1)
            in
            loop 0;
            M.clear_root root_slot))
  in
  Array.iter Domain.join tasks;
  M.collect ();
  assert_true "post-thread cleanup should reclaim memory" (M.used_words () >= 1)

let exhaustion_test_alloc_free () =
  let module M = Allocation_free_gc.Alloc_free_gc in
  M.reset ();
  let rec consume n =
    let prev = M.get_root 10 in
    let h = M.alloc_object ~fields:2 ~tag:7 in
    M.set_field h 0 prev;
    M.set_int_field h 1 n;
    M.set_root 10 h;
    consume (n + 1)
  in
  try
    let _ = consume 0 in
    failwith "expected Out_of_memory but allocation kept succeeding"
  with
  | M.Out_of_memory -> ()

let run name f =
  try
    f ();
    Printf.printf "[PASS] %s\n%!" name
  with exn ->
    Printf.printf "[FAIL] %s: %s\n%!" name (Printexc.to_string exn);
    Printf.printf "%s\n%!" (Printexc.get_backtrace ());
    exit 1

let () =
  Printexc.record_backtrace true;
  run "alloc-free cycle test" (fun () -> cycle_test (module Allocation_free_gc.Alloc_free_gc));
  run "dynamic cycle test" (fun () -> cycle_test (module Allocation_free_gc.Dynamic_gc));
  run "alloc-free concurrent test" (fun () -> concurrent_test (module Allocation_free_gc.Alloc_free_gc));
  run "dynamic concurrent test" (fun () -> concurrent_test (module Allocation_free_gc.Dynamic_gc));
  run "alloc-free exhaustion test" exhaustion_test_alloc_free;
  Printf.printf "All GC tests passed.\n%!"
