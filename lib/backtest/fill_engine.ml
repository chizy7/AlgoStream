module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book
module Trade = Algostream_domain_trades.Trade
module Execution_quality = Algostream_order_management.Execution_quality
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Side = Algostream_strategy.Side
module Rng = Algostream_rng.Rng
module Timestamp = Algostream_domain_common.Timestamp

type maker_fill_model =
  | Queue_position
  | Touch_cross
  | Optimistic

type stop_trigger_ref =
  | Trigger_last
  | Trigger_mid
  | Trigger_touch

type config = {
  slippage : Slippage.model;
  latency : Latency.t;
  maker_fill : maker_fill_model;
  stop_trigger : stop_trigger_ref;
  allow_partial : bool;
}

let default_config =
  {
    slippage = Slippage.Book_walk;
    latency = Latency.zero;
    maker_fill = Queue_position;
    stop_trigger = Trigger_touch;
    allow_partial = true;
  }


type working = {
  mutable order : Order.order;
  intent : Action.intent;
  mutable remaining : float;
  mutable queue_ahead : float;
  mutable queue_seeded : bool;
  mutable displayed : float;  (** iceberg visible slice; equals [remaining] for other kinds *)
  effective_ts_ns : int64;  (** venue arrival, after outbound latency *)
  mutable cancel_at_ns : int64 option;
  mutable triggered : bool;
  mutable fills : Execution_quality.fill list;
  decision_price : float;
  decision_ts_ns : int64;
}

type stats = {
  n_admitted : int;
  n_fills : int;
  n_maker_fills : int;
  n_taker_fills : int;
  n_cancelled : int;
  n_expired : int;
  n_fok_killed : int;
  n_ioc_remainder_cancelled : int;
  n_stops_triggered : int;
  unfilled_quantity : float;
}

type t = {
  cfg : config;
  cost : Cost_model.t;
  rng : Rng.t;
  working : (string, working) Hashtbl.t;  (** keyed by client_order_id *)
  mutable order_seq : int;
  closed : (string, working) Hashtbl.t;
  mutable s_admitted : int;
  mutable s_fills : int;
  mutable s_maker : int;
  mutable s_taker : int;
  mutable s_cancelled : int;
  mutable s_expired : int;
  mutable s_fok : int;
  mutable s_ioc : int;
  mutable s_stops : int;
  mutable s_unfilled : float;
}

let create ~config ~cost ~rng =
  {
    cfg = config;
    cost;
    rng;
    working = Hashtbl.create 64;
    order_seq = 0;
    closed = Hashtbl.create 64;
    s_admitted = 0;
    s_fills = 0;
    s_maker = 0;
    s_taker = 0;
    s_cancelled = 0;
    s_expired = 0;
    s_fok = 0;
    s_ioc = 0;
    s_stops = 0;
    s_unfilled = 0.0;
  }


let admit t ~now_ns (intent : Action.intent) ~order_id ~decision_price =
  let ts = Timestamp.of_ns now_ns in
  let order =
    Order.create_order ~ts ~id:order_id ~client_order_id:intent.Action.client_order_id
      ~symbol:intent.Action.symbol ~side:intent.Action.side ~order_type:intent.Action.order_type
      ~quantity:intent.Action.quantity ~time_in_force:intent.Action.time_in_force
      ~exchange:"backtest" ~strategy_id:intent.Action.strategy_id () in
  let display =
    match intent.Action.order_type with
    | Order.Iceberg { display_size; _ } -> Float.min display_size intent.Action.quantity
    | _ -> intent.Action.quantity in
  let w =
    {
      order = Order.update_status ~ts order Order.Open;
      intent;
      remaining = intent.Action.quantity;
      queue_ahead = 0.0;
      queue_seeded = false;
      displayed = display;
      effective_ts_ns = Int64.add now_ns (Latency.outbound t.cfg.latency ~rng:t.rng);
      cancel_at_ns = None;
      triggered = false;
      fills = [];
      decision_price;
      decision_ts_ns = now_ns;
    } in
    Hashtbl.replace t.working intent.Action.client_order_id w ;
    t.s_admitted <- t.s_admitted + 1 ;
    w.order


let cancel t ~now_ns ~client_order_id =
  match Hashtbl.find_opt t.working client_order_id with
  | None -> ()
  | Some w ->
    (* Effective only after the cancel latency, so a cancel can lose a race with a fill. *)
    w.cancel_at_ns <- Some (Int64.add now_ns (Latency.cancel t.cfg.latency ~rng:t.rng))


let working_orders t =
  Hashtbl.fold (fun _ w acc -> w.order :: acc) t.working []
  |> List.sort (fun (a : Order.order) b -> String.compare a.Order.id b.Order.id)


let is_working t ~client_order_id = Hashtbl.mem t.working client_order_id

(* ───── price helpers ──────────────────────────────────────────────── *)

let ctx_mid (c : Slippage.market_ctx) =
  match (c.Slippage.bid, c.Slippage.ask) with
  | Some b, Some a when b > 0.0 && a > 0.0 -> (b +. a) /. 2.0
  | _ -> c.Slippage.last


let trigger_price t (c : Slippage.market_ctx) side =
  match t.cfg.stop_trigger with
  | Trigger_last -> c.Slippage.last
  | Trigger_mid -> ctx_mid c
  | Trigger_touch ->
    (* Conservative: a buy-stop triggers on the ask (what you would pay), a sell-stop on the bid. *)
    (match side with
    | Side.Buy -> (match c.Slippage.ask with Some a when a > 0.0 -> a | _ -> c.Slippage.last)
    | Side.Sell -> (match c.Slippage.bid with Some b when b > 0.0 -> b | _ -> c.Slippage.last))


(* Does a limit at [px] cross the current touch? *)
let is_marketable side px (c : Slippage.market_ctx) =
  match side with
  | Side.Buy -> (match c.Slippage.ask with Some a when a > 0.0 -> px >= a | _ -> false)
  | Side.Sell -> (match c.Slippage.bid with Some b when b > 0.0 -> px <= b | _ -> false)


let limit_price_of w =
  match w.order.Order.order_type with
  | Order.Limit p -> Some p
  | Order.Stop_limit { limit_price; _ } -> if w.triggered then Some limit_price else None
  | _ -> None


let stop_price_of w =
  match w.order.Order.order_type with
  | Order.Stop p -> Some p
  | Order.Stop_limit { stop_price; _ } -> Some stop_price
  | _ -> None


(* ───── fill construction ──────────────────────────────────────────── *)

let record_fill t w ~now_ns ~price ~quantity ~liquidity =
  let notional = price *. quantity in
  let commission = Cost_model.commission t.cost ~notional ~liquidity in
    Cost_model.observe_fill t.cost ~notional ;
    let ts = Timestamp.of_ns now_ns in
      w.order <- Order.add_fill ~ts w.order ~fill_quantity:quantity ~fill_price:price ;
      w.remaining <- w.remaining -. quantity ;
      w.fills <-
        w.fills
        @ [ { Execution_quality.ts_ns = now_ns; price; quantity; venue = "backtest"; commission } ] ;
      t.s_fills <- t.s_fills + 1 ;
      (match liquidity with
      | Trade.Maker -> t.s_maker <- t.s_maker + 1
      | _ -> t.s_taker <- t.s_taker + 1) ;
      {
        Event.ts_ns = now_ns;
        order_id = w.order.Order.id;
        client_order_id = w.intent.Action.client_order_id;
        symbol = w.intent.Action.symbol;
        side = w.intent.Action.side;
        quantity;
        price;
        commission;
        liquidity;
        venue = "backtest";
      }


let close_order t w = Hashtbl.replace t.closed w.intent.Action.client_order_id w

let retire t w =
  Hashtbl.remove t.working w.intent.Action.client_order_id ;
  close_order t w


(* ───── one matching pass ──────────────────────────────────────────── *)

let cross t w ~now_ns ~ctx ~qty =
  let out =
    Slippage.apply t.cfg.slippage ~side:w.intent.Action.side ~quantity:qty ~ctx
      ~daily_vol:(match ctx.Slippage.sigma with Some s -> s | None -> 0.0)
      () in
  let filled = Float.min out.Slippage.filled_quantity qty in
    if filled <= 0.0 then (None, out)
    else
      ( Some
          (record_fill t w ~now_ns ~price:out.Slippage.executed_price ~quantity:filled
             ~liquidity:Trade.Taker),
        out )


(* Seed the queue from resting depth at our price. Cumulative at-or-better over-counts strictly
   better prices, which is conservative: it delays our fill rather than hastening it. *)
let seed_queue t w (ctx : Slippage.market_ctx) px =
  if not w.queue_seeded then (
    w.queue_seeded <- true ;
    match (t.cfg.maker_fill, ctx.Slippage.book) with
    | Queue_position, Some book ->
      let side =
        match w.intent.Action.side with Side.Buy -> Order_book.Bid | Side.Sell -> Order_book.Ask
      in
        w.queue_ahead <- Order_book.depth_at_price book ~side ~price:px
    | _ -> w.queue_ahead <- 0.0)


let advance_queue t w ~now_ns ~ctx ~px ~print_price ~print_size =
  seed_queue t w ctx px ;
  let through =
    match w.intent.Action.side with Side.Buy -> print_price <= px | Side.Sell -> print_price >= px
  in
    if not through then None
    else
      match t.cfg.maker_fill with
      | Optimistic ->
        let q = Float.min w.remaining w.displayed in
          if q <= 0.0 then None
          else Some (record_fill t w ~now_ns ~price:px ~quantity:q ~liquidity:Trade.Maker)
      | Touch_cross ->
        let q = Float.min (Float.min w.remaining w.displayed) print_size in
          if q <= 0.0 then None
          else Some (record_fill t w ~now_ns ~price:px ~quantity:q ~liquidity:Trade.Maker)
      | Queue_position ->
        if w.queue_ahead > 0.0 then (
          (* Consumed by the queue ahead of us. *)
          w.queue_ahead <- w.queue_ahead -. print_size ;
          if w.queue_ahead < 0.0 then (
            let spill = -.w.queue_ahead in
              w.queue_ahead <- 0.0 ;
              let q = Float.min (Float.min w.remaining w.displayed) spill in
                if q <= 0.0 then None
                else Some (record_fill t w ~now_ns ~price:px ~quantity:q ~liquidity:Trade.Maker))
          else None)
        else
          let q = Float.min (Float.min w.remaining w.displayed) print_size in
            if q <= 0.0 then None
            else Some (record_fill t w ~now_ns ~price:px ~quantity:q ~liquidity:Trade.Maker)


(* An iceberg slice that fills goes to the back of the queue — the reason naive iceberg simulation
   flatters fill rates. *)
let refresh_iceberg w ctx =
  match w.order.Order.order_type with
  | Order.Iceberg { display_size; _ } when w.remaining > 0.0 ->
    w.displayed <- Float.min display_size w.remaining ;
    ignore ctx ;
    w.queue_seeded <- false
  | _ -> w.displayed <- w.remaining


let expired_at w ~now_ns =
  match w.order.Order.time_in_force with
  | Order.Good_till_date ts -> Int64.compare now_ns (Timestamp.to_ns ts) > 0
  | _ -> false


let on_market t ~now_ns record ~ctx =
  let fills = ref [] in
  let events = ref [] in
  let to_retire = ref [] in
  let ts = Timestamp.of_ns now_ns in
  let emit_update w reason =
    events := Event.Order_update { order = w.order; ts_ns = now_ns; reason } :: !events in
  let process _key w =
    (* 1. Latency gate — an order not yet at the venue cannot match. *)
    if Int64.compare now_ns w.effective_ts_ns < 0 then ()
    else if
      (* 2. Cancel that has taken effect. *)
      match w.cancel_at_ns with
      | Some c -> Int64.compare now_ns c >= 0
      | None -> false
    then (
      w.order <- Order.update_status ~ts w.order Order.Cancelled ;
      t.s_cancelled <- t.s_cancelled + 1 ;
      t.s_unfilled <- t.s_unfilled +. w.remaining ;
      emit_update w Event.Cancelled ;
      to_retire := w :: !to_retire)
    else if expired_at w ~now_ns then (
      w.order <- Order.update_status ~ts w.order Order.Expired ;
      t.s_expired <- t.s_expired + 1 ;
      t.s_unfilled <- t.s_unfilled +. w.remaining ;
      emit_update w Event.Expired ;
      to_retire := w :: !to_retire)
    else if String.equal w.intent.Action.symbol (Data_source.symbol record) then (
      (* 3. Stop trigger. *)
      (match stop_price_of w with
      | Some sp when not w.triggered ->
        let ref_px = trigger_price t ctx w.intent.Action.side in
        let fired =
          match w.intent.Action.side with Side.Buy -> ref_px >= sp | Side.Sell -> ref_px <= sp in
          if fired then (
            w.triggered <- true ;
            t.s_stops <- t.s_stops + 1)
      | _ -> ()) ;
      let armed =
        match w.order.Order.order_type with
        | Order.Stop _ | Order.Stop_limit _ -> w.triggered
        | _ -> true in
        if armed && w.remaining > 0.0 then
          let lim = limit_price_of w in
          let aggressive = w.intent.Action.urgency = Action.Aggressive in
          let marketable =
            match lim with
            | None -> true (* market, or a triggered stop *)
            | Some px -> aggressive || is_marketable w.intent.Action.side px ctx in
            if marketable then (
              (* Taker path. FOK must be all-or-nothing, so probe first. *)
              let want = w.remaining in
              let probe =
                Slippage.apply t.cfg.slippage ~side:w.intent.Action.side ~quantity:want ~ctx ()
              in
              let can_fill = probe.Slippage.filled_quantity in
              let fok =
                match w.order.Order.time_in_force with Order.Fill_or_kill -> true | _ -> false in
                if fok && can_fill < want -. 1e-12 then (
                  w.order <- Order.update_status ~ts w.order Order.Cancelled ;
                  t.s_fok <- t.s_fok + 1 ;
                  t.s_unfilled <- t.s_unfilled +. w.remaining ;
                  emit_update w Event.Cancelled ;
                  to_retire := w :: !to_retire)
                else if (not t.cfg.allow_partial) && can_fill < want -. 1e-12 then ()
                else
                  match cross t w ~now_ns ~ctx ~qty:want with
                  | None, _ -> ()
                  | Some f, _ ->
                    fills := f :: !fills ;
                    refresh_iceberg w ctx ;
                    if w.remaining <= 1e-12 then (
                      w.order <- Order.update_status ~ts w.order Order.Filled ;
                      emit_update w Event.Filled ;
                      to_retire := w :: !to_retire)
                    else (
                      (* IOC: whatever did not fill on this pass is cancelled. *)
                      match w.order.Order.time_in_force with
                      | Order.Immediate_or_cancel ->
                        w.order <- Order.update_status ~ts w.order Order.Cancelled ;
                        t.s_ioc <- t.s_ioc + 1 ;
                        t.s_unfilled <- t.s_unfilled +. w.remaining ;
                        emit_update w Event.Cancelled ;
                        to_retire := w :: !to_retire
                      | _ -> emit_update w Event.Partially_filled))
            else
              (* Resting maker path: only tape prints advance us. *)
              match (lim, record) with
              | Some px, Data_source.Trade_print { price; size; _ } ->
                (match advance_queue t w ~now_ns ~ctx ~px ~print_price:price ~print_size:size with
                | None -> ()
                | Some f ->
                  fills := f :: !fills ;
                  refresh_iceberg w ctx ;
                  if w.remaining <= 1e-12 then (
                    w.order <- Order.update_status ~ts w.order Order.Filled ;
                    emit_update w Event.Filled ;
                    to_retire := w :: !to_retire)
                  else emit_update w Event.Partially_filled)
              | _ -> ()) in
    Hashtbl.iter process t.working ;
    List.iter (retire t) !to_retire ;
    (List.rev !fills, List.rev !events)


let cancel_all t ~now_ns =
  let ts = Timestamp.of_ns now_ns in
  let evts = ref [] in
  let ws = Hashtbl.fold (fun _ w acc -> w :: acc) t.working [] in
    List.iter
      (fun w ->
        w.order <- Order.update_status ~ts w.order Order.Cancelled ;
        t.s_cancelled <- t.s_cancelled + 1 ;
        t.s_unfilled <- t.s_unfilled +. w.remaining ;
        evts :=
          Event.Order_update { order = w.order; ts_ns = now_ns; reason = Event.Cancelled } :: !evts ;
        retire t w)
      ws ;
    List.rev !evts


let tca t ~client_order_id ~market_vwap =
  match Hashtbl.find_opt t.closed client_order_id with
  | None -> None
  | Some w ->
    if w.fills = [] then None
    else
      Some
        (Execution_quality.analyze ~order:w.order ~decision_price:w.decision_price
           ~decision_ts_ns:w.decision_ts_ns ~fills:w.fills ~market_vwap)


let stats t =
  {
    n_admitted = t.s_admitted;
    n_fills = t.s_fills;
    n_maker_fills = t.s_maker;
    n_taker_fills = t.s_taker;
    n_cancelled = t.s_cancelled;
    n_expired = t.s_expired;
    n_fok_killed = t.s_fok;
    n_ioc_remainder_cancelled = t.s_ioc;
    n_stops_triggered = t.s_stops;
    unfilled_quantity = t.s_unfilled;
  }
