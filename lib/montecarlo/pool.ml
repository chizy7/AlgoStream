let recommended_domains () = max 1 (Domain.recommended_domain_count () - 1)

let map_result ~n_domains ~n ~f =
  if n <= 0 then [||]
  else
    (* Pre-allocated result slots indexed by work item. Nothing is appended in completion order,
       which is the whole basis of the determinism contract. *)
    let results : ('a, exn) Stdlib.result option array = Array.make n None in
    let run_one i =
      let r = try Ok (f i) with e -> Error e in
        results.(i) <- Some r in
    let workers = min (max 1 n_domains) n in
      (if workers <= 1 then
         for i = 0 to n - 1 do
           run_one i
         done
       else
         let cursor = Atomic.make 0 in
         let worker () =
           let rec loop () =
             let i = Atomic.fetch_and_add cursor 1 in
               if i < n then (
                 run_one i ;
                 loop ()) in
             loop () in
         let domains = Array.init (workers - 1) (fun _ -> Domain.spawn worker) in
           (* The calling Domain works too rather than blocking — otherwise a pool of N leaves N+1
              threads for N cores. *)
           worker () ;
           Array.iter Domain.join domains) ;
      Array.map
        (function
          | Some r -> r
          | None ->
            (* Unreachable: every index is claimed exactly once by the cursor. *)
            Error (Failure "Pool: work item never ran"))
        results


let map ~n_domains ~n ~f =
  let rs = map_result ~n_domains ~n ~f in
  (* Re-raise the lowest failing index, so which exception surfaces does not depend on
     scheduling. *)
  let first_error = ref None in
    Array.iteri
      (fun i r ->
        match (r, !first_error) with Error e, None -> first_error := Some (i, e) | _ -> ())
      rs ;
    match !first_error with
    | Some (_, e) -> raise e
    | None -> Array.map (function Ok v -> v | Error e -> raise e) rs


let iter ~n_domains ~n ~f = ignore (map ~n_domains ~n ~f:(fun i -> f i))
