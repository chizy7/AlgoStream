(** Order management throughput bench.

    Three hot paths:
    - [Routing.route] decisions per second (~500k/s pure function).
    - [Book_impact.estimate_from_book] over a 32-level book (~1M/s).
    - [Position_sizing.Kelly.size_position] (~10M/s, O(1)). *)

module OM = Algostream_order_management
module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book
module Asset = Algostream_domain_market.Asset
module Clock = Algostream_common_utils.Time_utils.Clock

let n_routing = 200_000

let n_book_impact = 500_000

let n_kelly = 10_000_000

let routing_floor = 50_000.0

let book_impact_floor = 100_000.0

let kelly_floor = 1_000_000.0

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: order_management_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let make_venues n =
  Array.init n (fun i ->
    OM.Venue.create ~name:(Printf.sprintf "v%d" i) ~asset_class:Asset.Crypto
      ~fee_tiers:[ { maker_bps = 5.0; taker_bps = 8.0 +. float_of_int i; volume_threshold = 0.0 } ]
      ~base_latency_us:50_000.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:1.0)


let make_snaps venues =
  Array.mapi
    (fun i v ->
      OM.Routing.
        {
          venue = v;
          best_bid = 100.0 -. (0.01 *. float_of_int i);
          best_ask = 100.1 +. (0.01 *. float_of_int i);
          bid_depth = 500.0;
          ask_depth = 500.0;
          monthly_volume = 0.0;
        })
    venues


let make_book () =
  let bids =
    Array.init 32 (fun i ->
      Order_book.Price_level.{ price = 100.0 -. (0.05 *. float_of_int i); size = 100.0; orders = 1 })
  in
  let asks =
    Array.init 32 (fun i ->
      Order_book.Price_level.{ price = 100.1 +. (0.05 *. float_of_int i); size = 100.0; orders = 1 })
  in
    Order_book.create_order_book ~symbol:"BTCUSDT"
      ~timestamp:(Algostream_domain_common.Timestamp.now ())
      ~sequence:0L ~bids ~asks


let make_order () =
  Order.create_order ~id:"o" ~client_order_id:"c" ~symbol:"BTCUSDT" ~side:Order.Buy
    ~order_type:Order.Market ~quantity:1000.0 ~time_in_force:Order.Immediate_or_cancel ~exchange:""
    ()


let bench_routing () =
  let venues = make_venues 5 in
  let snaps_arr = make_snaps venues in
  let snaps_list = Array.to_list snaps_arr in
  let order = make_order () in
  let t0 = Clock.now_monotonic_ns () in
    for _ = 1 to n_routing do
      let _ = OM.Routing.route ~order ~venues:snaps_list ~strategy:OM.Routing.Smart_split () in
        ()
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed_ns = Int64.sub t1 t0 in
    let ev_s = float_of_int n_routing /. (Int64.to_float elapsed_ns /. 1e9) in
    let ns_per = Int64.div elapsed_ns (Int64.of_int n_routing) in
      (elapsed_ns, ns_per, ev_s)


let bench_book_impact () =
  let book = make_book () in
  let t0 = Clock.now_monotonic_ns () in
    for _ = 1 to n_book_impact do
      let _ = OM.Book_impact.estimate_from_book ~side:Order.Buy ~quantity:200.0 ~book in
        ()
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed_ns = Int64.sub t1 t0 in
    let ev_s = float_of_int n_book_impact /. (Int64.to_float elapsed_ns /. 1e9) in
    let ns_per = Int64.div elapsed_ns (Int64.of_int n_book_impact) in
      (elapsed_ns, ns_per, ev_s)


let bench_kelly () =
  let t0 = Clock.now_monotonic_ns () in
    for _ = 1 to n_kelly do
      let _ =
        OM.Position_sizing.Kelly.size_position ~capital:100_000.0 ~kelly_fraction:0.25 ~price:100.0
          () in
        ()
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed_ns = Int64.sub t1 t0 in
    let ev_s = float_of_int n_kelly /. (Int64.to_float elapsed_ns /. 1e9) in
    let ns_per = Int64.div elapsed_ns (Int64.of_int n_kelly) in
      (elapsed_ns, ns_per, ev_s)


let main () =
  let json_path = parse_args () in
  let r_elapsed, r_ns_per, r_eps = bench_routing () in
    Printf.printf "routing.route:       n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
      n_routing r_elapsed r_ns_per r_eps ;
    let b_elapsed, b_ns_per, b_eps = bench_book_impact () in
      Printf.printf "book_impact:         n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
        n_book_impact b_elapsed b_ns_per b_eps ;
      let k_elapsed, k_ns_per, k_eps = bench_kelly () in
        Printf.printf "kelly.size_position: n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
          n_kelly k_elapsed k_ns_per k_eps ;
        if r_eps < routing_floor then (
          Printf.eprintf "REGRESSION: routing %.0f < floor %.0f\n" r_eps routing_floor ;
          exit 1) ;
        if b_eps < book_impact_floor then (
          Printf.eprintf "REGRESSION: book_impact %.0f < floor %.0f\n" b_eps book_impact_floor ;
          exit 1) ;
        if k_eps < kelly_floor then (
          Printf.eprintf "REGRESSION: kelly %.0f < floor %.0f\n" k_eps kelly_floor ;
          exit 1) ;
        match json_path with
        | None -> ()
        | Some path ->
          let oc = open_out path in
            Printf.fprintf oc "[\n" ;
            Printf.fprintf oc
              "  \
               {\"name\":\"oms.routing.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
               ev/s\"},\n"
              r_ns_per r_eps ;
            Printf.fprintf oc
              "  \
               {\"name\":\"oms.book_impact.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
               ev/s\"},\n"
              b_ns_per b_eps ;
            Printf.fprintf oc
              "  \
               {\"name\":\"oms.kelly.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
               ev/s\"}\n"
              k_ns_per k_eps ;
            Printf.fprintf oc "]\n" ;
            close_out oc ;
            Printf.printf "wrote %s\n" path


let () = main ()
