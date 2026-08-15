module Rng = Algostream_rng.Rng

type spec =
  | Grid of float array
  | Uniform of {
      lo : float;
      hi : float;
    }
  | Log_uniform of {
      lo : float;
      hi : float;
    }
  | Int_range of {
      lo : int;
      hi : int;
      step : int;
    }

type dim = {
  name : string;
  spec : spec;
}

type t = dim list

let of_bounds bounds ?(points_per_dim = 5) () =
  List.map
    (fun (name, lo, hi) ->
      let k = max 2 points_per_dim in
      let values =
        Array.init k (fun i -> lo +. ((hi -. lo) *. float_of_int i /. float_of_int (k - 1))) in
        { name; spec = Grid values })
    bounds


let dim_values = function
  | Grid vs -> Some vs
  | Int_range { lo; hi; step } ->
    let step = max 1 step in
    let n = ((hi - lo) / step) + 1 in
      if n <= 0 then Some [||] else Some (Array.init n (fun i -> float_of_int (lo + (i * step))))
  | Uniform _ | Log_uniform _ -> None


let cardinality t =
  List.fold_left
    (fun acc d ->
      match (acc, dim_values d.spec) with
      | None, _ -> None
      | _, None -> None
      | Some n, Some vs -> Some (n * Array.length vs))
    (Some 1) t


let grid_points t ~max_points =
  match cardinality t with
  | None -> Error (`Too_large max_int)
  | Some n when n > max_points -> Error (`Too_large n)
  | Some 0 -> Ok [||]
  | Some _ ->
    (* Cartesian product, built by extending a prefix one dimension at a time. *)
    let acc = ref [ [] ] in
      List.iter
        (fun d ->
          match dim_values d.spec with
          | None -> ()
          | Some vs ->
            acc :=
              List.concat_map
                (fun prefix -> Array.to_list (Array.map (fun v -> (d.name, v) :: prefix) vs))
                !acc)
        t ;
      Ok (Array.of_list (List.map List.rev !acc))


let sample_dim d rng =
  match d.spec with
  | Grid vs -> if Array.length vs = 0 then 0.0 else vs.(Rng.int_below rng (Array.length vs))
  | Uniform { lo; hi } -> Rng.uniform_range rng ~lo ~hi
  | Log_uniform { lo; hi } ->
    (* Sample uniformly in log space so each decade gets equal attention. *)
    let l = log (Float.max 1e-12 lo) and h = log (Float.max 1e-12 hi) in
      exp (Rng.uniform_range rng ~lo:l ~hi:h)
  | Int_range { lo; hi; step } ->
    let step = max 1 step in
    let n = max 1 (((hi - lo) / step) + 1) in
      float_of_int (lo + (Rng.int_below rng n * step))


let sample t rng = List.map (fun d -> (d.name, sample_dim d rng)) t

let random_points t rng ~n = Array.init n (fun _ -> sample t rng)

(* Latin hypercube sampling.

   An earlier draft here used a Sobol sequence. Sobol needs per-dimension direction-number tables,
   and getting one row misaligned degrades coverage silently — the sequence still looks plausible,
   it just stops being low-discrepancy. Rather than ship a numeric table that cannot be verified
   from first principles, this uses LHS, which delivers the same "better coverage than independent
   random draws for the same budget" property and is correct by construction: each dimension is cut
   into n equal strata and every stratum receives exactly one sample.

   Marginal coverage is therefore perfect by construction; joint coverage is better than random but
   not as good as a correct Sobol sequence would be. That trade is stated rather than hidden. *)

let stratified_supported _ = true

let stratified_points t rng ~n =
  let dims = List.length t in
    if dims = 0 || n <= 0 then [||]
    else
      (* One independent stratum permutation per dimension. *)
      let perms =
        Array.init dims (fun _ ->
          let p = Array.init n (fun i -> i) in
            Rng.shuffle rng p ;
            p) in
        Array.init n (fun i ->
          List.mapi
            (fun d dim ->
              (* Sample uniformly WITHIN the stratum this point was assigned. *)
              let stratum = perms.(d).(i) in
              let u = (float_of_int stratum +. Rng.uniform rng) /. float_of_int n in
              let value =
                match dim.spec with
                | Grid vs ->
                  if Array.length vs = 0 then 0.0
                  else
                    vs.(min
                          (Array.length vs - 1)
                          (int_of_float (u *. float_of_int (Array.length vs))))
                | Uniform { lo; hi } -> lo +. (u *. (hi -. lo))
                | Log_uniform { lo; hi } ->
                  let l = log (Float.max 1e-12 lo) and h = log (Float.max 1e-12 hi) in
                    exp (l +. (u *. (h -. l)))
                | Int_range { lo; hi; step } ->
                  let step = max 1 step in
                  let k = max 1 (((hi - lo) / step) + 1) in
                    float_of_int (lo + (min (k - 1) (int_of_float (u *. float_of_int k)) * step))
              in
                (dim.name, value))
            t)


let neighbours t point =
  let out = ref [] in
    List.iter
      (fun d ->
        match dim_values d.spec with
        | None -> ()
        | Some vs ->
          let cur = match List.assoc_opt d.name point with Some v -> v | None -> 0.0 in
          (* Index of the nearest grid value to the current one. *)
          let best = ref 0 in
          let bd = ref infinity in
            Array.iteri
              (fun i v ->
                let dist = Float.abs (v -. cur) in
                  if dist < !bd then (
                    bd := dist ;
                    best := i))
              vs ;
            List.iter
              (fun offset ->
                let j = !best + offset in
                  if j >= 0 && j < Array.length vs then
                    out :=
                      List.map
                        (fun (k, v) -> if String.equal k d.name then (k, vs.(j)) else (k, v))
                        point
                      :: !out)
              [ -1; 1 ])
      t ;
    Array.of_list (List.rev !out)


let clamp t point =
  List.map
    (fun (k, v) ->
      match List.find_opt (fun d -> String.equal d.name k) t with
      | None -> (k, v)
      | Some d ->
        (match d.spec with
        | Grid vs ->
          if Array.length vs = 0 then (k, v)
          else
            let best = ref vs.(0) in
            let bd = ref infinity in
              Array.iter
                (fun x ->
                  let dist = Float.abs (x -. v) in
                    if dist < !bd then (
                      bd := dist ;
                      best := x))
                vs ;
              (k, !best)
        | Uniform { lo; hi } | Log_uniform { lo; hi } ->
          (k, if v < lo then lo else if v > hi then hi else v)
        | Int_range { lo; hi; step } ->
          (* Snap to the nearest value actually IN the range, not merely inside its bounds:
             Int_range {lo=0; hi=10; step=5} admits 0, 5, 10 — never 7. *)
          let step = max 1 step in
          let i = int_of_float (Float.round v) in
          let i = if i < lo then lo else if i > hi then hi else i in
          let snapped =
            lo + (int_of_float (Float.round (float_of_int (i - lo) /. float_of_int step)) * step)
          in
          let snapped = if snapped > hi then hi else snapped in
            (k, float_of_int snapped)))
    point


let spec_to_string = function
  | Grid vs -> Printf.sprintf "grid[%d]" (Array.length vs)
  | Uniform { lo; hi } -> Printf.sprintf "uniform(%g,%g)" lo hi
  | Log_uniform { lo; hi } -> Printf.sprintf "log_uniform(%g,%g)" lo hi
  | Int_range { lo; hi; step } -> Printf.sprintf "int(%d..%d/%d)" lo hi step


let to_string t =
  String.concat ", " (List.map (fun d -> Printf.sprintf "%s:%s" d.name (spec_to_string d.spec)) t)
