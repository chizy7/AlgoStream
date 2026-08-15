module Portfolio = Algostream_domain_portfolio.Portfolio
module Garch11 = Algostream_advanced_models.Garch11

type stats = {
  n_updates : int;
  n_breaches : int;
  n_circuit_trips : int;
}

type t = {
  limits : Risk_limits.t;
  drawdown : Drawdown.Tracker.t;
  circuit : Circuit_breaker.t;
  correlation_detectors : (string * string, Correlation_breakdown.Detector.t) Hashtbl.t;
  pub : Risk_snapshot.t Atomic.t;
  mutable n_updates : int;
  mutable n_breaches : int;
  mutable n_circuit_trips : int;
  mutable prev_circuit_tripped : bool;
  mutable last_realized_vol : float;
  mutable last_baseline_vol : float;
  mutable prev_portfolio_value : float;
}

let create ~limits ~circuit_config ?(initial_equity = 0.0) () =
  {
    limits;
    drawdown = Drawdown.Tracker.create ~initial_equity ();
    circuit = Circuit_breaker.create ~config:circuit_config;
    correlation_detectors = Hashtbl.create 16;
    pub = Atomic.make Risk_snapshot.empty;
    n_updates = 0;
    n_breaches = 0;
    n_circuit_trips = 0;
    prev_circuit_tripped = false;
    last_realized_vol = 0.0;
    last_baseline_vol = 0.0;
    prev_portfolio_value = initial_equity;
  }


let compute_realized_vol returns =
  let n = Array.length returns in
    if n < 2 then 0.0
    else
      let sum = ref 0.0 in
        Array.iter (fun x -> sum := !sum +. x) returns ;
        let mu = !sum /. float_of_int n in
        let sum2 = ref 0.0 in
          Array.iter (fun x -> sum2 := !sum2 +. ((x -. mu) ** 2.0)) returns ;
          sqrt (!sum2 /. float_of_int (n - 1))


let compute_baseline_vol returns =
  let n = Array.length returns in
    if n < 30 then compute_realized_vol returns
    else
      let baseline_n = max 30 (n / 2) in
      let slice = Array.sub returns 0 baseline_n in
        compute_realized_vol slice


let get_or_create_detector t pair =
  match Hashtbl.find_opt t.correlation_detectors pair with
  | Some d -> d
  | None ->
    (* Detector.create defaults breakdown_threshold to its own value; passing the configured one is
       what makes Risk_limits.correlation_breakdown_threshold mean anything. Without it the field
       was read by nothing and tuning it silently did nothing. *)
    let d =
      Correlation_breakdown.Detector.create
        ~breakdown_threshold:t.limits.correlation_breakdown_threshold () in
      Hashtbl.replace t.correlation_detectors pair d ;
      d


let aggregate_correlation_status statuses =
  let max_severity = ref 0 in
  let chosen = ref Correlation_breakdown.Stable in
  let severity = function
    | Correlation_breakdown.Stable -> 0
    | Weakening _ -> 1
    | Broken_down _ -> 2
    | Sign_flipped _ -> 3 in
    List.iter
      (fun s ->
        let sv = severity s in
          if sv > !max_severity then (
            max_severity := sv ;
            chosen := s))
      statuses ;
    !chosen


let update t ~portfolio ~returns ?(correlation_updates = []) ?garch ~ts_ns () =
  t.n_updates <- t.n_updates + 1 ;
  let portfolio_value = Portfolio.net_asset_value portfolio in
    Drawdown.Tracker.update t.drawdown ~equity:portfolio_value ~ts_ns ;
    let current_dd = Drawdown.Tracker.current_drawdown t.drawdown in
    let max_dd = Drawdown.Tracker.max_drawdown t.drawdown in
    let peak = Drawdown.Tracker.peak_equity t.drawdown in
    let tuw = Drawdown.Tracker.time_under_water_ns t.drawdown in
    let exposure = Exposure.compute ~portfolio () in
    let realized_vol = compute_realized_vol returns in
    let baseline_vol =
      if t.last_baseline_vol > 0.0 then t.last_baseline_vol else compute_baseline_vol returns in
      t.last_realized_vol <- realized_vol ;
      if t.last_baseline_vol <= 0.0 then t.last_baseline_vol <- baseline_vol ;
      let daily_pnl_pct =
        if t.prev_portfolio_value > 0.0 then
          (portfolio_value -. t.prev_portfolio_value) /. t.prev_portfolio_value
        else 0.0 in
      let var_result =
        match garch with
        | Some g ->
          Var.compute ~method_:(Var.Garch_forecast g) ~returns ~portfolio_value ~confidence:0.95
            ~horizon_days:1
        | None ->
          Var.compute ~method_:Var.Parametric_normal ~returns ~portfolio_value ~confidence:0.95
            ~horizon_days:1 in
      let cb_state =
        Circuit_breaker.evaluate t.circuit ~drawdown:current_dd ~daily_pnl:daily_pnl_pct
          ~leverage:exposure.leverage_ratio ~realized_vol ~baseline_vol ~ts_ns in
      let tripped_now = Circuit_breaker.is_tripped t.circuit in
        if tripped_now && not t.prev_circuit_tripped then t.n_circuit_trips <- t.n_circuit_trips + 1 ;
        t.prev_circuit_tripped <- tripped_now ;
        let correlation_status =
          let updated_statuses =
            List.map
              (fun (a, b, c) ->
                let pair = if String.compare a b <= 0 then (a, b) else (b, a) in
                let detector = get_or_create_detector t pair in
                  Correlation_breakdown.Detector.update detector ~correlation:c)
              correlation_updates in
            aggregate_correlation_status updated_statuses in
        let breaches = ref [] in
          if current_dd > t.limits.max_drawdown then
            breaches :=
              Risk_limits.Drawdown { current = current_dd; limit = t.limits.max_drawdown }
              :: !breaches ;
          if -.daily_pnl_pct > t.limits.max_daily_loss then
            breaches :=
              Risk_limits.Daily_loss { current = -.daily_pnl_pct; limit = t.limits.max_daily_loss }
              :: !breaches ;
          if exposure.leverage_ratio > t.limits.max_leverage then
            breaches :=
              Risk_limits.Leverage
                { current = exposure.leverage_ratio; limit = t.limits.max_leverage }
              :: !breaches ;
          if var_result.var_pct > t.limits.max_var_pct then
            breaches :=
              Risk_limits.Var { current = var_result.var_pct; limit = t.limits.max_var_pct }
              :: !breaches ;
          (if exposure.largest_position_pct > t.limits.max_position_concentration then
             match exposure.per_symbol with
             | first :: _ ->
               breaches :=
                 Risk_limits.Position_concentration
                   {
                     symbol = first.symbol;
                     current = exposure.largest_position_pct;
                     limit = t.limits.max_position_concentration;
                   }
                 :: !breaches
             | [] -> ()) ;
          let breaches_list = List.rev !breaches in
            t.n_breaches <- t.n_breaches + List.length breaches_list ;
            let snap : Risk_snapshot.t =
              {
                ts_ns;
                portfolio_value;
                var_pct = var_result.var_pct;
                var_dollars = var_result.var_dollars;
                expected_shortfall_pct = var_result.expected_shortfall_pct;
                expected_shortfall_dollars = var_result.expected_shortfall_dollars;
                current_drawdown = current_dd;
                max_drawdown = max_dd;
                peak_equity = peak;
                time_under_water_ns = tuw;
                gross_exposure = exposure.gross_exposure;
                net_exposure = exposure.net_exposure;
                leverage_ratio = exposure.leverage_ratio;
                largest_position_pct = exposure.largest_position_pct;
                n_positions = exposure.n_positions;
                correlation_status;
                circuit_breaker_state = cb_state;
                breaches = breaches_list;
                ready = Drawdown.Tracker.n_updates t.drawdown >= 2 && Array.length returns >= 2;
              } in
              Atomic.set t.pub snap ;
              t.prev_portfolio_value <- portfolio_value ;
              snap


let snapshot t = Atomic.get t.pub

let snapshot_atomic t = t.pub

let circuit_breaker_state t = Circuit_breaker.state t.circuit

let reset_circuit t ~ts_ns = Circuit_breaker.reset t.circuit ~ts_ns

let realized_vol t = t.last_realized_vol

let baseline_vol t = t.last_baseline_vol

let stats t =
  { n_updates = t.n_updates; n_breaches = t.n_breaches; n_circuit_trips = t.n_circuit_trips }
