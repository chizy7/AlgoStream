type trigger =
  | Drawdown_breach of {
      current : float;
      limit : float;
    }
  | Daily_loss_breach of {
      current : float;
      limit : float;
    }
  | Leverage_breach of {
      current : float;
      limit : float;
    }
  | Vol_spike of {
      current : float;
      baseline : float;
      ratio : float;
    }
  | Manual of string

type state =
  | Active
  | Tripped of {
      trigger : trigger;
      tripped_at_ns : int64;
    }
  | Recovering of { since_ns : int64 }

type config = {
  max_drawdown : float;
  max_daily_loss : float;
  max_leverage : float;
  vol_spike_ratio : float;
  cooldown_ns : int64;
}

type t = {
  config : config;
  mutable state : state;
}

let create ~config = { config; state = Active }

let state t = t.state

let is_tripped t = match t.state with Active -> false | Tripped _ | Recovering _ -> true

let first_trigger t ~drawdown ~daily_pnl ~leverage ~realized_vol ~baseline_vol =
  if drawdown > t.config.max_drawdown then
    Some (Drawdown_breach { current = drawdown; limit = t.config.max_drawdown })
  else
    let daily_loss = -.daily_pnl in
      if daily_loss > t.config.max_daily_loss then
        Some (Daily_loss_breach { current = daily_loss; limit = t.config.max_daily_loss })
      else if leverage > t.config.max_leverage then
        Some (Leverage_breach { current = leverage; limit = t.config.max_leverage })
      else
        let ratio = if baseline_vol > 1e-12 then realized_vol /. baseline_vol else 0.0 in
          if ratio > t.config.vol_spike_ratio then
            Some (Vol_spike { current = realized_vol; baseline = baseline_vol; ratio })
          else None


let evaluate t ~drawdown ~daily_pnl ~leverage ~realized_vol ~baseline_vol ~ts_ns =
  (match t.state with
  | Tripped { tripped_at_ns; _ } ->
    if Int64.compare (Int64.sub ts_ns tripped_at_ns) t.config.cooldown_ns >= 0 then
      t.state <- Recovering { since_ns = ts_ns }
  | _ -> ()) ;
  (match t.state with
  | Active ->
    (match first_trigger t ~drawdown ~daily_pnl ~leverage ~realized_vol ~baseline_vol with
    | Some trig -> t.state <- Tripped { trigger = trig; tripped_at_ns = ts_ns }
    | None -> ())
  | Tripped _ | Recovering _ -> ()) ;
  t.state


let trip_manual t ~reason ~ts_ns =
  t.state <- Tripped { trigger = Manual reason; tripped_at_ns = ts_ns }


let reset t ~ts_ns =
  let _ = ts_ns in
    t.state <- Active


let trigger_to_string = function
  | Drawdown_breach { current; limit } -> Printf.sprintf "Drawdown_breach(%g > %g)" current limit
  | Daily_loss_breach { current; limit } ->
    Printf.sprintf "Daily_loss_breach(%g > %g)" current limit
  | Leverage_breach { current; limit } -> Printf.sprintf "Leverage_breach(%g > %g)" current limit
  | Vol_spike { current; baseline; ratio } ->
    Printf.sprintf "Vol_spike(%g vs %g, ratio %g)" current baseline ratio
  | Manual r -> Printf.sprintf "Manual(%s)" r


let state_to_string = function
  | Active -> "active"
  | Tripped { trigger; tripped_at_ns } ->
    Printf.sprintf "tripped(%s, since %Ld)" (trigger_to_string trigger) tripped_at_ns
  | Recovering { since_ns } -> Printf.sprintf "recovering(since %Ld)" since_ns
