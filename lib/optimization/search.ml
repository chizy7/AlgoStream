module Metrics = Algostream_performance.Metrics
module Rng = Algostream_rng.Rng
module Pool = Algostream_montecarlo.Pool
module Nelder_mead = Algostream_advanced_models.Nelder_mead

type trial = {
  index : int;
  params : (string * float) list;
  metrics : Metrics.t option;
  score : float;
  error : string option;
}

type report = {
  objective : string;
  trials : trial array;
  best : trial option;
  n_evaluated : int;
  n_failed : int;
  score_stdev : float;
}

type eval = (string * float) list -> Metrics.t

let stdev_of xs =
  let finite = List.filter (fun x -> Float.is_finite x) xs in
  let n = List.length finite in
    if n < 2 then 0.0
    else
      let m = List.fold_left ( +. ) 0.0 finite /. float_of_int n in
      let ss = List.fold_left (fun a x -> a +. ((x -. m) *. (x -. m))) 0.0 finite in
        sqrt (ss /. float_of_int (n - 1))


let assemble ~objective ~trials =
  let n_failed = Array.fold_left (fun a t -> if t.error <> None then a + 1 else a) 0 trials in
  let best =
    Array.fold_left
      (fun acc t ->
        match acc with
        | None -> if t.error = None then Some t else None
        | Some b -> if t.error = None && t.score > b.score then Some t else acc)
      None trials in
    {
      objective = objective.Objective.name;
      trials;
      best;
      n_evaluated = Array.length trials;
      n_failed;
      score_stdev = stdev_of (Array.to_list (Array.map (fun t -> t.score) trials));
    }


(* Evaluate a set of points through the pool, indexed by trial so results come back in trial order
   regardless of scheduling. *)
let evaluate ~points ~objective ~eval ~n_domains =
  let n = Array.length points in
  let rs =
    Pool.map_result ~n_domains ~n ~f:(fun i ->
      let m = eval points.(i) in
        (m, Objective.score objective m)) in
    Array.mapi
      (fun i r ->
        match r with
        | Ok (m, s) -> { index = i; params = points.(i); metrics = Some m; score = s; error = None }
        | Error e ->
          {
            index = i;
            params = points.(i);
            metrics = None;
            score = neg_infinity;
            error = Some (Printexc.to_string e);
          })
      rs


let grid ~space ~objective ~eval ~n_domains ~max_points =
  match Search_space.grid_points space ~max_points with
  | Error (`Too_large n) -> Error (`Too_large n)
  | Ok points -> Ok (assemble ~objective ~trials:(evaluate ~points ~objective ~eval ~n_domains))


let random ~space ~objective ~eval ~n_domains ~n ~root_seed =
  let rng = Rng.substream ~root_seed ~index:0 in
  let points = Search_space.random_points space rng ~n in
    assemble ~objective ~trials:(evaluate ~points ~objective ~eval ~n_domains)


let stratified ~space ~objective ~eval ~n_domains ~n ~root_seed =
  let rng = Rng.substream ~root_seed ~index:1 in
  let points = Search_space.stratified_points space rng ~n in
    assemble ~objective ~trials:(evaluate ~points ~objective ~eval ~n_domains)


let coordinate_descent ~space ~objective ~eval ~x0 ~max_passes =
  let all = ref [] in
  let idx = ref 0 in
  let score_point p =
    let t =
      try
        let m = eval p in
          {
            index = !idx;
            params = p;
            metrics = Some m;
            score = Objective.score objective m;
            error = None;
          }
      with e ->
        {
          index = !idx;
          params = p;
          metrics = None;
          score = neg_infinity;
          error = Some (Printexc.to_string e);
        } in
      incr idx ;
      all := t :: !all ;
      t in
  let current = ref (score_point (Search_space.clamp space x0)) in
  let improved = ref true in
  let pass = ref 0 in
    (* Sequential by nature — each step depends on the previous winner — so no pool here. *)
    while !improved && !pass < max_passes do
      improved := false ;
      incr pass ;
      let neighbours = Search_space.neighbours space !current.params in
        Array.iter
          (fun p ->
            let t = score_point p in
              if t.score > !current.score then (
                current := t ;
                improved := true))
          neighbours
    done ;
    assemble ~objective ~trials:(Array.of_list (List.rev !all))


let nelder_mead_refine ~space ~objective ~eval ~x0 =
  let dims = List.length x0 in
    if dims > 4 then Error (`Too_many_dimensions dims)
    else
      let names = List.map fst x0 in
      let all = ref [] in
      let idx = ref 0 in
      let to_point v = Search_space.clamp space (List.mapi (fun i n -> (n, v.(i))) names) in
      (* Nelder_mead minimizes; the objective maximizes. Negate at the boundary. *)
      let f v =
        let p = to_point v in
        let t =
          try
            let m = eval p in
              {
                index = !idx;
                params = p;
                metrics = Some m;
                score = Objective.score objective m;
                error = None;
              }
          with e ->
            {
              index = !idx;
              params = p;
              metrics = None;
              score = neg_infinity;
              error = Some (Printexc.to_string e);
            } in
          incr idx ;
          all := t :: !all ;
          if Float.is_finite t.score then -.t.score else Float.max_float in
      let x0_arr = Array.of_list (List.map snd x0) in
      let _ = Nelder_mead.minimize ~f ~x0:x0_arr () in
        Ok (assemble ~objective ~trials:(Array.of_list (List.rev !all)))


let report_to_string r =
  let b = Buffer.create 256 in
    Buffer.add_string b
      (Printf.sprintf "search[%s]: %d evaluated, %d failed, score sd=%.4f\n" r.objective
         r.n_evaluated r.n_failed r.score_stdev) ;
    (match r.best with
    | None -> Buffer.add_string b "  no successful trial\n"
    | Some t ->
      Buffer.add_string b
        (Printf.sprintf "  best score=%.6f at %s\n" t.score
           (String.concat " " (List.map (fun (k, v) -> Printf.sprintf "%s=%g" k v) t.params)))) ;
    Buffer.contents b
