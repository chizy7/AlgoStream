module Portfolio = Algostream_domain_portfolio.Portfolio
module Position = Algostream_domain_portfolio.Position
module Order = Algostream_domain_orders.Order
module Trade = Algostream_domain_trades.Trade
module Venue = Algostream_order_management.Venue
module Risk_limits = Algostream_risk_management.Risk_limits
module Drawdown = Algostream_risk_management.Drawdown
module Rng = Algostream_rng.Rng
module Timestamp = Algostream_domain_common.Timestamp
module Strategy = Algostream_strategy.Strategy
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Context = Algostream_strategy.Context
module Side = Algostream_strategy.Side
module Per_pair = Algostream_pairs.Per_pair
module Pair_id = Algostream_pairs.Pair_id
module Bar_builder = Algostream_time_series.Bar_builder

type config = {
  initial_capital : float;
  account_id : string;
  venue : Venue.t;
  slippage : Slippage.model;
  latency : Latency.t;
  cost : Cost_model.config;
  risk_limits : Risk_limits.t option;
  maker_fill : Fill_engine.maker_fill_model;
  stop_trigger : Fill_engine.stop_trigger_ref;
  equity_sample_interval_ns : int64;
  pairs_config : Algostream_pairs.Config.t;
  bar_interval_ns : int64 option;
  root_seed : int64;
  run_index : int;
  flatten_at_end : bool;
  max_events : int option;
}

let default_config ~venue ~initial_capital =
  {
    initial_capital;
    account_id = "BACKTEST";
    venue;
    slippage = Slippage.Book_walk;
    latency = Latency.zero;
    cost = Cost_model.default_config venue;
    risk_limits = None;
    maker_fill = Fill_engine.Queue_position;
    stop_trigger = Fill_engine.Trigger_touch;
    equity_sample_interval_ns = 0L;
    pairs_config = Algostream_pairs.Config.default;
    bar_interval_ns = None;
    root_seed = 0L;
    run_index = 0;
    flatten_at_end = true;
    max_events = None;
  }


(* Inbound messages are held until their delivery time. A sorted list is adequate here: the queue
   holds at most a few messages per event, and a heap would cost more in complexity than it
   saves. *)
type pending = {
  deliver_at_ns : int64;
  ev : Event.t;
}

type pair_driver = {
  pd_pair : Pair_id.t;
  pd_y : string;
  pd_x : string;
  pd_state : Per_pair.t;
  mutable pd_last_y : float;
  mutable pd_last_x : float;
  (* Per_pair only runs its cointegration retest on the BAR cadence — [on_tick] alone never sets
     [cointegrated], so a strategy screening on it would never trade. The engine therefore builds
     bars for both legs and calls [on_bar] when the two legs close on the same boundary, mirroring
     what Pairs.Processor.process_bar does. *)
  pd_bb_y : Bar_builder.t;
  pd_bb_x : Bar_builder.t;
  mutable pd_bar_y : Algostream_time_series.Bar.t option;
  mutable pd_bar_x : Algostream_time_series.Bar.t option;
}

let run (type p) (module S : Strategy.S with type params = p) ~params ~config ~data =
  (* Two disjoint substreams: data noise and execution noise. Changing the latency model must not
     perturb the price path — see the .mli. *)
  let rng_exec = Rng.substream ~root_seed:config.root_seed ~index:((2 * config.run_index) + 1) in
  let cost = Cost_model.create config.cost in
  let fill_cfg =
    {
      Fill_engine.slippage = config.slippage;
      latency = config.latency;
      maker_fill = config.maker_fill;
      stop_trigger = config.stop_trigger;
      allow_partial = true;
    } in
  let fills_engine = Fill_engine.create ~config:fill_cfg ~cost ~rng:rng_exec in
  let view = Market_view.create () in
  let portfolio =
    ref
      (Portfolio.create_portfolio ~account_id:config.account_id
         ~initial_capital:config.initial_capital ()) in
  let st = S.create ~params ~symbols:(Data_source.symbols data) in
  let dd = Drawdown.Tracker.create ~initial_equity:config.initial_capital () in
  let equity = ref [] in
  let blotter = ref [] in
  let inbound = ref [] in
  let pair_drivers : (string, pair_driver) Hashtbl.t = Hashtbl.create 8 in
  let bar_builders : (string, Bar_builder.t) Hashtbl.t = Hashtbl.create 8 in
  let timers : (string * int64) list ref = ref [] in
  let now = ref 0L in
  let seq = ref 0 in
  let order_seq = ref 0 in
  (* [None] until the first sample. A sentinel of Int64.min_int would overflow on the [now -
     last_sample] subtraction and silently suppress every sample after the first. *)
  let last_sample = ref None in
  let prev_financing_ts = ref 0L in
  (* Accounting day for the daily-loss limit, as a UTC day index. Bar and tick timestamps are
     already UTC nanoseconds, so integer division is the whole boundary rule — there is no session
     calendar here, and crypto venues do not have one either. [day_start_nav] is the equity the day
     opened at; a fresh run opens its first day at the starting capital. *)
  let day_of ts_ns = Int64.div ts_ns 86_400_000_000_000L in
  let day_index = ref Int64.min_int in
  let day_start_nav = ref config.initial_capital in
  let first_ts = ref 0L in
  let n_events = ref 0 in
  let n_actions = ref 0 in
  let n_submitted = ref 0 in
  let n_rejected = ref 0 in
  let realized_running = ref 0.0 in
  let stop_flag = ref false in
  (* Cointegration is retested on the bar cadence, so a pair subscription needs a bar interval even
     when the strategy asked for no explicit bar stream. One minute is the natural default for the
     crypto feeds this platform ingests. *)
  let pair_bar_interval =
    match config.bar_interval_ns with
    | Some b when Int64.compare b 0L > 0 -> b
    | _ -> 60_000_000_000L in
  (* ───── subscriptions ──────────────────────────────────────────── *)
  let register_subscriptions () =
    List.iter
      (function
        | Strategy.Pair { pair; y_symbol; x_symbol } ->
          let key = Pair_id.to_string pair in
            if not (Hashtbl.mem pair_drivers key) then
              Hashtbl.replace pair_drivers key
                {
                  pd_pair = pair;
                  pd_y = y_symbol;
                  pd_x = x_symbol;
                  pd_state = Per_pair.create ~pair ~config:config.pairs_config;
                  pd_last_y = 0.0;
                  pd_last_x = 0.0;
                  pd_bb_y = Bar_builder.create ~symbol:y_symbol ~interval_ns:pair_bar_interval;
                  pd_bb_x = Bar_builder.create ~symbol:x_symbol ~interval_ns:pair_bar_interval;
                  pd_bar_y = None;
                  pd_bar_x = None;
                }
        | Strategy.Bars { symbol; interval_ns } ->
          if not (Hashtbl.mem bar_builders symbol) then
            Hashtbl.replace bar_builders symbol (Bar_builder.create ~symbol ~interval_ns)
        | Strategy.Timer_every { interval_ns; tag } -> timers := (tag, interval_ns) :: !timers
        | Strategy.Symbol _ -> ())
      (S.subscriptions st) in
  (* ───── context construction ───────────────────────────────────── *)
  let position_of symbol =
    match Portfolio.get_position !portfolio ~symbol with
    | Some p -> p.Position.quantity
    | None -> 0.0 in
  let nav () = Portfolio.net_asset_value !portfolio in
  let make_ctx () =
    {
      Context.ts_ns = !now;
      seq = !seq;
      portfolio = !portfolio;
      nav = nav ();
      working_orders = Fill_engine.working_orders fills_engine;
      position = position_of;
      last_price = Market_view.last_price view;
      quote = Market_view.quote view;
      book = Market_view.book view;
      risk = None;
    } in
  (* ───── booking a fill ─────────────────────────────────────────── *)
  let book_fill (f : Event.fill) =
    let ts = Timestamp.of_ns f.Event.ts_ns in
    let signed = Side.signed f.Event.side ~qty:f.Event.quantity in
      portfolio :=
        Portfolio.add_trade ~ts !portfolio ~symbol:f.Event.symbol ~trade_quantity:signed
          ~trade_price:f.Event.price ~commission:f.Event.commission ~strategy_id:"backtest" () ;
      realized_running := Portfolio.total_realized_pnl !portfolio ;
      let decision_px =
        match Market_view.mid view f.Event.symbol with Some m -> m | None -> f.Event.price in
      let slippage_cost =
        Side.sign f.Event.side *. (f.Event.price -. decision_px) *. f.Event.quantity in
        blotter :=
          {
            Result.ts_ns = f.Event.ts_ns;
            order_id = f.Event.order_id;
            client_order_id = f.Event.client_order_id;
            symbol = f.Event.symbol;
            side = f.Event.side;
            quantity = f.Event.quantity;
            price = f.Event.price;
            notional = f.Event.price *. f.Event.quantity;
            commission = f.Event.commission;
            slippage_cost;
            liquidity = f.Event.liquidity;
            strategy_id = "backtest";
            tag = "";
            nav_after = nav ();
            realized_pnl_after = !realized_running;
          }
          :: !blotter in
  (* ───── action handling ────────────────────────────────────────── *)
  let handle_action (a : Action.t) =
    incr n_actions ;
    match a with
    | Action.Submit intent ->
      let px =
        match Market_view.mid view intent.Action.symbol with
        | Some m -> m
        | None ->
          (match Market_view.last_price view intent.Action.symbol with Some p -> p | None -> 0.0)
      in
        if px <= 0.0 then ()
        else (
          incr order_seq ;
          let order_id = Printf.sprintf "BT-%08d" !order_seq in
          let gate_ok =
            match config.risk_limits with
            | None -> true
            | Some limits ->
              let proposed =
                Order.create_order ~ts:(Timestamp.of_ns !now) ~id:order_id
                  ~client_order_id:intent.Action.client_order_id ~symbol:intent.Action.symbol
                  ~side:intent.Action.side ~order_type:intent.Action.order_type
                  ~quantity:intent.Action.quantity ~time_in_force:intent.Action.time_in_force
                  ~exchange:"backtest" () in
              (* Read straight from the tracker: track_drawdown feeds it on every event, so the peak
                 is current here without the gate having to compute it. See track_drawdown for why
                 this must not be tied to the equity-sampling cadence. *)
              let equity = nav () in
              let current_drawdown = Drawdown.Tracker.current_drawdown dd in
              let daily_pnl_pct =
                if !day_start_nav > 0.0 then (equity -. !day_start_nav) /. !day_start_nav else 0.0
              in
              let breaches =
                Risk_limits.pre_trade_check limits ~portfolio:!portfolio ~proposed_order:proposed
                  ~proposed_price:px ~current_drawdown ~daily_pnl_pct () in
                breaches = [] in
            if not gate_ok then (
              incr n_rejected ;
              let ord =
                Order.create_order ~ts:(Timestamp.of_ns !now) ~id:order_id
                  ~client_order_id:intent.Action.client_order_id ~symbol:intent.Action.symbol
                  ~side:intent.Action.side ~order_type:intent.Action.order_type
                  ~quantity:intent.Action.quantity ~time_in_force:intent.Action.time_in_force
                  ~exchange:"backtest" () in
                inbound :=
                  {
                    deliver_at_ns = Int64.add !now (Latency.inbound config.latency ~rng:rng_exec);
                    ev =
                      Event.Order_update
                        { order = ord; ts_ns = !now; reason = Event.Rejected "risk_limit" };
                  }
                  :: !inbound)
            else (
              incr n_submitted ;
              ignore
                (Fill_engine.admit fills_engine ~now_ns:!now intent ~order_id ~decision_price:px)))
    | Action.Cancel cid -> Fill_engine.cancel fills_engine ~now_ns:!now ~client_order_id:cid
    | Action.Replace { client_order_id; _ } ->
      (* Modelled as cancel-only: a venue-side amend that preserves queue priority is not something
         this simulator can honestly reproduce, so the strategy must re-submit. Documented rather
         than faked. *)
      Fill_engine.cancel fills_engine ~now_ns:!now ~client_order_id
    | Action.Set_timer { ts_ns; tag } ->
      inbound := { deliver_at_ns = ts_ns; ev = Event.Timer { ts_ns; tag } } :: !inbound
    | Action.Log _ -> () in
  let dispatch_to_strategy ev =
    let ctx = make_ctx () in
      List.iter handle_action (S.on_event st ctx ev) in
  (* ───── inbound release ────────────────────────────────────────── *)
  let release_inbound () =
    let ready, held = List.partition (fun p -> Int64.compare p.deliver_at_ns !now <= 0) !inbound in
      inbound := held ;
      (* Deterministic order: by delivery time, then by insertion (list order is reverse insertion,
         so reverse it first). *)
      let ready =
        List.stable_sort (fun a b -> Int64.compare a.deliver_at_ns b.deliver_at_ns) (List.rev ready)
      in
        List.iter (fun p -> dispatch_to_strategy p.ev) ready in
  (* ───── pair drivers ───────────────────────────────────────────── *)
  let feed_pairs symbol price =
    Hashtbl.iter
      (fun _ pd ->
        let touched =
          if String.equal symbol pd.pd_y then (
            pd.pd_last_y <- price ;
            true)
          else if String.equal symbol pd.pd_x then (
            pd.pd_last_x <- price ;
            true)
          else false in
          if touched && pd.pd_last_y > 0.0 && pd.pd_last_x > 0.0 then (
            Per_pair.on_tick pd.pd_state ~y_price:pd.pd_last_y ~x_price:pd.pd_last_x ~ts_ns:!now ;
            (* Advance both legs' bar builders; when a bar closes on each leg for the SAME boundary,
               hand the pair to Per_pair.on_bar so the cointegration retest can run. *)
            (let closed_y = Bar_builder.on_tick pd.pd_bb_y ~ts:!now ~price:pd.pd_last_y ~size:1.0 in
             let closed_x = Bar_builder.on_tick pd.pd_bb_x ~ts:!now ~price:pd.pd_last_x ~size:1.0 in
               (match closed_y with Some b -> pd.pd_bar_y <- Some b | None -> ()) ;
               (match closed_x with Some b -> pd.pd_bar_x <- Some b | None -> ()) ;
               match (pd.pd_bar_y, pd.pd_bar_x) with
               | Some by, Some bx
                 when Int64.equal by.Algostream_time_series.Bar.open_ts
                        bx.Algostream_time_series.Bar.open_ts ->
                 Per_pair.on_bar pd.pd_state ~y_bar:by ~x_bar:bx ;
                 pd.pd_bar_y <- None ;
                 pd.pd_bar_x <- None
               | _ -> ()) ;
            dispatch_to_strategy
              (Event.Pair_snapshot
                 {
                   snapshot = Per_pair.snapshot pd.pd_state;
                   y_symbol = pd.pd_y;
                   x_symbol = pd.pd_x;
                 })))
      pair_drivers in
  (* Feeds the running peak. Called on every event; cheap enough (one NAV evaluation plus a few
     comparisons) that tying it to a sampling cadence was never worth the correctness it cost. *)
  let track_drawdown () = Drawdown.Tracker.update dd ~equity:(nav ()) ~ts_ns:!now in
  (* ───── equity sampling ────────────────────────────────────────── *)
  (* Drawdown tracking is deliberately NOT done here — see track_drawdown below. This appends to the
     reported equity curve, which is a storage concern. *)
  let sample_equity () =
    let v = nav () in
      equity :=
        {
          Result.ts_ns = !now;
          nav = v;
          cash = !portfolio.Portfolio.cash_balance;
          gross_exposure = Portfolio.gross_exposure !portfolio;
          net_exposure = Portfolio.net_exposure !portfolio;
          leverage = Portfolio.leverage !portfolio;
          drawdown = Drawdown.Tracker.current_drawdown dd;
          n_positions = Portfolio.position_count !portfolio;
        }
        :: !equity ;
      last_sample := Some !now in
  (* ───── main step ──────────────────────────────────────────────── *)
  let step record =
    if not !stop_flag then (
      let ts = Data_source.ts_ns record in
        if Int64.equal !first_ts 0L then (
          first_ts := ts ;
          prev_financing_ts := ts) ;
        now := ts ;
        (* Roll the daily-loss baseline before anything can trade on this record. The first record
           establishes the opening day rather than counting as a rollover. *)
        let d = day_of ts in
          if not (Int64.equal d !day_index) then (
            if not (Int64.equal !day_index Int64.min_int) then
              day_start_nav := Portfolio.net_asset_value !portfolio ;
            day_index := d) ;
          incr seq ;
          incr n_events ;
          (match config.max_events with Some m when !n_events > m -> stop_flag := true | _ -> ()) ;
          if not !stop_flag then (
            (* 2. market view + derived state *)
            Market_view.observe view record ;
            let symbol = Data_source.symbol record in
              (* 3. inbound *)
              release_inbound () ;
              (* 5. matching *)
              (match Market_view.slippage_ctx view symbol with
              | None -> ()
              | Some ctx ->
                let fs, evs = Fill_engine.on_market fills_engine ~now_ns:!now record ~ctx in
                  List.iter
                    (fun (f : Event.fill) ->
                      book_fill f ;
                      (* Permanent impact moves the mark the rest of the run trades against. *)
                      let out =
                        Slippage.apply config.slippage ~side:f.Event.side ~quantity:f.Event.quantity
                          ~ctx () in
                        if Float.abs out.Slippage.permanent_impact_bps > 0.0 then
                          Market_view.apply_permanent_impact view f.Event.symbol
                            ~bps:(Side.sign f.Event.side *. out.Slippage.permanent_impact_bps) ;
                        inbound :=
                          {
                            deliver_at_ns =
                              Int64.add !now (Latency.inbound config.latency ~rng:rng_exec);
                            ev = Event.Fill f;
                          }
                          :: !inbound)
                    fs ;
                  List.iter
                    (fun e ->
                      inbound :=
                        {
                          deliver_at_ns =
                            Int64.add !now (Latency.inbound config.latency ~rng:rng_exec);
                          ev = e;
                        }
                        :: !inbound)
                    evs) ;
              (* 6. deliver the market event *)
              (match record with
              | Data_source.Tick { symbol; ts_ns; price; volume; bid; ask } ->
                dispatch_to_strategy (Event.Tick { symbol; ts_ns; price; volume; bid; ask }) ;
                (match Hashtbl.find_opt bar_builders symbol with
                | Some bb ->
                  (match Bar_builder.on_tick bb ~ts:ts_ns ~price ~size:volume with
                  | Some bar -> dispatch_to_strategy (Event.Bar bar)
                  | None -> ())
                | None -> ()) ;
                feed_pairs symbol price
              | Data_source.Trade_print { symbol; ts_ns; price; size; _ } ->
                dispatch_to_strategy
                  (Event.Tick { symbol; ts_ns; price; volume = size; bid = None; ask = None }) ;
                (match Hashtbl.find_opt bar_builders symbol with
                | Some bb ->
                  (match Bar_builder.on_tick bb ~ts:ts_ns ~price ~size with
                  | Some bar -> dispatch_to_strategy (Event.Bar bar)
                  | None -> ())
                | None -> ()) ;
                feed_pairs symbol price
              | Data_source.Book b -> dispatch_to_strategy (Event.Book b)) ;
              (* 8. mark, accrue, sample *)
              (match Market_view.last_price view symbol with
              | Some px ->
                let updates = Base.Map.Poly.singleton symbol px in
                  portfolio :=
                    Portfolio.update_position_prices ~ts:(Timestamp.of_ns !now) !portfolio
                      ~price_updates:updates
              | None -> ()) ;
              let fin =
                Cost_model.accrue_financing cost ~portfolio:!portfolio
                  ~prev_ts_ns:!prev_financing_ts ~now_ns:!now in
                prev_financing_ts := !now ;
                if fin > 0.0 then
                  portfolio :=
                    {
                      !portfolio with
                      Portfolio.cash_balance = !portfolio.Portfolio.cash_balance -. fin;
                    } ;
                (* Every event, regardless of equity_sample_interval_ns. That interval bounds how
                   much equity history is *stored*; it must not decide how accurately risk is
                   measured. When the two were the same call, a coarse interval left the running
                   peak stale, the gate saw a smaller drawdown than had really occurred, and it
                   admitted orders it should have refused — so a logging setting silently changed
                   trading decisions. *)
                track_drawdown () ;
                if
                  Int64.compare config.equity_sample_interval_ns 0L <= 0
                  ||
                  match !last_sample with
                  | None -> true
                  | Some t -> Int64.compare (Int64.sub !now t) config.equity_sample_interval_ns >= 0
                then sample_equity ())) in
    register_subscriptions () ;
    let _delivered = Data_source.iter data ~f:step in
    (* ───── shutdown ───────────────────────────────────────────────── *)
    let ctx = make_ctx () in
      List.iter handle_action (S.on_stop st ctx) ;
      (* One final matching pass so on_stop orders can execute against the last known market. *)
      List.iter
        (fun symbol ->
          match Market_view.slippage_ctx view symbol with
          | None -> ()
          | Some sctx ->
            let last = match Market_view.last_price view symbol with Some p -> p | None -> 0.0 in
            let rec drain n =
              if n <= 0 then ()
              else
                let fs, _ =
                  Fill_engine.on_market fills_engine ~now_ns:!now
                    (Data_source.Trade_print
                       {
                         symbol;
                         ts_ns = !now;
                         price = last;
                         size = Float.max_float;
                         aggressor = None;
                       })
                    ~ctx:sctx in
                  if fs = [] then ()
                  else (
                    List.iter book_fill fs ;
                    drain (n - 1)) in
              drain 8)
        (Market_view.symbols view) ;
      if config.flatten_at_end then
        (* Close remaining exposure at the last known price. Simulating this as market orders would
           re-enter the fill engine after the data has ended; marking out at last price is the
           honest equivalent and is what the flag documents. *)
        Base.Map.Poly.iteri !portfolio.Portfolio.positions ~f:(fun ~key:symbol ~data:pos ->
          let q = pos.Position.quantity in
            if Float.abs q > 1e-12 then
              match Market_view.last_price view symbol with
              | None -> ()
              | Some px ->
                portfolio :=
                  Portfolio.add_trade ~ts:(Timestamp.of_ns !now) !portfolio ~symbol
                    ~trade_quantity:(-.q) ~trade_price:px ~commission:0.0 ()) ;
      let cancel_evs = Fill_engine.cancel_all fills_engine ~now_ns:!now in
        ignore cancel_evs ;
        sample_equity () ;
        let fe = Fill_engine.stats fills_engine in
        let blotter_arr = Array.of_list (List.rev !blotter) in
        let tca =
          Array.to_list blotter_arr
          |> List.filter_map (fun (r : Result.blotter_row) ->
               match
                 Fill_engine.tca fills_engine ~client_order_id:r.Result.client_order_id
                   ~market_vwap:(Market_view.vwap view r.Result.symbol)
               with
               | Some rep -> Some (r.Result.client_order_id, rep)
               | None -> None)
          |> List.sort_uniq (fun (a, _) (b, _) -> String.compare a b)
          |> Array.of_list in
          {
            Result.strategy_name = S.name;
            params = S.params_to_assoc params;
            root_seed = config.root_seed;
            run_index = config.run_index;
            equity = Array.of_list (List.rev !equity);
            blotter = blotter_arr;
            tca;
            final_portfolio = !portfolio;
            counters =
              {
                Result.n_events = !n_events;
                n_out_of_order_dropped = Data_source.out_of_order_dropped data;
                n_actions = !n_actions;
                n_submitted = !n_submitted;
                n_rejected_by_risk = !n_rejected;
                n_fills = fe.Fill_engine.n_fills;
                n_maker_fills = fe.Fill_engine.n_maker_fills;
                n_taker_fills = fe.Fill_engine.n_taker_fills;
                n_cancelled = fe.Fill_engine.n_cancelled;
                n_expired = fe.Fill_engine.n_expired;
                n_fok_killed = fe.Fill_engine.n_fok_killed;
                n_ioc_remainder_cancelled = fe.Fill_engine.n_ioc_remainder_cancelled;
                n_stops_triggered = fe.Fill_engine.n_stops_triggered;
                unfilled_quantity = fe.Fill_engine.unfilled_quantity;
              };
            first_ts_ns = !first_ts;
            last_ts_ns = !now;
            total_commission = Cost_model.total_commission cost;
            total_financing = Cost_model.total_financing cost;
            strategy_diagnostics = S.diagnostics st;
          }
