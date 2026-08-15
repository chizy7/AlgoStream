type kind =
  | Simple
  | Log

let of_nav ~nav ~kind =
  let n = Array.length nav in
    if n < 2 then [||]
    else
      let out = Array.make (n - 1) 0.0 in
      let count = ref 0 in
      let stop = ref false in
        for i = 1 to n - 1 do
          if not !stop then
            let _, prev = nav.(i - 1) in
            let _, cur = nav.(i) in
              (* Terminate rather than emit nan/-inf. An equity curve that reaches zero has no
                 meaningful return afterwards, and a single nan would poison every downstream metric
                 silently. *)
              if
                prev <= 0.0 || cur <= 0.0
                || (not (Float.is_finite prev))
                || not (Float.is_finite cur)
              then stop := true
              else (
                out.(!count) <-
                  (match kind with Simple -> (cur /. prev) -. 1.0 | Log -> log (cur /. prev)) ;
                incr count)
        done ;
        if !count = n - 1 then out else Array.sub out 0 !count


let infer_interval_ns ~nav =
  let n = Array.length nav in
    if n < 2 then 0L
    else
      let gaps =
        Array.init (n - 1) (fun i ->
          let t0, _ = nav.(i) in
          let t1, _ = nav.(i + 1) in
            Int64.sub t1 t0) in
        Array.sort Int64.compare gaps ;
        (* Median, not mean — one weekend gap should not redefine the cadence. *)
        gaps.(Array.length gaps / 2)


let periods_per_year ?(days_per_year = 365.0) ?(hours_per_day = 24.0) ~interval_ns () =
  if Int64.compare interval_ns 0L <= 0 then 0.0
  else
    let ns_per_year = days_per_year *. hours_per_day *. 3600.0 *. 1e9 in
      ns_per_year /. Int64.to_float interval_ns


let per_period_rate ~annual_rate ~periods_per_year =
  if periods_per_year <= 0.0 then 0.0
  else ((1.0 +. annual_rate) ** (1.0 /. periods_per_year)) -. 1.0


let excess ~returns ~risk_free_rate_ann ~periods_per_year =
  let rf = per_period_rate ~annual_rate:risk_free_rate_ann ~periods_per_year in
    if rf = 0.0 then Array.copy returns else Array.map (fun r -> r -. rf) returns


let total_return ~returns ~kind =
  match kind with
  | Simple -> Array.fold_left (fun acc r -> acc *. (1.0 +. r)) 1.0 returns -. 1.0
  | Log -> exp (Array.fold_left ( +. ) 0.0 returns) -. 1.0


let mean a =
  let n = Array.length a in
    if n = 0 then 0.0 else Array.fold_left ( +. ) 0.0 a /. float_of_int n


let stddev a =
  let n = Array.length a in
    if n < 2 then 0.0
    else
      let m = mean a in
      let ss = Array.fold_left (fun acc x -> acc +. ((x -. m) *. (x -. m))) 0.0 a in
        sqrt (ss /. float_of_int (n - 1))


let downside_deviation ~returns ~mar =
  let n = Array.length returns in
    if n = 0 then 0.0
    else
      let ss =
        Array.fold_left
          (fun acc r ->
            let d = r -. mar in
              if d < 0.0 then acc +. (d *. d) else acc)
          0.0 returns in
        (* Full-sample n denominator — see the .mli. *)
        sqrt (ss /. float_of_int n)
