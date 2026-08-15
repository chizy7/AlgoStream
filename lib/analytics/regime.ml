type t =
  | Calm
  | Trending of {
      direction : int;
      strength : float;
    }
  | Volatile
  | Crisis

let to_string = function
  | Calm -> "calm"
  | Trending { direction; strength } ->
    Printf.sprintf "trending(%s, %.2f)"
      (if direction > 0 then "up" else if direction < 0 then "down" else "flat")
      strength
  | Volatile -> "volatile"
  | Crisis -> "crisis"


let equal a b =
  match (a, b) with
  | Calm, Calm | Volatile, Volatile | Crisis, Crisis -> true
  | Trending { direction = d1; _ }, Trending { direction = d2; _ } -> d1 = d2
  | _ -> false


let log_src = Logs.Src.create "algostream.analytics.regime"

module Log = (val Logs.src_log log_src : Logs.LOG)

(* ───── detector ──────────────────────────────────────────────────── *)

type detector = {
  config : Config.t;
  mutable current : t;
  mutable since_ns : int64; (* event-time of entry into current state *)
  mutable last_ts_ns : int64;
  mutable last_observation : t; (* what would-be regime is the data suggesting? *)
  mutable consecutive_obs : int; (* how many consecutive ticks see [last_observation] *)
  mutable consecutive_obs_start_ns : int64;
  mutable transitions : int;
}

let create config =
  {
    config;
    current = Calm;
    since_ns = 0L;
    last_ts_ns = 0L;
    last_observation = Calm;
    consecutive_obs = 0;
    consecutive_obs_start_ns = 0L;
    transitions = 0;
  }


let current t = t.current

let dwell_ns t = if Int64.equal t.since_ns 0L then 0L else Int64.sub t.last_ts_ns t.since_ns

let transitions t = t.transitions

(* Classify the current observation independent of state. *)
let classify_observation cfg ~ewma_vol ~vol_band_median ~drawdown_from_peak ~return_run_length
  ~return_run_sign =
  if drawdown_from_peak >= cfg.Config.regime_crisis_drawdown then Crisis
  else
    let high_vol =
      vol_band_median > 0.0 && ewma_vol /. vol_band_median > cfg.Config.regime_volatile_band in
      if high_vol then Volatile
      else if return_run_length >= cfg.Config.regime_calm_to_trending_min_ticks then
        Trending { direction = return_run_sign; strength = float_of_int return_run_length /. 100.0 }
      else Calm


(* Fetch the (dwell, min_ticks) pair for a particular transition. *)
let dwell_for_transition cfg ~from_ ~to_ =
  let to_crisis = match to_ with Crisis -> true | _ -> false in
  let from_crisis = match from_ with Crisis -> true | _ -> false in
    if to_crisis then (cfg.Config.regime_to_crisis_dwell_ns, cfg.Config.regime_to_crisis_min_ticks)
    else if from_crisis then
      (cfg.regime_crisis_to_other_dwell_ns, cfg.regime_crisis_to_other_min_ticks)
    else
      match (from_, to_) with
      | Calm, Trending _ ->
        (cfg.regime_calm_to_trending_dwell_ns, cfg.regime_calm_to_trending_min_ticks)
      | Calm, Volatile ->
        (cfg.regime_calm_to_volatile_dwell_ns, cfg.regime_calm_to_volatile_min_ticks)
      | Volatile, Calm ->
        (cfg.regime_volatile_to_calm_dwell_ns, cfg.regime_volatile_to_calm_min_ticks)
      | Trending _, Calm ->
        (cfg.regime_trending_to_calm_dwell_ns, cfg.regime_trending_to_calm_min_ticks)
      | _ -> (cfg.regime_calm_to_volatile_dwell_ns, cfg.regime_calm_to_volatile_min_ticks)


let update t ~ts_ns ~ewma_vol ~vol_band_median ~drawdown_from_peak ~return_run_length
  ~return_run_sign =
  t.last_ts_ns <- ts_ns ;
  if Int64.equal t.since_ns 0L then t.since_ns <- ts_ns ;
  let obs =
    classify_observation t.config ~ewma_vol ~vol_band_median ~drawdown_from_peak ~return_run_length
      ~return_run_sign in
    if equal obs t.current then (
      t.last_observation <- obs ;
      t.consecutive_obs <- 0)
    else if equal obs t.last_observation then t.consecutive_obs <- t.consecutive_obs + 1
    else (
      t.last_observation <- obs ;
      t.consecutive_obs <- 1 ;
      t.consecutive_obs_start_ns <- ts_ns) ;
    let dwell, min_ticks = dwell_for_transition t.config ~from_:t.current ~to_:obs in
    let observed_dwell = Int64.sub ts_ns t.consecutive_obs_start_ns in
      if
        (not (equal obs t.current))
        && t.consecutive_obs >= min_ticks
        && Int64.compare observed_dwell dwell >= 0
      then (
        let prev = t.current in
          t.current <- obs ;
          t.since_ns <- ts_ns ;
          t.transitions <- t.transitions + 1 ;
          Log.info (fun m ->
            m "regime transition %s -> %s after dwell=%Ldns ticks=%d" (to_string prev)
              (to_string obs) observed_dwell t.consecutive_obs)) ;
      t.current
