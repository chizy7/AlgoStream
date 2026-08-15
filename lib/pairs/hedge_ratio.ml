module Rolling = Algostream_analytics.Rolling
module Filters = Algostream_analytics.Filters

type rolling_state = {
  cov : Rolling.Rolling_cov.t;
  var_x : Rolling.Rolling_var.t;
  mean_x : Rolling.Rolling_mean.t;
  mean_y : Rolling.Rolling_mean.t;
  beta_history : Rolling.Rolling_var.t;
}

type internal =
  | Static_st of {
      beta : float;
      intercept : float;
    }
  | Rolling_st of rolling_state
  | Kalman_st of {
      rolling : rolling_state;
      kalman : Filters.Kalman1d.t;
    }

type t = {
  st : internal;
  mutable beta : float;
  mutable intercept : float;
  mutable n_updates : int;
  mutable beta_frozen_ticks : int;
}

let create (config : Config.t) =
  let make_rolling () =
    {
      cov =
        Rolling.Rolling_cov.create ~window:config.beta_window
          ~recompute_every:config.recompute_every;
      var_x =
        Rolling.Rolling_var.create ~window:config.beta_window
          ~recompute_every:config.recompute_every;
      mean_x = Rolling.Rolling_mean.create ~window:config.beta_window;
      mean_y = Rolling.Rolling_mean.create ~window:config.beta_window;
      beta_history =
        Rolling.Rolling_var.create
          ~window:(max 8 (config.beta_window / 4))
          ~recompute_every:(max 4 (config.beta_window / 16));
    } in
    match config.beta_mode with
    | Config.Static b ->
      {
        st = Static_st { beta = b; intercept = 0.0 };
        beta = b;
        intercept = 0.0;
        n_updates = 0;
        beta_frozen_ticks = 0;
      }
    | Rolling_ols ->
      let r = make_rolling () in
        { st = Rolling_st r; beta = 1.0; intercept = 0.0; n_updates = 0; beta_frozen_ticks = 0 }
    | Kalman_smoothed ->
      let r = make_rolling () in
      let k =
        Filters.Kalman1d.create ~signal_to_noise_ratio:config.kalman_signal_to_noise
          ~warmup:config.kalman_warmup in
        {
          st = Kalman_st { rolling = r; kalman = k };
          beta = 1.0;
          intercept = 0.0;
          n_updates = 0;
          beta_frozen_ticks = 0;
        }


let step_rolling (r : rolling_state) ~x ~y t =
  let cov_v = Rolling.Rolling_cov.update r.cov x y in
  let var_v = Rolling.Rolling_var.update r.var_x x in
  let mx = Rolling.Rolling_mean.update r.mean_x x in
  let my = Rolling.Rolling_mean.update r.mean_y y in
    if var_v < 1e-12 then t.beta_frozen_ticks <- t.beta_frozen_ticks + 1
    else (
      t.beta <- cov_v /. var_v ;
      t.intercept <- my -. (t.beta *. mx)) ;
    ignore (Rolling.Rolling_var.update r.beta_history t.beta : float)


let update t ~x ~y =
  t.n_updates <- t.n_updates + 1 ;
  (match t.st with
  | Static_st _ -> ()
  | Rolling_st r -> step_rolling r ~x ~y t
  | Kalman_st { rolling; kalman } ->
    step_rolling rolling ~x ~y t ;
    let smoothed = Filters.Kalman1d.update kalman t.beta in
      t.beta <- smoothed) ;
  (t.beta, t.intercept)


let beta t = t.beta

let intercept t = t.intercept

let beta_stdev t =
  match t.st with
  | Static_st _ -> 0.0
  | Rolling_st r -> Rolling.Rolling_var.std_dev r.beta_history
  | Kalman_st { rolling; _ } -> Rolling.Rolling_var.std_dev rolling.beta_history


let n_updates t = t.n_updates

let beta_frozen_ticks t = t.beta_frozen_ticks

let ready t =
  match t.st with
  | Static_st _ -> true
  | Rolling_st r -> Rolling.Rolling_cov.n r.cov >= 8
  | Kalman_st { rolling; kalman } ->
    Rolling.Rolling_cov.n rolling.cov >= 8 && Filters.Kalman1d.ready kalman
