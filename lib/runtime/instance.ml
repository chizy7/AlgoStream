module Data_source = Algostream_backtest.Data_source
module Market_view = Algostream_backtest.Market_view
module Fill_engine = Algostream_backtest.Fill_engine
module Cost_model = Algostream_backtest.Cost_model
module Slippage = Algostream_backtest.Slippage
module Latency = Algostream_backtest.Latency
module Strategy = Algostream_strategy.Strategy
module Context = Algostream_strategy.Context
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Side = Algostream_strategy.Side
module Order = Algostream_domain_orders.Order
module Portfolio = Algostream_domain_portfolio.Portfolio
module Position = Algostream_domain_portfolio.Position
module Timestamp = Algostream_domain_common.Timestamp
module Venue = Algostream_order_management.Venue
module Risk_limits = Algostream_risk_management.Risk_limits
module Drawdown = Algostream_risk_management.Drawdown
module Bar_builder = Algostream_time_series.Bar_builder
module Bar = Algostream_time_series.Bar
module Per_pair = Algostream_pairs.Per_pair
module Rng = Algostream_rng.Rng

type config = {
  strategy_id : string;
  symbols : string list;
  initial_capital : float;
  venue : Venue.t;
  slippage : Slippage.model;
  latency : Latency.t;
  cost : Cost_model.config;
  risk_limits : Risk_limits.t option;
  maker_fill : Fill_engine.maker_fill_model;
  stop_trigger : Fill_engine.stop_trigger_ref;
  bar_interval_ns : int64;
  pairs_config : Algostream_pairs.Config.t;
  seed : int64;
  max_recent_fills : int;
  nav_sample_interval_ns : int64;
}

let default_config ~strategy_id ~venue ~initial_capital =
  {
    strategy_id;
    symbols = [];
    initial_capital;
    venue;
    slippage = Slippage.Book_walk;
    (* Unlike the backtest's [Latency.zero], the live runtime models the venue's real round trip: an
       order submitted now is not matchable until the outbound delay has elapsed. *)
    latency = Latency.of_venue venue ();
    cost = Cost_model.default_config venue;
    risk_limits = Some Risk_limits.default;
    maker_fill = Fill_engine.Queue_position;
    stop_trigger = Fill_engine.Trigger_touch;
    bar_interval_ns = 60_000_000_000L;
    pairs_config = Algostream_pairs.Config.default;
    seed = 42L;
    max_recent_fills = 200;
    nav_sample_interval_ns = 1_000_000_000L;
  }


(* Per-pair bookkeeping, mirroring Backtest.Engine: Per_pair.on_tick runs on every tick but its
   cointegration retest only advances on the BAR cadence, so both legs need bar builders and the
   pair is only handed to on_bar when both close on the same boundary. *)
type pair_driver = {
  pd_y : string;
  pd_x : string;
  pd_state : Per_pair.t;
  pd_bb_y : Bar_builder.t;
  pd_bb_x : Bar_builder.t;
  mutable pd_last_y : float;
  mutable pd_last_x : float;
  mutable pd_bar_y : Bar.t option;
  mutable pd_bar_x : Bar.t option;
}

type t = {
  id : string;
  lifecycle : Snapshot.lifecycle Atomic.t;
  allocation : float Atomic.t;
  pub : Snapshot.instance Atomic.t;
  nav_pub : (int64 * float) array Atomic.t;
  feed : Data_source.record -> unit;
  finish : unit -> unit;
}

let id t = t.id

let lifecycle t = Atomic.get t.lifecycle

(* The published record is only rebuilt when a record is processed, but lifecycle and allocation are
   changed by control calls from another Domain. Overlaying them at read time makes a pause visible
   immediately instead of at the next tick — which matters most exactly when it is least likely to
   arrive, on a feed that has gone quiet. Both are atomics, so this stays race-free. *)
let snapshot t =
  let s = Atomic.get t.pub in
    { s with Snapshot.lifecycle = Atomic.get t.lifecycle; allocation = Atomic.get t.allocation }


let nav_curve t = Atomic.get t.nav_pub

let set_allocation t v = Atomic.set t.allocation v

let pause t =
  if Atomic.get t.lifecycle = Snapshot.Running then Atomic.set t.lifecycle Snapshot.Paused


let resume t =
  if Atomic.get t.lifecycle = Snapshot.Paused then Atomic.set t.lifecycle Snapshot.Running


let create (type p) (module S : Strategy.S with type params = p) ~(params : p) ~config =
  let st = S.create ~params ~symbols:config.symbols in
  let view = Market_view.create () in
  let cost = Cost_model.create config.cost in
  let rng = Rng.create ~seed:(Int64.to_int config.seed) in
  let fills =
    Fill_engine.create
      ~config:
        {
          Fill_engine.slippage = config.slippage;
          latency = config.latency;
          maker_fill = config.maker_fill;
          stop_trigger = config.stop_trigger;
          allow_partial = true;
        }
      ~cost ~rng in
  let portfolio =
    ref
      (Portfolio.create_portfolio ~account_id:config.strategy_id
         ~initial_capital:config.initial_capital ()) in
  let lifecycle = Atomic.make Snapshot.Running in
  let allocation = Atomic.make config.initial_capital in
  let pub =
    Atomic.make
      Snapshot.
        {
          (* filled by publish below *)
          strategy_id = config.strategy_id;
          strategy_name = S.name;
          strategy_version = S.version;
          lifecycle = Running;
          allocation = config.initial_capital;
          nav = config.initial_capital;
          cash = config.initial_capital;
          realized_pnl = 0.0;
          unrealized_pnl = 0.0;
          gross_exposure = 0.0;
          net_exposure = 0.0;
          leverage = 0.0;
          positions = [];
          working_orders = 0;
          n_events = 0;
          n_actions = 0;
          n_submitted = 0;
          n_rejected_by_risk = 0;
          n_fills = 0;
          recent_fills = [];
          diagnostics = [];
          params = S.params_to_assoc params;
          last_event_ts_ns = 0L;
          risk = None;
        } in
  let nav_pub = Atomic.make [||] in

  let now = ref 0L in
  let seq = ref 0 in
  let order_seq = ref 0 in
  let n_events = ref 0 and n_actions = ref 0 in
  let n_submitted = ref 0 and n_rejected = ref 0 and n_fills = ref 0 in
  let recent = ref [] in
  let nav_samples = ref [] in
  let nav_count = ref 0 in
  let last_nav_sample = ref None in
  let prev_financing_ts = ref 0L in
  (* Drives the drawdown and daily-loss limits. The live gate has to track this itself for the same
     reason the backtest engine does: a portfolio snapshot carries no history. Same UTC-day rule. *)
  let dd = Drawdown.Tracker.create ~initial_equity:config.initial_capital () in
  let day_of ts_ns = Int64.div ts_ns 86_400_000_000_000L in
  let day_index = ref Int64.min_int in
  let day_start_nav = ref config.initial_capital in
  let stopped = ref false in

  let bar_builders : (string, Bar_builder.t) Hashtbl.t = Hashtbl.create 8 in
  let pair_drivers : (string, pair_driver) Hashtbl.t = Hashtbl.create 4 in

  (* Read the strategy's subscriptions once, as Backtest.Engine does, and build the derived state it
     implies. Doing this lazily would mean the first events for a pair arrive before its state
     exists. *)
  List.iter
    (fun (sub : Strategy.subscription) ->
      match sub with
      | Strategy.Symbol _ -> ()
      | Strategy.Bars { symbol; interval_ns } ->
        if not (Hashtbl.mem bar_builders symbol) then
          Hashtbl.replace bar_builders symbol (Bar_builder.create ~symbol ~interval_ns)
      | Strategy.Timer_every _ -> ()
      | Strategy.Pair { pair; y_symbol; x_symbol } ->
        let key = Algostream_pairs.Pair_id.to_string pair in
          if not (Hashtbl.mem pair_drivers key) then
            Hashtbl.replace pair_drivers key
              {
                pd_y = y_symbol;
                pd_x = x_symbol;
                pd_state = Per_pair.create ~pair ~config:config.pairs_config;
                pd_bb_y = Bar_builder.create ~symbol:y_symbol ~interval_ns:config.bar_interval_ns;
                pd_bb_x = Bar_builder.create ~symbol:x_symbol ~interval_ns:config.bar_interval_ns;
                pd_last_y = 0.0;
                pd_last_x = 0.0;
                pd_bar_y = None;
                pd_bar_x = None;
              })
    (S.subscriptions st) ;

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
      working_orders = Fill_engine.working_orders fills;
      position = position_of;
      last_price = Market_view.last_price view;
      quote = Market_view.quote view;
      book = Market_view.book view;
      risk = None;
    } in

  let book_fill (f : Event.fill) =
    incr n_fills ;
    let ts = Timestamp.of_ns f.Event.ts_ns in
    let signed = Side.signed f.Event.side ~qty:f.Event.quantity in
      portfolio :=
        Portfolio.add_trade ~ts !portfolio ~symbol:f.Event.symbol ~trade_quantity:signed
          ~trade_price:f.Event.price ~commission:f.Event.commission ~strategy_id:config.strategy_id
          () ;
      let row =
        {
          Snapshot.ts_ns = f.Event.ts_ns;
          order_id = f.Event.order_id;
          client_order_id = f.Event.client_order_id;
          symbol = f.Event.symbol;
          side = f.Event.side;
          quantity = f.Event.quantity;
          price = f.Event.price;
          commission = f.Event.commission;
          liquidity = f.Event.liquidity;
          tag = "";
        } in
        (* Newest first, bounded — an unbounded blotter in a process meant to run for days is a slow
           leak. *)
        recent :=
          row
          ::
          (if List.length !recent >= config.max_recent_fills then
             List.filteri (fun i _ -> i < config.max_recent_fills - 1) !recent
           else !recent) in

  let rec dispatch_to_strategy ev =
    if Atomic.get lifecycle = Snapshot.Running then
      let ctx = make_ctx () in
        List.iter handle_action (S.on_event st ctx ev)
  and handle_action (a : Action.t) =
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
          let order_id = Printf.sprintf "%s-%08d" config.strategy_id !order_seq in
          let gate_ok =
            match config.risk_limits with
            | None -> true
            | Some limits ->
              let proposed =
                Order.create_order ~ts:(Timestamp.of_ns !now) ~id:order_id
                  ~client_order_id:intent.Action.client_order_id ~symbol:intent.Action.symbol
                  ~side:intent.Action.side ~order_type:intent.Action.order_type
                  ~quantity:intent.Action.quantity ~time_in_force:intent.Action.time_in_force
                  ~exchange:config.venue.Venue.name ~strategy_id:config.strategy_id () in
              let equity = nav () in
              (* The tracker is fed on every record, so this is already current. *)
              let current_drawdown = Drawdown.Tracker.current_drawdown dd in
              let daily_pnl_pct =
                if Float.compare !day_start_nav 0.0 > 0 then
                  (equity -. !day_start_nav) /. !day_start_nav
                else 0.0 in
              let breaches =
                Risk_limits.pre_trade_check limits ~portfolio:!portfolio ~proposed_order:proposed
                  ~proposed_price:px ~current_drawdown ~daily_pnl_pct () in
                breaches = [] in
            if not gate_ok then incr n_rejected
            else (
              incr n_submitted ;
              ignore
                (Fill_engine.admit fills ~now_ns:!now intent ~order_id ~decision_price:px
                  : Order.order)))
    | Action.Cancel coid -> Fill_engine.cancel fills ~now_ns:!now ~client_order_id:coid
    | Action.Replace { client_order_id; _ } ->
      (* The fill engine has no amend; a replace is a cancel and the strategy re-submits. Stated
         rather than silently ignored. *)
      Fill_engine.cancel fills ~now_ns:!now ~client_order_id
    | Action.Set_timer _ -> ()
    | Action.Log _ -> () in

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
            (let cy = Bar_builder.on_tick pd.pd_bb_y ~ts:!now ~price:pd.pd_last_y ~size:1.0 in
             let cx = Bar_builder.on_tick pd.pd_bb_x ~ts:!now ~price:pd.pd_last_x ~size:1.0 in
               (match cy with Some b -> pd.pd_bar_y <- Some b | None -> ()) ;
               (match cx with Some b -> pd.pd_bar_x <- Some b | None -> ()) ;
               match (pd.pd_bar_y, pd.pd_bar_x) with
               | Some by, Some bx when Int64.equal by.Bar.open_ts bx.Bar.open_ts ->
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

  let publish () =
    let p = !portfolio in
    let positions =
      Base.Map.Poly.fold p.Portfolio.positions ~init:[] ~f:(fun ~key ~data acc ->
        {
          Snapshot.symbol = key;
          quantity = data.Position.quantity;
          average_price = data.Position.average_price;
          market_value = data.Position.quantity *. data.Position.last_price;
          unrealized_pnl = data.Position.unrealized_pnl;
        }
        :: acc) in
      Atomic.set pub
        {
          Snapshot.strategy_id = config.strategy_id;
          strategy_name = S.name;
          strategy_version = S.version;
          lifecycle = Atomic.get lifecycle;
          allocation = Atomic.get allocation;
          nav = nav ();
          cash = p.Portfolio.cash_balance;
          realized_pnl = Portfolio.total_realized_pnl p;
          unrealized_pnl = Portfolio.total_unrealized_pnl p;
          gross_exposure = Portfolio.gross_exposure p;
          net_exposure = Portfolio.net_exposure p;
          leverage = Portfolio.leverage p;
          positions;
          working_orders = List.length (Fill_engine.working_orders fills);
          n_events = !n_events;
          n_actions = !n_actions;
          n_submitted = !n_submitted;
          n_rejected_by_risk = !n_rejected;
          n_fills = !n_fills;
          recent_fills = !recent;
          diagnostics = S.diagnostics st;
          params = S.params_to_assoc params;
          last_event_ts_ns = !now;
          risk = None;
        } in

  (* Feeds the running peak, on every record. nav_sample_interval_ns bounds how much history the
     charting ring *stores*; it must not decide how accurately the risk gate sees drawdown. Keeping
     these one call meant a slower dashboard cadence changed which orders were refused. *)
  let track_drawdown () = Drawdown.Tracker.update dd ~equity:(nav ()) ~ts_ns:!now in

  let sample_nav () =
    nav_samples := (!now, nav ()) :: !nav_samples ;
    incr nav_count ;
    (* Bounded ring, published oldest-first for charting. *)
    if !nav_count > 4096 then (
      nav_samples := List.filteri (fun i _ -> i < 2048) !nav_samples ;
      nav_count := 2048) ;
    Atomic.set nav_pub (Array.of_list (List.rev !nav_samples)) ;
    last_nav_sample := Some !now in

  let step (record : Data_source.record) =
    if not !stopped then (
      let ts = Data_source.ts_ns record in
        if Int64.equal !now 0L then prev_financing_ts := ts ;
        now := ts ;
        (let d = day_of ts in
           if not (Int64.equal d !day_index) then (
             if not (Int64.equal !day_index Int64.min_int) then
               day_start_nav := Portfolio.net_asset_value !portfolio ;
             day_index := d)) ;
        incr seq ;
        incr n_events ;
        Market_view.observe view record ;
        let symbol = Data_source.symbol record in
          (* Matching runs even while paused: resting orders are at the venue and keep filling. *)
          (match Market_view.slippage_ctx view symbol with
          | None -> ()
          | Some ctx ->
            let fs, evs = Fill_engine.on_market fills ~now_ns:!now record ~ctx in
              List.iter
                (fun (f : Event.fill) ->
                  book_fill f ;
                  let out =
                    Slippage.apply config.slippage ~side:f.Event.side ~quantity:f.Event.quantity
                      ~ctx () in
                    if Float.abs out.Slippage.permanent_impact_bps > 0.0 then
                      Market_view.apply_permanent_impact view f.Event.symbol
                        ~bps:(Side.sign f.Event.side *. out.Slippage.permanent_impact_bps) ;
                    dispatch_to_strategy (Event.Fill f))
                fs ;
              List.iter dispatch_to_strategy evs) ;
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
          (match Market_view.last_price view symbol with
          | Some px ->
            portfolio :=
              Portfolio.update_position_prices ~ts:(Timestamp.of_ns !now) !portfolio
                ~price_updates:(Base.Map.Poly.singleton symbol px)
          | None -> ()) ;
          let fin =
            Cost_model.accrue_financing cost ~portfolio:!portfolio ~prev_ts_ns:!prev_financing_ts
              ~now_ns:!now in
            prev_financing_ts := !now ;
            if fin > 0.0 then
              portfolio :=
                {
                  !portfolio with
                  Portfolio.cash_balance = !portfolio.Portfolio.cash_balance -. fin;
                } ;
            track_drawdown () ;
            (match !last_nav_sample with
            | None -> sample_nav ()
            | Some t when Int64.compare (Int64.sub !now t) config.nav_sample_interval_ns >= 0 ->
              sample_nav ()
            | Some _ -> ()) ;
            publish ()) in

  let finish () =
    if not !stopped then (
      stopped := true ;
      (if Atomic.get lifecycle <> Snapshot.Stopped then
         let ctx = make_ctx () in
           List.iter handle_action (S.on_stop st ctx)) ;
      ignore (Fill_engine.cancel_all fills ~now_ns:!now : Event.t list) ;
      Atomic.set lifecycle Snapshot.Stopped ;
      publish ()) in

  publish () ;
  { id = config.strategy_id; lifecycle; allocation; pub; nav_pub; feed = step; finish }


let on_record t r = t.feed r

let stop t = t.finish ()
