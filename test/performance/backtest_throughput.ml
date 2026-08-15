(** Backtest engine throughput bench.

    Three configurations of the same synthetic tick stream, chosen to separate where the time goes:
    - frictionless (fixed 0 bps slippage, no fees, no latency) — the engine loop itself
    - spread-crossing with fees — adds the cost model
    - book-walk against a synthetic depth ladder — the expensive path, since Order_book has no
      incremental update and the book is rebuilt per step

    The gap between the first and last is the honest answer to "what does book-mode Monte Carlo
    cost", which the guide quotes rather than claiming a single headline number. *)

module BT = Algostream_backtest
module Strategy = Algostream_strategy.Strategy
module Action = Algostream_strategy.Action
module Event = Algostream_strategy.Event
module Side = Algostream_strategy.Side
module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book
module Venue = Algostream_order_management.Venue
module Timestamp = Algostream_domain_common.Timestamp
module Clock = Algostream_common_utils.Time_utils.Clock

let n_events = 200_000

(* Measured release-profile: ~840k ev/s frictionless, ~920k ev/s in book mode. *)
let frictionless_floor = 300_000.0

let book_floor = 300_000.0

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: backtest_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


(* A strategy that trades on a fixed cadence, so the fill engine is genuinely exercised rather than
   idling. *)
module Churn = struct
  let name = "churn"

  let version = "1.0"

  type params = { every : float }

  let default_params = { every = 500.0 }

  let param_bounds = [ ("every", 1.0, 1e6) ]

  let params_to_assoc p = [ ("every", p.every) ]

  let params_of_assoc a =
    match Strategy.require a "every" with Ok v -> Ok { every = v } | Error e -> Error e


  type state = {
    params : params;
    mutable n : int;
    mutable long : bool;
  }

  let create ~params ~symbols =
    ignore symbols ;
    { params; n = 0; long = false }


  let subscriptions _ = [ Strategy.Symbol "SYN" ]

  let on_event st _ctx = function
    | Event.Tick _ ->
      st.n <- st.n + 1 ;
      if st.n mod int_of_float st.params.every = 0 then (
        let side = if st.long then Side.Sell else Side.Buy in
          st.long <- not st.long ;
          [
            Action.submit ~symbol:"SYN" ~side ~quantity:1.0 ~order_type:Order.Market
              ~client_order_id:(Printf.sprintf "c%d" st.n) ~strategy_id:"churn" ();
          ])
      else []
    | _ -> []


  let on_stop _ _ = []

  let diagnostics st = [ ("ticks", float_of_int st.n) ]
end

let tick_records n =
  Array.init n (fun i ->
    let price = 100.0 +. (5.0 *. sin (float_of_int i /. 50.0)) in
      BT.Data_source.Tick
        {
          symbol = "SYN";
          ts_ns = Int64.mul (Int64.of_int i) 1_000_000_000L;
          price;
          volume = 10.0;
          bid = Some (price *. 0.9995);
          ask = Some (price *. 1.0005);
        })


let book_records n =
  let out =
    Array.make (2 * n)
      (BT.Data_source.Tick
         { symbol = "SYN"; ts_ns = 0L; price = 0.0; volume = 0.0; bid = None; ask = None }) in
    for i = 0 to n - 1 do
      let price = 100.0 +. (5.0 *. sin (float_of_int i /. 50.0)) in
      let ts = Int64.mul (Int64.of_int i) 1_000_000_000L in
      let level k sign =
        Order_book.Price_level.
          { price = price +. (sign *. float_of_int (k + 1) *. 0.01); size = 50.0; orders = 1 } in
      let bids = Array.init 5 (fun k -> level k (-1.0)) in
      let asks = Array.init 5 (fun k -> level k 1.0) in
        out.(2 * i) <-
          BT.Data_source.Book
            (Order_book.create_order_book ~symbol:"SYN" ~timestamp:(Timestamp.of_ns ts)
               ~sequence:(Int64.of_int i) ~bids ~asks) ;
        out.((2 * i) + 1) <-
          BT.Data_source.Trade_print
            { symbol = "SYN"; ts_ns = ts; price; size = 1.0; aggressor = None }
    done ;
    out


let free_venue =
  Venue.create ~name:"bench" ~asset_class:Algostream_domain_market.Asset.Crypto
    ~fee_tiers:[ { Venue.maker_bps = 0.0; taker_bps = 0.0; volume_threshold = 0.0 } ]
    ~base_latency_us:0.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:0.0


let run_bench ~records ~slippage ~fees =
  let data = BT.Data_source.of_records records in
  let venue = if fees then Venue.binance_spot else free_venue in
  let base = BT.Engine.default_config ~venue ~initial_capital:1_000_000.0 in
  let config =
    {
      base with
      BT.Engine.slippage;
      cost = BT.Cost_model.default_config venue;
      flatten_at_end = false;
    } in
  let n = Array.length records in
  let t0 = Clock.now_monotonic_ns () in
  let r = BT.Engine.run (module Churn) ~params:Churn.default_params ~config ~data in
  let t1 = Clock.now_monotonic_ns () in
  let elapsed = Int64.sub t1 t0 in
  let eps = float_of_int n /. (Int64.to_float elapsed /. 1e9) in
  let nspe = Int64.div elapsed (Int64.of_int n) in
    (nspe, eps, r.BT.Result.counters.BT.Result.n_fills)


let main () =
  let json_path = parse_args () in
  let ticks = tick_records n_events in
  let books = book_records (n_events / 4) in
  let f_ns, f_eps, f_fills =
    run_bench ~records:ticks ~slippage:(BT.Slippage.Fixed_bps 0.0) ~fees:false in
  let s_ns, s_eps, s_fills =
    run_bench ~records:ticks ~slippage:(BT.Slippage.Spread_fraction 1.0) ~fees:true in
  let b_ns, b_eps, b_fills = run_bench ~records:books ~slippage:BT.Slippage.Book_walk ~fees:true in
    Printf.printf "bt.frictionless: n=%d ns/ev=%Ld throughput=%.0f ev/s fills=%d\n" n_events f_ns
      f_eps f_fills ;
    Printf.printf "bt.spread_fees:  n=%d ns/ev=%Ld throughput=%.0f ev/s fills=%d\n" n_events s_ns
      s_eps s_fills ;
    Printf.printf "bt.book_walk:    n=%d ns/ev=%Ld throughput=%.0f ev/s fills=%d\n"
      (Array.length books) b_ns b_eps b_fills ;
    if f_eps < frictionless_floor then (
      Printf.eprintf "REGRESSION: frictionless %.0f ev/s is below the floor of %.0f\n" f_eps
        frictionless_floor ;
      exit 1) ;
    if b_eps < book_floor then (
      Printf.eprintf "REGRESSION: book walk %.0f ev/s is below the floor of %.0f\n" b_eps book_floor ;
      exit 1) ;
    match json_path with
    | None -> ()
    | Some path ->
      let oc = open_out path in
        Printf.fprintf oc "[\n" ;
        Printf.fprintf oc
          "  \
           {\"name\":\"bt.frictionless.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
           ev/s\"},\n"
          f_ns f_eps ;
        Printf.fprintf oc
          "  \
           {\"name\":\"bt.spread_fees.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
           ev/s\"},\n"
          s_ns s_eps ;
        Printf.fprintf oc
          "  \
           {\"name\":\"bt.book_walk.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
           ev/s\"}\n"
          b_ns b_eps ;
        Printf.fprintf oc "]\n" ;
        close_out oc ;
        Printf.printf "wrote %s\n" path


let () = main ()
