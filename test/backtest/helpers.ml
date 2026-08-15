module BT = Algostream_backtest
module Strategy = Algostream_strategy.Strategy
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Side = Algostream_strategy.Side
module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book
module Timestamp = Algostream_domain_common.Timestamp
module Venue = Algostream_order_management.Venue

let sec = 1_000_000_000L

let ts_of i = Int64.mul (Int64.of_int i) sec

let tick ?(symbol = "TEST") ?(volume = 1.0) ?bid ?ask ~i ~price () =
  BT.Data_source.Tick { symbol; ts_ns = ts_of i; price; volume; bid; ask }


(* A tick with a symmetric two-sided quote around [price], [spread_bps] wide. *)
let quoted_tick ?(symbol = "TEST") ?(volume = 1.0) ?(spread_bps = 10.0) ~i ~price () =
  let half = price *. spread_bps /. 2.0 /. 10_000.0 in
    BT.Data_source.Tick
      {
        symbol;
        ts_ns = ts_of i;
        price;
        volume;
        bid = Some (price -. half);
        ask = Some (price +. half);
      }


let print_ ?(symbol = "TEST") ?aggressor ~i ~price ~size () =
  BT.Data_source.Trade_print { symbol; ts_ns = ts_of i; price; size; aggressor }


let level ~price ~size = Order_book.Price_level.{ price; size; orders = 1 }

let book ?(symbol = "TEST") ?(i = 0) ?(bids = [||]) ?(asks = [||]) () =
  BT.Data_source.Book
    (Order_book.create_order_book ~symbol
       ~timestamp:(Timestamp.of_ns (ts_of i))
       ~sequence:(Int64.of_int i) ~bids ~asks)


(* A flat venue with zero fees, so a test that is not about costs sees none. *)
let free_venue =
  Venue.create ~name:"test" ~asset_class:Algostream_domain_market.Asset.Crypto
    ~fee_tiers:[ { Venue.maker_bps = 0.0; taker_bps = 0.0; volume_threshold = 0.0 } ]
    ~base_latency_us:0.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:0.0


let fee_venue ~maker_bps ~taker_bps =
  Venue.create ~name:"test_fees" ~asset_class:Algostream_domain_market.Asset.Crypto
    ~fee_tiers:[ { Venue.maker_bps; taker_bps; volume_threshold = 0.0 } ]
    ~base_latency_us:0.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:0.0


(* Frictionless config: no fees, no latency, no impact. Anything a test observes on top of this is
   the thing the test is actually about. *)
let frictionless_config ?(venue = free_venue) ?(capital = 100_000.0) () =
  let c = BT.Engine.default_config ~venue ~initial_capital:capital in
    { c with BT.Engine.slippage = BT.Slippage.Fixed_bps 0.0; flatten_at_end = false }


(* ───── a scripted strategy, for driving the engine deterministically ───── *)

(* Emits a fixed action list on the Nth tick it sees, then nothing. Lets a test state exactly what
   the engine should do without depending on any real signal logic. *)
module Scripted = struct
  let name = "scripted"

  let version = "1.0"

  type params = { fire_on_tick : float }

  let default_params = { fire_on_tick = 1.0 }

  let param_bounds = [ ("fire_on_tick", 0.0, 1e9) ]

  let params_to_assoc p = [ ("fire_on_tick", p.fire_on_tick) ]

  let params_of_assoc assoc =
    match Strategy.require assoc "fire_on_tick" with
    | Ok v -> Ok { fire_on_tick = v }
    | Error e -> Error e


  (* The script is installed by the test through this ref before [create] is called. *)
  let script : (int -> Action.t list) ref = ref (fun _ -> [])

  type state = {
    params : params;
    symbols : string list;
    mutable n_ticks : int;
    mutable fills : Event.fill list;
  }

  let create ~params ~symbols = { params; symbols; n_ticks = 0; fills = [] }

  let subscriptions st = List.map (fun s -> Strategy.Symbol s) st.symbols

  let on_event st _ctx = function
    | Event.Tick _ ->
      st.n_ticks <- st.n_ticks + 1 ;
      !script st.n_ticks
    | Event.Fill f ->
      st.fills <- f :: st.fills ;
      []
    | _ -> []


  let on_stop _ _ = []

  let diagnostics st =
    [ ("ticks", float_of_int st.n_ticks); ("fills", float_of_int (List.length st.fills)) ]
end

let buy ?(symbol = "TEST") ?(order_type = Order.Market) ?(tif = Order.Good_till_cancel)
  ?(urgency = Action.Normal) ~qty ~id () =
  Action.submit ~symbol ~side:Side.Buy ~quantity:qty ~order_type ~time_in_force:tif ~urgency
    ~client_order_id:id ~strategy_id:"scripted" ()


let sell ?(symbol = "TEST") ?(order_type = Order.Market) ?(tif = Order.Good_till_cancel)
  ?(urgency = Action.Normal) ~qty ~id () =
  Action.submit ~symbol ~side:Side.Sell ~quantity:qty ~order_type ~time_in_force:tif ~urgency
    ~client_order_id:id ~strategy_id:"scripted" ()
