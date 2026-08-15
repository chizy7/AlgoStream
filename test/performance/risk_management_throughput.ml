(** Risk management throughput bench.

    Four hot paths:
    - [Var.compute Parametric_normal] over 252-day returns (~1M ev/s pure function).
    - [Var.compute Historical] over 252-day returns (~100k ev/s; sort + tail mean).
    - [Drawdown.Tracker.update] (~10M ev/s; O(1) per step).
    - [Monitor.update] end-to-end over a 10-position portfolio (~50k ev/s). *)

module RM = Algostream_risk_management
module Portfolio = Algostream_domain_portfolio.Portfolio
module Position = Algostream_domain_portfolio.Position
module Clock = Algostream_common_utils.Time_utils.Clock

let n_var_param = 1_000_000

let n_var_hist = 200_000

let n_drawdown = 10_000_000

let n_monitor = 100_000

let var_param_floor = 100_000.0

let var_hist_floor = 10_000.0

let drawdown_floor = 1_000_000.0

let monitor_floor = 10_000.0

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: risk_management_throughput [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let normal_sample rng =
  let u1 = Float.max 1e-12 (Random.State.float rng 1.0) in
  let u2 = Random.State.float rng 1.0 in
    Float.sqrt (-2.0 *. Float.log u1) *. Float.cos (2.0 *. Float.pi *. u2)


let make_returns ~n ~sd ~seed =
  let rng = Random.State.make [| seed |] in
    Array.init n (fun _ -> sd *. normal_sample rng)


let bench_var_parametric () =
  let returns = make_returns ~n:252 ~sd:0.02 ~seed:1 in
  let t0 = Clock.now_monotonic_ns () in
    for _ = 1 to n_var_param do
      let _ =
        RM.Var.compute ~method_:RM.Var.Parametric_normal ~returns ~portfolio_value:100_000.0
          ~confidence:0.95 ~horizon_days:1 in
        ()
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed = Int64.sub t1 t0 in
    let eps = float_of_int n_var_param /. (Int64.to_float elapsed /. 1e9) in
    let nspe = Int64.div elapsed (Int64.of_int n_var_param) in
      (elapsed, nspe, eps)


let bench_var_historical () =
  let returns = make_returns ~n:252 ~sd:0.02 ~seed:2 in
  let t0 = Clock.now_monotonic_ns () in
    for _ = 1 to n_var_hist do
      let _ =
        RM.Var.compute ~method_:RM.Var.Historical ~returns ~portfolio_value:100_000.0
          ~confidence:0.95 ~horizon_days:1 in
        ()
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed = Int64.sub t1 t0 in
    let eps = float_of_int n_var_hist /. (Int64.to_float elapsed /. 1e9) in
    let nspe = Int64.div elapsed (Int64.of_int n_var_hist) in
      (elapsed, nspe, eps)


let bench_drawdown () =
  let tracker = RM.Drawdown.Tracker.create () in
  let t0 = Clock.now_monotonic_ns () in
    for i = 1 to n_drawdown do
      RM.Drawdown.Tracker.update tracker
        ~equity:(100_000.0 +. (float_of_int i *. 0.1))
        ~ts_ns:(Int64.of_int i)
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed = Int64.sub t1 t0 in
    let eps = float_of_int n_drawdown /. (Int64.to_float elapsed /. 1e9) in
    let nspe = Int64.div elapsed (Int64.of_int n_drawdown) in
      (elapsed, nspe, eps)


let make_portfolio () =
  let open Base in
  let p = Portfolio.create_portfolio ~account_id:"bench" ~initial_capital:100_000.0 () in
  let positions =
    List.fold (List.range 0 10) ~init:Map.Poly.empty ~f:(fun acc i ->
      let symbol = Printf.sprintf "SYM%d" i in
      let pos = Position.create_position ~symbol () in
      let pos = Position.add_trade pos ~trade_quantity:100.0 ~trade_price:50.0 ~commission:0.0 in
      let pos = Position.update_last_price pos ~new_price:50.0 in
        Map.Poly.set acc ~key:symbol ~data:pos) in
    { p with positions }


let bench_monitor () =
  let returns = make_returns ~n:252 ~sd:0.02 ~seed:3 in
  let portfolio = make_portfolio () in
  let limits = RM.Risk_limits.default in
  let cb_config =
    {
      RM.Circuit_breaker.max_drawdown = 0.20;
      max_daily_loss = 0.05;
      max_leverage = 3.0;
      vol_spike_ratio = 5.0;
      cooldown_ns = 10_000_000_000L;
    } in
  let m = RM.Monitor.create ~limits ~circuit_config:cb_config ~initial_equity:100_000.0 () in
  let t0 = Clock.now_monotonic_ns () in
    for i = 1 to n_monitor do
      let _ = RM.Monitor.update m ~portfolio ~returns ~ts_ns:(Int64.of_int i) () in
        ()
    done ;
    let t1 = Clock.now_monotonic_ns () in
    let elapsed = Int64.sub t1 t0 in
    let eps = float_of_int n_monitor /. (Int64.to_float elapsed /. 1e9) in
    let nspe = Int64.div elapsed (Int64.of_int n_monitor) in
      (elapsed, nspe, eps)


let main () =
  let json_path = parse_args () in
  let vp_e, vp_n, vp_eps = bench_var_parametric () in
    Printf.printf "var.parametric:  n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n" n_var_param
      vp_e vp_n vp_eps ;
    let vh_e, vh_n, vh_eps = bench_var_historical () in
      Printf.printf "var.historical:  n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
        n_var_hist vh_e vh_n vh_eps ;
      let dd_e, dd_n, dd_eps = bench_drawdown () in
        Printf.printf "drawdown.update: n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
          n_drawdown dd_e dd_n dd_eps ;
        let mo_e, mo_n, mo_eps = bench_monitor () in
          Printf.printf "monitor.update:  n=%d elapsed=%Ldns ns/ev=%Ld throughput=%.0f ev/s\n"
            n_monitor mo_e mo_n mo_eps ;
          if vp_eps < var_param_floor then (
            Printf.eprintf "REGRESSION: var parametric %.0f < floor %.0f\n" vp_eps var_param_floor ;
            exit 1) ;
          if vh_eps < var_hist_floor then (
            Printf.eprintf "REGRESSION: var historical %.0f < floor %.0f\n" vh_eps var_hist_floor ;
            exit 1) ;
          if dd_eps < drawdown_floor then (
            Printf.eprintf "REGRESSION: drawdown %.0f < floor %.0f\n" dd_eps drawdown_floor ;
            exit 1) ;
          if mo_eps < monitor_floor then (
            Printf.eprintf "REGRESSION: monitor %.0f < floor %.0f\n" mo_eps monitor_floor ;
            exit 1) ;
          match json_path with
          | None -> ()
          | Some path ->
            let oc = open_out path in
              Printf.fprintf oc "[\n" ;
              Printf.fprintf oc
                "  \
                 {\"name\":\"risk.var_parametric.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
                 ev/s\"},\n"
                vp_n vp_eps ;
              Printf.fprintf oc
                "  \
                 {\"name\":\"risk.var_historical.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
                 ev/s\"},\n"
                vh_n vh_eps ;
              Printf.fprintf oc
                "  \
                 {\"name\":\"risk.drawdown.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
                 ev/s\"},\n"
                dd_n dd_eps ;
              Printf.fprintf oc
                "  \
                 {\"name\":\"risk.monitor.ns_per_event\",\"unit\":\"ns\",\"value\":%Ld,\"extra\":\"throughput=%.0f \
                 ev/s\"}\n"
                mo_n mo_eps ;
              Printf.fprintf oc "]\n" ;
              close_out oc ;
              Printf.printf "wrote %s\n" path


let () = main ()
