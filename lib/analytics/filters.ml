module Stats = Algostream_common_utils.Math_utils.Statistics

(* ───── Sanity ──────────────────────────────────────────────────────── *)

module Sanity = struct
  type verdict =
    | Ok
    | Reject of string

  let check ~price ~size =
    if not (Float.is_finite price) then Reject "price not finite"
    else if not (Float.is_finite size) then Reject "size not finite"
    else if price <= 0.0 then Reject "price <= 0"
    else if size <= 0.0 then Reject "size <= 0"
    else Ok
end

(* ───── EWMA with RiskMetrics bias correction ─────────────────────── *)

module Ewma = struct
  type t = {
    alpha : float;
    mutable s : float;
    mutable w : float;
    mutable n : int;
  }

  let create ~period =
    let alpha = 2.0 /. (float_of_int period +. 1.0) in
      { alpha; s = 0.0; w = 0.0; n = 0 }


  let update t x =
    t.s <- (t.alpha *. x) +. ((1.0 -. t.alpha) *. t.s) ;
    t.w <- t.alpha +. ((1.0 -. t.alpha) *. t.w) ;
    t.n <- t.n + 1 ;
    if t.w > 0.0 then t.s /. t.w else x


  let value t = if t.w > 0.0 then t.s /. t.w else 0.0

  let ready t = t.w >= 0.95

  let n t = t.n
end

(* ───── EWMA variance with matched bias correction ─────────────────── *)

module Ewma_var = struct
  type t = {
    mean : Ewma.t;
    alpha : float;
    mutable s2 : float; (* squared-deviation accumulator *)
    mutable w : float;
    mutable n : int;
  }

  let create ~period =
    let alpha = 2.0 /. (float_of_int period +. 1.0) in
      { mean = Ewma.create ~period; alpha; s2 = 0.0; w = 0.0; n = 0 }


  let update t x =
    let mu_prev = Ewma.value t.mean in
    let _ = Ewma.update t.mean x in
    let dev = x -. mu_prev in
      t.s2 <- (t.alpha *. dev *. dev) +. ((1.0 -. t.alpha) *. t.s2) ;
      t.w <- t.alpha +. ((1.0 -. t.alpha) *. t.w) ;
      t.n <- t.n + 1 ;
      if t.w > 0.0 then t.s2 /. t.w else 0.0


  let value t = if t.w > 0.0 then t.s2 /. t.w else 0.0

  let std_dev t = sqrt (value t)

  let ready t = t.w >= 0.95
end

(* ───── 1-D Kalman filter (local-level) ───────────────────────────── *)

module Kalman1d = struct
  type t = {
    mutable signal_to_noise : float;
    warmup : int;
    mutable x_hat : float; (* state estimate *)
    mutable p : float; (* covariance *)
    mutable q : float; (* process noise *)
    mutable r : float; (* observation noise *)
    mutable n : int;
    mutable last_obs : float option;
    warmup_returns : Stats.streaming_stats; (* tick-to-tick log-return variance *)
    mutable residual_acc : Stats.streaming_stats;
  }

  let create ~signal_to_noise_ratio ~warmup =
    {
      signal_to_noise = signal_to_noise_ratio;
      warmup;
      x_hat = 0.0;
      p = 1.0;
      q = 0.0;
      r = 0.0;
      n = 0;
      last_obs = None;
      warmup_returns = Stats.create_streaming_stats ();
      residual_acc = Stats.create_streaming_stats ();
    }


  let calibrate_qr t =
    let r = max 1e-12 (Stats.get_variance t.warmup_returns) in
    let q = r *. t.signal_to_noise in
      t.r <- r ;
      t.q <- q


  let recalibrate t =
    let r = max 1e-12 (Stats.get_variance t.residual_acc) in
    let q = r *. t.signal_to_noise in
      t.r <- r ;
      t.q <- q ;
      t.residual_acc <- Stats.create_streaming_stats ()


  let update t z =
    t.n <- t.n + 1 ;
    if t.n = 1 then (
      t.x_hat <- z ;
      t.last_obs <- Some z ;
      z)
    else (
      (match t.last_obs with
      | Some prev when prev > 0.0 && z > 0.0 ->
        Stats.update_streaming_stats t.warmup_returns (log (z /. prev))
      | _ -> ()) ;
      t.last_obs <- Some z ;
      if t.n = t.warmup then calibrate_qr t ;
      if t.n < t.warmup then (
        (* During warmup: smooth via running mean of warmup returns; cheaper than full Kalman. *)
        t.x_hat <- (0.5 *. t.x_hat) +. (0.5 *. z) ;
        t.x_hat)
      else
        (* Predict *)
        let p_pred = t.p +. t.q in
        (* Update *)
        let k = p_pred /. (p_pred +. t.r) in
        let residual = z -. t.x_hat in
          t.x_hat <- t.x_hat +. (k *. residual) ;
          t.p <- (1.0 -. k) *. p_pred ;
          Stats.update_streaming_stats t.residual_acc residual ;
          t.x_hat)


  let value t = t.x_hat

  let variance t = t.p

  let ready t = t.n >= t.warmup
end

(* ───── Median over a fixed window ─────────────────────────────────── *)

module Median_window = struct
  type t = {
    buffer : float array;
    window : int;
    mutable index : int;
    mutable count : int;
  }

  let create ~window = { buffer = Array.make window 0.0; window; index = 0; count = 0 }

  let update t x =
    t.buffer.(t.index) <- x ;
    t.index <- (t.index + 1) mod t.window ;
    if t.count < t.window then t.count <- t.count + 1 ;
    let n = t.count in
    let copy = Array.sub t.buffer 0 n in
      Array.sort Float.compare copy ;
      if n mod 2 = 1 then copy.(n / 2) else (copy.((n / 2) - 1) +. copy.(n / 2)) /. 2.0


  let mad t =
    let n = t.count in
      if n < 2 then 0.0
      else
        let copy = Array.sub t.buffer 0 n in
          Array.sort Float.compare copy ;
          let med =
            if n mod 2 = 1 then copy.(n / 2) else (copy.((n / 2) - 1) +. copy.(n / 2)) /. 2.0 in
          let dev = Array.map (fun v -> abs_float (v -. med)) copy in
            Array.sort Float.compare dev ;
            if n mod 2 = 1 then dev.(n / 2) else (dev.((n / 2) - 1) +. dev.(n / 2)) /. 2.0


  let n t = t.count
end
