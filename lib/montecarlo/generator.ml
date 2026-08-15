module Rng = Algostream_rng.Rng
module Resample = Algostream_stochastic.Resample
module Data_source = Algostream_backtest.Data_source
module Garch11 = Algostream_advanced_models.Garch11
module Ornstein_uhlenbeck = Algostream_advanced_models.Ornstein_uhlenbeck

type price_series = {
  symbol : string;
  s0 : float;
  start_ts_ns : int64;
  step_ns : int64;
  spread_bps : float;
  volume : float;
}

type t =
  | Historical of Data_source.record array
  | Iid_bootstrap of {
      returns : float array;
      series : price_series;
    }
  | Block_bootstrap of {
      returns : float array;
      block_len : int;
      series : price_series;
    }
  | Stationary_bootstrap of {
      returns : float array;
      mean_block_len : float;
      series : price_series;
    }
  | Record_bootstrap of {
      records : Data_source.record array;
      block_len : int;
    }
  | Gbm of {
      mu : float;
      sigma : float;
      dt : float;
      series : price_series;
    }
  | Garch_path of {
      model : Garch11.t;
      series : price_series;
    }
  | Ou_path of {
      params : Ornstein_uhlenbeck.params;
      dt : float;
      series : price_series;
    }
  | Jump_diffusion of {
      mu : float;
      sigma : float;
      lambda : float;
      jump_mu : float;
      jump_sigma : float;
      dt : float;
      series : price_series;
    }
  | Multivariate of {
      symbols : string array;
      s0 : float array;
      mu : float array;
      cov : float array array;
      dt : float;
      start_ts_ns : int64;
      step_ns : int64;
      spread_bps : float;
      volume : float;
    }
  | Regime_switching of {
      spec : Regime_sim.spec;
      series : price_series;
    }
  | Stressed of {
      base : t;
      scenario : Stress.scenario;
      at_fraction : float;
    }

let default_series ~symbol ~s0 =
  { symbol; s0; start_ts_ns = 0L; step_ns = 60_000_000_000L; spread_bps = 5.0; volume = 1.0 }


let records_of_prices series prices =
  Path.to_records ~symbol:series.symbol ~prices ~start_ts_ns:series.start_ts_ns
    ~step_ns:series.step_ns ~spread_bps:series.spread_bps ~volume:series.volume ()


let records_of_returns series returns =
  records_of_prices series (Path.prices_of_returns ~s0:series.s0 ~returns)


(* Rewriting timestamps onto a uniform grid is necessary because a block bootstrap splices
   discontiguous pieces of history: keeping the original stamps would produce a stream that jumps
   backwards, and Data_source drops out-of-order records. *)
let regrid_records records ~step_ns =
  Array.mapi
    (fun i r ->
      let ts = Int64.mul (Int64.of_int i) step_ns in
        match r with
        | Data_source.Tick t -> Data_source.Tick { t with ts_ns = ts }
        | Data_source.Trade_print t -> Data_source.Trade_print { t with ts_ns = ts }
        | Data_source.Book b ->
          Data_source.Book
            {
              b with
              Algostream_domain_market.Order_book.timestamp =
                Algostream_domain_common.Timestamp.of_ns ts;
            })
    records


let rec build g ~rng ~n_steps =
  match g with
  | Historical records -> Data_source.of_records records
  | Iid_bootstrap { returns; series } ->
    Data_source.of_records (records_of_returns series (Resample.iid rng ~data:returns ~n:n_steps))
  | Block_bootstrap { returns; block_len; series } ->
    Data_source.of_records
      (records_of_returns series (Resample.circular_block rng ~data:returns ~block_len ~n:n_steps))
  | Stationary_bootstrap { returns; mean_block_len; series } ->
    Data_source.of_records
      (records_of_returns series (Resample.stationary rng ~data:returns ~mean_block_len ~n:n_steps))
  | Record_bootstrap { records; block_len } ->
    let m = Array.length records in
      if m = 0 then Data_source.of_records [||]
      else
        let idx = Resample.joint_index rng ~n_source:m ~n:n_steps ~block_len in
        let step =
          if m < 2 then 1_000_000_000L
          else Int64.sub (Data_source.ts_ns records.(1)) (Data_source.ts_ns records.(0)) in
        let step = if Int64.compare step 0L <= 0 then 1_000_000_000L else step in
          Data_source.of_records
            (regrid_records (Array.map (fun i -> records.(i)) idx) ~step_ns:step)
  | Gbm { mu; sigma; dt; series } ->
    Data_source.of_records
      (records_of_prices series (Path.gbm ~rng ~s0:series.s0 ~mu ~sigma ~n:n_steps ~dt))
  | Garch_path { model; series } ->
    Data_source.of_records
      (records_of_prices series (Path.garch ~rng ~model ~s0:series.s0 ~n:n_steps))
  | Ou_path { params; dt; series } ->
    (* OU is a level process, not a return process — the simulated path IS the price. *)
    Data_source.of_records
      (records_of_prices series (Path.ou ~rng ~params ~r0:series.s0 ~n:n_steps ~dt))
  | Jump_diffusion { mu; sigma; lambda; jump_mu; jump_sigma; dt; series } ->
    Data_source.of_records
      (records_of_prices series
         (Path.merton_jump_diffusion ~rng ~s0:series.s0 ~mu ~sigma ~lambda ~jump_mu ~jump_sigma
            ~n:n_steps ~dt))
  | Multivariate { symbols; s0; mu; cov; dt; start_ts_ns; step_ns; spread_bps; volume } ->
    (match Path.multivariate_gbm ~rng ~s0 ~mu ~cov ~n:n_steps ~dt with
    | Error _ -> Data_source.of_records [||]
    | Ok paths ->
      let all =
        Array.to_list
          (Array.mapi
             (fun j prices ->
               Path.to_records ~symbol:symbols.(j) ~prices ~start_ts_ns ~step_ns ~spread_bps ~volume
                 ())
             paths) in
        (* of_records sorts stably, so the per-symbol streams interleave by timestamp with a stable
           tie-break on symbol order. *)
        Data_source.of_records (Array.concat all))
  | Regime_switching { spec; series } ->
    let _, rets = Regime_sim.simulate ~rng spec ~n:n_steps in
      Data_source.of_records (records_of_returns series rets)
  | Stressed { base; scenario; at_fraction } ->
    let inner = build base ~rng ~n_steps in
    let records = Data_source.to_array inner in
    let sc = Stress.at_fraction scenario ~records ~fraction:at_fraction in
      Data_source.of_records (Stress.apply sc ~records)


let rec to_string = function
  | Historical r -> Printf.sprintf "historical(%d records)" (Array.length r)
  | Iid_bootstrap _ -> "iid_bootstrap"
  | Block_bootstrap { block_len; _ } -> Printf.sprintf "block_bootstrap(b=%d)" block_len
  | Stationary_bootstrap { mean_block_len; _ } ->
    Printf.sprintf "stationary_bootstrap(mean_b=%.1f)" mean_block_len
  | Record_bootstrap { block_len; _ } -> Printf.sprintf "record_bootstrap(b=%d)" block_len
  | Gbm { mu; sigma; _ } -> Printf.sprintf "gbm(mu=%g,sigma=%g)" mu sigma
  | Garch_path _ -> "garch_path"
  | Ou_path _ -> "ou_path"
  | Jump_diffusion { lambda; _ } -> Printf.sprintf "jump_diffusion(lambda=%g)" lambda
  | Multivariate { symbols; _ } -> Printf.sprintf "multivariate(%d assets)" (Array.length symbols)
  | Regime_switching _ -> "regime_switching"
  | Stressed { base; scenario; _ } ->
    Printf.sprintf "stressed(%s, %s)" (to_string base) scenario.Stress.name
