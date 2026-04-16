module type G = Allocation_free_gc.Gc_sig.S

let run_workload (module M : G) ~threads ~iters ~gc_period =
  M.reset ();
  let t0 = Unix.gettimeofday () in
  let domains =
    Array.init threads (fun tid ->
        Domain.spawn (fun () ->
            let root_slot = tid * 8 in
            let rec loop i =
              if i = iters then ()
              else
                let _obj = M.alloc_object_rooted ~root_slot ~fields:2 ~tag:tid in
                if i mod gc_period = 0 then M.collect ();
                loop (i + 1)
            in
            loop 0;
            M.clear_root root_slot))
  in
  Array.iter Domain.join domains;
  M.collect ();
  let t1 = Unix.gettimeofday () in
  t1 -. t0

let print_result name threads secs ops =
  let throughput = float_of_int ops /. secs in
  Printf.printf "%s,%d,%.6f,%.2f\n%!" name threads secs throughput

let run_suite name gc_module =
  let thread_counts = [| 1; 2; 4; 8 |] in
  let iters = 100_000 in
  Array.iter
    (fun th ->
      let secs = run_workload gc_module ~threads:th ~iters ~gc_period:2000 in
      print_result name th secs (th * iters))
    thread_counts

let () =
  Printf.printf "collector,threads,seconds,throughput_ops_per_sec\n%!";
  run_suite "alloc_free_semispace" (module Allocation_free_gc.Alloc_free_gc);
  run_suite "dynamic_semispace" (module Allocation_free_gc.Dynamic_gc)
