module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate
module Cholesky = Algostream_stochastic.Cholesky
module Garch11 = Algostream_advanced_models.Garch11
module Ornstein_uhlenbeck = Algostream_advanced_models.Ornstein_uhlenbeck
module Data_source = Algostream_backtest.Data_source
module Order_book = Algostream_domain_market.Order_book
module Timestamp = Algostream_domain_common.Timestamp

let gbm ~rng ~s0 ~mu ~sigma ~n ~dt =
  let out = Array.make n 0.0 in
  (* Exact GBM increment: the -sigma^2/2 term makes E[S_t] = S_0 e^{mu t} rather than drifting high,
     which the naive discretization gets wrong. *)
  let drift = (mu -. (0.5 *. sigma *. sigma)) *. dt in
  let vol = sigma *. sqrt dt in
  let s = ref s0 in
    for i = 0 to n - 1 do
      s := !s *. exp (drift +. (vol *. Variate.normal rng)) ;
      out.(i) <- !s
    done ;
    out


let ou ~rng ~params ~r0 ~n ~dt = Ornstein_uhlenbeck.simulate_with params ~rng ~n ~dt ~r0

let garch_returns ~rng ~model ~n =
  let out = Array.make n 0.0 in
  let m = ref model in
    for i = 0 to n - 1 do
      (* current_variance is the forecast for this step; draw the innovation against it, then feed
         the realized return back so the next variance responds to it. That feedback is the
         clustering. *)
      let sigma = sqrt (Garch11.current_variance !m) in
      let r = sigma *. Variate.normal rng in
        out.(i) <- r ;
        ignore (Garch11.update !m ~r)
    done ;
    out


let prices_of_returns ~s0 ~returns =
  let n = Array.length returns in
  let out = Array.make n 0.0 in
  let s = ref s0 in
    for i = 0 to n - 1 do
      s := !s *. (1.0 +. returns.(i)) ;
      out.(i) <- !s
    done ;
    out


let garch ~rng ~model ~s0 ~n = prices_of_returns ~s0 ~returns:(garch_returns ~rng ~model ~n)

let merton_jump_diffusion ~rng ~s0 ~mu ~sigma ~lambda ~jump_mu ~jump_sigma ~n ~dt =
  let out = Array.make n 0.0 in
  let drift = (mu -. (0.5 *. sigma *. sigma)) *. dt in
  let vol = sigma *. sqrt dt in
  let s = ref s0 in
    for i = 0 to n - 1 do
      let diffusion = drift +. (vol *. Variate.normal rng) in
      (* Number of jumps in this interval is Poisson(lambda*dt); each is lognormal. *)
      let n_jumps = Variate.poisson rng ~lambda:(lambda *. dt) in
      let jump = ref 0.0 in
        for _ = 1 to n_jumps do
          jump := !jump +. jump_mu +. (jump_sigma *. Variate.normal rng)
        done ;
        s := !s *. exp (diffusion +. !jump) ;
        out.(i) <- !s
    done ;
    out


let multivariate_gbm ~rng ~s0 ~mu ~cov ~n ~dt =
  let k = Array.length s0 in
    if Array.length mu <> k || Array.length cov <> k then Error (`Not_square (Array.length cov, k))
    else
      (* Factorize once, sample n times. The jittered variant tolerates a sample covariance that is
         indefinite by a rounding epsilon, which estimated matrices routinely are. *)
      match Cholesky.factor_jittered cov with
      | Error (`Not_square (a, b)) -> Error (`Not_square (a, b))
      | Error (`Not_positive_definite i) -> Error (`Not_positive_definite i)
      | Ok lower ->
        let paths = Array.init k (fun _ -> Array.make n 0.0) in
        let s = Array.copy s0 in
        let zero_mean = Array.make k 0.0 in
        let sqrt_dt = sqrt dt in
          for t = 0 to n - 1 do
            let shock = Variate.multivariate_normal rng ~mean:zero_mean ~chol_lower:lower in
              for j = 0 to k - 1 do
                let drift = (mu.(j) -. (0.5 *. cov.(j).(j))) *. dt in
                  s.(j) <- s.(j) *. exp (drift +. (shock.(j) *. sqrt_dt)) ;
                  paths.(j).(t) <- s.(j)
              done
          done ;
          Ok paths


let to_records ~symbol ~prices ~start_ts_ns ~step_ns ?(spread_bps = 5.0) ?(volume = 1.0) () =
  Array.mapi
    (fun i price ->
      let half = price *. spread_bps /. 2.0 /. 10_000.0 in
        Data_source.Tick
          {
            symbol;
            ts_ns = Int64.add start_ts_ns (Int64.mul (Int64.of_int i) step_ns);
            price;
            volume;
            bid = Some (price -. half);
            ask = Some (price +. half);
          })
    prices


let to_records_with_book ~symbol ~prices ~start_ts_ns ~step_ns ~levels ~level_size ~tick_size
  ?(volume = 1.0) () =
  let out = ref [] in
    Array.iteri
      (fun i price ->
        let ts = Int64.add start_ts_ns (Int64.mul (Int64.of_int i) step_ns) in
        (* Symmetric ladder around the mid. Rebuilt in full every step — Order_book has no
           incremental update, and this is the dominant cost of book-mode Monte Carlo. *)
        let bids =
          Array.init levels (fun l ->
            Order_book.Price_level.
              {
                price = price -. (float_of_int (l + 1) *. tick_size);
                size = level_size;
                orders = 1;
              }) in
        let asks =
          Array.init levels (fun l ->
            Order_book.Price_level.
              {
                price = price +. (float_of_int (l + 1) *. tick_size);
                size = level_size;
                orders = 1;
              }) in
        let book =
          Order_book.create_order_book ~symbol ~timestamp:(Timestamp.of_ns ts)
            ~sequence:(Int64.of_int i) ~bids ~asks in
          out :=
            Data_source.Trade_print { symbol; ts_ns = ts; price; size = volume; aggressor = None }
            :: Data_source.Book book :: !out)
      prices ;
    Array.of_list (List.rev !out)
