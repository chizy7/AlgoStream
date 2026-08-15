(** Mathematical utilities optimized for trading applications *)

open Base

(** Fast mathematical operations with minimal allocations *)
module FastMath = struct
  (** Fast inverse square root (famous Quake algorithm) *)
  let fast_inv_sqrt x = 1.0 /. Float.sqrt x

  (** Fast logarithm approximation *)
  let fast_log x =
    if Float.(x <= 0.0) then Float.neg_infinity
    else
      let bits = Int64.bits_of_float x in
      let exp = Int64.((bits lsr 52) land 0x7ffL) |> Int64.to_int_trunc |> fun x -> x - 1023 in
      let mantissa = Int64.(bits land 0xfffffffffffffL) in
      let normalized = (Int64.to_float mantissa /. 4503599627370496.0) +. 1.0 in
        (Float.of_int exp *. 0.693147180559945) +. Float.log normalized


  (** Fast exponential approximation *)
  let fast_exp x =
    if Float.(x > 700.0) then Float.infinity
    else if Float.(x < -700.0) then 0.0
    else
      let n = Int.of_float ((x /. 0.693147180559945) +. 0.5) in
      let remainder = x -. (Float.of_int n *. 0.693147180559945) in
      let exp_remainder = 1.0 +. (remainder *. (1.0 +. (remainder /. 2.0))) in
        exp_remainder *. (Int.pow 2 n |> Float.of_int)


  (** Fast power function for integer exponents *)
  let fast_pow base exp =
    let rec power acc b e =
      if e = 0 then acc
      else if e % 2 = 0 then power acc (b *. b) (e / 2)
      else power (acc *. b) (b *. b) ((e - 1) / 2) in
      if exp < 0 then 1.0 /. power 1.0 base (-exp) else power 1.0 base exp
end

(** Statistical functions optimized for financial data *)
module Statistics = struct
  (** Online/streaming statistics calculation *)
  type streaming_stats = {
    mutable count : int;
    mutable mean : float;
    mutable m2 : float; (* Sum of squares of differences from mean *)
    mutable min_val : float;
    mutable max_val : float;
  }

  let create_streaming_stats () =
    { count = 0; mean = 0.0; m2 = 0.0; min_val = Float.infinity; max_val = Float.neg_infinity }


  let update_streaming_stats stats value =
    stats.count <- stats.count + 1 ;
    let delta = value -. stats.mean in
      stats.mean <- stats.mean +. (delta /. Float.of_int stats.count) ;
      let delta2 = value -. stats.mean in
        stats.m2 <- stats.m2 +. (delta *. delta2) ;
        stats.min_val <- Float.min stats.min_val value ;
        stats.max_val <- Float.max stats.max_val value


  let get_variance stats =
    if stats.count < 2 then 0.0 else stats.m2 /. Float.of_int (stats.count - 1)


  let get_std_dev stats = Float.sqrt (get_variance stats)

  (** Fast moving average using circular buffer *)
  type moving_average = {
    window_size : int;
    buffer : float array;
    mutable index : int;
    mutable sum : float;
    mutable count : int;
  }

  let create_moving_average window_size =
    { window_size; buffer = Array.create ~len:window_size 0.0; index = 0; sum = 0.0; count = 0 }


  let update_moving_average ma value =
    let old_value = ma.buffer.(ma.index) in
      ma.buffer.(ma.index) <- value ;
      ma.sum <- ma.sum -. old_value +. value ;
      ma.index <- (ma.index + 1) % ma.window_size ;
      if ma.count < ma.window_size then ma.count <- ma.count + 1 ;
      ma.sum /. Float.of_int ma.count


  (** Exponential moving average *)
  type ema = {
    alpha : float;
    mutable value : float;
    mutable initialized : bool;
  }

  let create_ema ~period =
    { alpha = 2.0 /. (Float.of_int period +. 1.0); value = 0.0; initialized = false }


  let update_ema ema new_value =
    if not ema.initialized then (
      ema.value <- new_value ;
      ema.initialized <- true)
    else ema.value <- (ema.alpha *. new_value) +. ((1.0 -. ema.alpha) *. ema.value) ;
    ema.value


  (** Efficient percentile calculation using reservoir sampling *)
  type percentile_tracker = {
    reservoir : float array;
    capacity : int;
    mutable count : int64;
    rng_state : Random.State.t;
  }

  let create_percentile_tracker capacity =
    {
      reservoir = Array.create ~len:capacity 0.0;
      capacity;
      count = 0L;
      rng_state = Random.State.make_self_init ();
    }


  let update_percentile_tracker tracker value =
    let count = Int64.to_int_trunc tracker.count in
      (if count < tracker.capacity then tracker.reservoir.(count) <- value
       else
         let j = Random.State.int tracker.rng_state count in
           if j < tracker.capacity then tracker.reservoir.(j) <- value) ;
      tracker.count <- Int64.(tracker.count + 1L)


  let get_percentile tracker p =
    let count = Int.min (Int64.to_int_trunc tracker.count) tracker.capacity in
      if count = 0 then 0.0
      else
        let sorted = Array.sub tracker.reservoir ~pos:0 ~len:count in
          Array.sort sorted ~compare:Float.compare ;
          let index = Float.to_int (p *. Float.of_int (count - 1)) in
            sorted.(index)
end

(** Financial mathematics functions *)
module FinancialMath = struct
  (** Black-Scholes option pricing *)
  let black_scholes ~call ~s ~k ~t ~r ~sigma =
    let d1 =
      (Float.log (s /. k) +. ((r +. (0.5 *. sigma *. sigma)) *. t)) /. (sigma *. Float.sqrt t) in
    let d2 = d1 -. (sigma *. Float.sqrt t) in

    (* Approximate normal CDF using fast implementation *)
    let norm_cdf x =
      let a1 = 0.254829592 in
      let a2 = -0.284496736 in
      let a3 = 1.421413741 in
      let a4 = -1.453152027 in
      let a5 = 1.061405429 in
      let p = 0.3275911 in

      let sign = if Float.(x >= 0.0) then 1.0 else -1.0 in
      let x_abs = Float.abs x in
      let t = 1.0 /. (1.0 +. (p *. x_abs)) in
      let y =
        1.0
        -. ((((((((a5 *. t) +. a4) *. t) +. a3) *. t) +. a2) *. t) +. a1)
           *. t
           *. FastMath.fast_exp (-.x_abs *. x_abs) in
        0.5 *. (1.0 +. (sign *. y)) in

    let nd1 = norm_cdf d1 in
    let nd2 = norm_cdf d2 in

    if call then (s *. nd1) -. (k *. FastMath.fast_exp (-.r *. t) *. nd2)
    else (k *. FastMath.fast_exp (-.r *. t) *. (1.0 -. nd2)) -. (s *. (1.0 -. nd1))


  (** Value at Risk calculation using historical simulation *)
  let value_at_risk returns confidence_level =
    let sorted_returns = Array.copy returns in
      Array.sort sorted_returns ~compare:Float.compare ;
      let index = Int.of_float ((1.0 -. confidence_level) *. Float.of_int (Array.length returns)) in
        if index >= Array.length sorted_returns then
          sorted_returns.(Array.length sorted_returns - 1)
        else sorted_returns.(index)


  (** Sharpe ratio calculation *)
  let sharpe_ratio returns risk_free_rate =
    let stats = Statistics.create_streaming_stats () in
      Array.iter returns ~f:(Statistics.update_streaming_stats stats) ;

      let excess_return = stats.mean -. risk_free_rate in
      let volatility = Statistics.get_std_dev stats in

      if Float.(volatility = 0.0) then 0.0 else excess_return /. volatility


  (** Maximum drawdown calculation *)
  let max_drawdown equity_curve =
    let peak = ref equity_curve.(0) in
    let max_dd = ref 0.0 in

    for i = 1 to Array.length equity_curve - 1 do
      if Float.(equity_curve.(i) > !peak) then peak := equity_curve.(i)
      else
        let drawdown = (!peak -. equity_curve.(i)) /. !peak in
          max_dd := Float.max !max_dd drawdown
    done ;

    !max_dd
end

(** High-performance linear algebra operations *)
module LinearAlgebra = struct
  (** Vector operations *)
  let dot_product v1 v2 =
    if Array.length v1 <> Array.length v2 then failwith "Vector dimensions must match" ;

    let sum = ref 0.0 in
      for i = 0 to Array.length v1 - 1 do
        sum := !sum +. (v1.(i) *. v2.(i))
      done ;
      !sum


  let vector_norm v = Float.sqrt (dot_product v v)

  let normalize_vector v =
    let norm = vector_norm v in
      if Float.(norm = 0.0) then v else Array.map v ~f:(fun x -> x /. norm)


  (** Matrix operations for small matrices (optimized for 2x2, 3x3) *)
  let matrix_2x2_det m = (m.(0).(0) *. m.(1).(1)) -. (m.(0).(1) *. m.(1).(0))

  let matrix_2x2_inv m =
    let det = matrix_2x2_det m in
      if Float.(abs det < 1e-10) then failwith "Matrix is singular" ;

      let inv_det = 1.0 /. det in
        [|
          [| m.(1).(1) *. inv_det; -.m.(0).(1) *. inv_det |];
          [| -.m.(1).(0) *. inv_det; m.(0).(0) *. inv_det |];
        |]


  (** Fast correlation coefficient calculation *)
  let correlation x y =
    if Array.length x <> Array.length y then failwith "Array lengths must match" ;

    let n = Array.length x in
      if n < 2 then failwith "Need at least 2 data points" ;

      let sum_x = ref 0.0 in
      let sum_y = ref 0.0 in
      let sum_xx = ref 0.0 in
      let sum_yy = ref 0.0 in
      let sum_xy = ref 0.0 in

      for i = 0 to n - 1 do
        let xi = x.(i) in
        let yi = y.(i) in
          sum_x := !sum_x +. xi ;
          sum_y := !sum_y +. yi ;
          sum_xx := !sum_xx +. (xi *. xi) ;
          sum_yy := !sum_yy +. (yi *. yi) ;
          sum_xy := !sum_xy +. (xi *. yi)
      done ;

      let n_f = Float.of_int n in
      let numerator = (n_f *. !sum_xy) -. (!sum_x *. !sum_y) in
      let denominator =
        Float.sqrt
          (((n_f *. !sum_xx) -. (!sum_x *. !sum_x)) *. ((n_f *. !sum_yy) -. (!sum_y *. !sum_y)))
      in

      if Float.(abs denominator < 1e-10) then 0.0 else numerator /. denominator
end

(** Random number generation optimized for financial simulations *)
module FastRandom = struct
  (** Xorshift random number generator (very fast) *)
  type xorshift_state = {
    mutable x : int64;
    mutable y : int64;
    mutable z : int64;
    mutable w : int64;
  }

  let create_xorshift seed =
    { x = Int64.of_int seed; y = 362436069L; z = 521288629L; w = 88675123L }


  let xorshift_next state =
    let t = Int64.(state.x lxor (state.x lsl 11)) in
      state.x <- state.y ;
      state.y <- state.z ;
      state.z <- state.w ;
      state.w <- Int64.(state.w lxor (state.w lsr 19) lxor t lxor (t lsr 8)) ;
      state.w


  let uniform_float state =
    let r = xorshift_next state in
      Int64.to_float Int64.(r land 0x7fffffffffffffffL) /. Int64.to_float 0x7fffffffffffffffL


  (** Box-Muller transform for normal distribution *)
  type normal_state = {
    rng : xorshift_state;
    mutable has_spare : bool;
    mutable spare : float;
  }

  let create_normal_rng seed = { rng = create_xorshift seed; has_spare = false; spare = 0.0 }

  let normal_sample state =
    if state.has_spare then (
      state.has_spare <- false ;
      state.spare)
    else
      let u1 = uniform_float state.rng in
      let u2 = uniform_float state.rng in
      let mag = Float.sqrt (-2.0 *. Float.log u1) in
      let angle = 2.0 *. Float.pi *. u2 in
        state.spare <- mag *. Float.sin angle ;
        state.has_spare <- true ;
        mag *. Float.cos angle


  (** Monte Carlo sampling utilities *)
  let monte_carlo_estimate ~samples ~f ~rng =
    let sum = ref 0.0 in
      for _i = 1 to samples do
        sum := !sum +. f (uniform_float rng)
      done ;
      !sum /. Float.of_int samples
end
