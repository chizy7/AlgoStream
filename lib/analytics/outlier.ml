type verdict =
  | Pass
  | Reject of {
      reason : string;
      severity : int;
    }

module type FILTER = sig
  type t

  val name : string

  val update : t -> float -> verdict
end

module Sanity = struct
  type t = unit

  let name = "sanity"

  let update () x =
    if not (Float.is_finite x) then Reject { reason = "non-finite value"; severity = 3 }
    else if x <= 0.0 then Reject { reason = "non-positive value"; severity = 3 }
    else Pass
end

let sanity : Sanity.t = ()

module Z_score = struct
  type t = {
    ewma : Filters.Ewma.t;
    ewma_var : Filters.Ewma_var.t;
    threshold : float;
    warmup : int;
    mutable n : int;
  }

  let name = "z_score"

  let create ~threshold ~warmup ~ewma_period =
    {
      ewma = Filters.Ewma.create ~period:ewma_period;
      ewma_var = Filters.Ewma_var.create ~period:ewma_period;
      threshold;
      warmup;
      n = 0;
    }


  let update t x =
    t.n <- t.n + 1 ;
    let mu = Filters.Ewma.value t.ewma in
    let sigma = Filters.Ewma_var.std_dev t.ewma_var in
    let _ = Filters.Ewma.update t.ewma x in
    let _ = Filters.Ewma_var.update t.ewma_var x in
      if t.n <= t.warmup || sigma <= 1e-12 then Pass
      else
        let z = abs_float (x -. mu) /. sigma in
          if z > t.threshold then
            Reject { reason = Printf.sprintf "z=%.2f > %.2f" z t.threshold; severity = 1 }
          else Pass
end

module Hampel = struct
  type t = {
    median : Filters.Median_window.t;
    threshold : float;
    warmup : int;
    mutable n : int;
  }

  let name = "hampel"

  let create ~threshold ~warmup ~window =
    { median = Filters.Median_window.create ~window; threshold; warmup; n = 0 }


  let update t x =
    t.n <- t.n + 1 ;
    let med = Filters.Median_window.update t.median x in
    let mad = Filters.Median_window.mad t.median in
      if t.n <= t.warmup || mad <= 1e-12 then Pass
      else
        (* MAD-to-sigma scaling: 1.4826 for normally-distributed data. *)
        let sigma_est = 1.4826 *. mad in
        let z = abs_float (x -. med) /. sigma_est in
          if z > t.threshold then
            Reject { reason = Printf.sprintf "hampel z=%.2f > %.2f" z t.threshold; severity = 2 }
          else Pass
end

type runner = float -> verdict

let wrap (type a) (module F : FILTER with type t = a) (state : a) : runner = F.update state

let rec run runners x =
  match runners with
  | [] -> Pass
  | f :: rest -> (match f x with Pass -> run rest x | Reject _ as r -> r)
