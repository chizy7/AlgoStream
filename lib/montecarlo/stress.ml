module Rng = Algostream_rng.Rng
module Data_source = Algostream_backtest.Data_source
module Order_book = Algostream_domain_market.Order_book
module Timestamp = Algostream_domain_common.Timestamp

type shock =
  | Price_pct of float
  | Drift_pct_per_day of float
  | Vol_multiplier of float
  | Spread_multiplier of float
  | Depth_multiplier of float
  | Halt of { duration_ns : int64 }

type decay =
  | Instant
  | Linear
  | Exponential of float

type scenario = {
  name : string;
  description : string;
  shocks : (string option * shock) list;
  onset_ns : int64;
  duration_ns : int64;
  decay : decay;
}

let day = 86_400_000_000_000L

let hour = 3_600_000_000_000L

(* Magnitudes are round numbers shaped after the episode, not measured from it. *)
let black_monday_1987 =
  {
    name = "black_monday_1987";
    description = "Single-session equity crash: -22% gap, volatility 4x, spreads 5x";
    shocks =
      [
        (None, Price_pct (-0.22));
        (None, Vol_multiplier 4.0);
        (None, Spread_multiplier 5.0);
        (None, Depth_multiplier 0.3);
      ];
    onset_ns = 0L;
    duration_ns = day;
    decay = Exponential 0.3;
  }


let ltcm_1998 =
  {
    name = "ltcm_1998";
    description = "Convergence-trade unwind: sustained spread widening over ~6 weeks";
    shocks =
      [
        (None, Drift_pct_per_day (-0.005));
        (None, Vol_multiplier 2.5);
        (None, Spread_multiplier 4.0);
        (None, Depth_multiplier 0.25);
      ];
    onset_ns = 0L;
    duration_ns = Int64.mul day 42L;
    decay = Linear;
  }


let lehman_2008 =
  {
    name = "lehman_2008";
    description = "Credit crisis: -35% over ~3 weeks, liquidity collapse";
    shocks =
      [
        (None, Drift_pct_per_day (-0.017));
        (None, Vol_multiplier 3.5);
        (None, Spread_multiplier 6.0);
        (None, Depth_multiplier 0.15);
      ];
    onset_ns = 0L;
    duration_ns = Int64.mul day 21L;
    decay = Linear;
  }


let flash_crash_2010 =
  {
    name = "flash_crash_2010";
    description = "Intraday liquidity vacuum: -9% and recovery within ~30 minutes";
    shocks =
      [
        (None, Price_pct (-0.09));
        (None, Vol_multiplier 8.0);
        (None, Spread_multiplier 20.0);
        (None, Depth_multiplier 0.02);
      ];
    onset_ns = 0L;
    duration_ns = Int64.mul 1_800_000_000_000L 1L;
    decay = Exponential 0.15;
  }


let covid_march_2020 =
  {
    name = "covid_march_2020";
    description = "Cross-asset repricing: -30% over ~4 weeks with repeated limit-down sessions";
    shocks =
      [
        (None, Drift_pct_per_day (-0.012));
        (None, Vol_multiplier 4.0);
        (None, Spread_multiplier 5.0);
        (None, Depth_multiplier 0.2);
      ];
    onset_ns = 0L;
    duration_ns = Int64.mul day 28L;
    decay = Linear;
  }


let luna_may_2022 =
  {
    name = "luna_may_2022";
    description = "Algorithmic-stablecoin death spiral: near-total loss over ~4 days";
    shocks =
      [
        (None, Drift_pct_per_day (-0.55));
        (None, Vol_multiplier 10.0);
        (None, Spread_multiplier 30.0);
        (None, Depth_multiplier 0.02);
      ];
    onset_ns = 0L;
    duration_ns = Int64.mul day 4L;
    decay = Instant;
  }


let ftx_nov_2022 =
  {
    name = "ftx_nov_2022";
    description = "Exchange failure: -25% with a multi-hour halt and depth collapse";
    shocks =
      [
        (None, Price_pct (-0.25));
        (None, Halt { duration_ns = Int64.mul hour 6L });
        (None, Vol_multiplier 5.0);
        (None, Depth_multiplier 0.05);
      ];
    onset_ns = 0L;
    duration_ns = Int64.mul day 3L;
    decay = Linear;
  }


let all_presets =
  [|
    black_monday_1987;
    ltcm_1998;
    lehman_2008;
    flash_crash_2010;
    covid_march_2020;
    luna_may_2022;
    ftx_nov_2022;
  |]


let find_preset name = Array.find_opt (fun s -> String.equal s.name name) all_presets

let at_fraction sc ~records ~fraction =
  let n = Array.length records in
    if n = 0 then sc
    else
      let lo = Data_source.ts_ns records.(0) in
      let hi = Data_source.ts_ns records.(n - 1) in
      let span = Int64.sub hi lo in
      let f = if fraction < 0.0 then 0.0 else if fraction > 1.0 then 1.0 else fraction in
      let onset = Int64.add lo (Int64.of_float (Int64.to_float span *. f)) in
        { sc with onset_ns = onset }


(* Shock intensity at time [ts]: 1.0 at onset, decaying to 0 by the end of the window. *)
let intensity sc ts =
  if Int64.compare ts sc.onset_ns < 0 then 0.0
  else
    let elapsed = Int64.to_float (Int64.sub ts sc.onset_ns) in
    let dur = Int64.to_float sc.duration_ns in
      if dur <= 0.0 || elapsed > dur then 0.0
      else
        match sc.decay with
        | Instant -> 1.0
        | Linear -> 1.0 -. (elapsed /. dur)
        | Exponential half_life_frac ->
          let hl = Float.max 1e-9 (half_life_frac *. dur) in
            exp (-.Float.log 2.0 *. elapsed /. hl)


let applies_to sc symbol =
  List.filter
    (fun (s, _) -> match s with None -> true | Some x -> String.equal x symbol)
    sc.shocks
  |> List.map snd


let apply sc ~records =
  let n = Array.length records in
    if n = 0 then records
    else
      let out = ref [] in
      (* Drift compounds over the window, so it is accumulated per symbol as we walk forward. *)
      let drift_acc : (string, float) Hashtbl.t = Hashtbl.create 8 in
      let prev_ts : (string, int64) Hashtbl.t = Hashtbl.create 8 in
      let gap_applied : (string, unit) Hashtbl.t = Hashtbl.create 8 in
        Array.iter
          (fun r ->
            let symbol = Data_source.symbol r in
            let ts = Data_source.ts_ns r in
            let shocks = applies_to sc symbol in
            let k = intensity sc ts in
            let halted =
              List.exists
                (function
                  | Halt { duration_ns } ->
                    Int64.compare ts sc.onset_ns >= 0
                    && Int64.compare ts (Int64.add sc.onset_ns duration_ns) < 0
                  | _ -> false)
                shocks in
              if halted then ()
              else
                (* Accumulate drift since the previous record for this symbol. *)
                let dt_days =
                  match Hashtbl.find_opt prev_ts symbol with
                  | Some p -> Int64.to_float (Int64.sub ts p) /. 86_400e9
                  | None -> 0.0 in
                  Hashtbl.replace prev_ts symbol ts ;
                  List.iter
                    (function
                      | Drift_pct_per_day d ->
                        let acc = try Hashtbl.find drift_acc symbol with Not_found -> 0.0 in
                          Hashtbl.replace drift_acc symbol (acc +. (d *. dt_days *. k))
                      | _ -> ())
                    shocks ;
                  let drift = try Hashtbl.find drift_acc symbol with Not_found -> 0.0 in
                  let gap =
                    if k <= 0.0 then 0.0
                    else
                      List.fold_left
                        (fun acc s ->
                          match s with
                          | Price_pct p ->
                            (* A gap is a one-time jump at onset, not a per-record multiplier. *)
                            if Hashtbl.mem gap_applied symbol then acc
                            else (
                              Hashtbl.replace gap_applied symbol () ;
                              acc +. p)
                          | _ -> acc)
                        0.0 shocks in
                  let price_mult = 1.0 +. drift +. gap in
                  let spread_mult =
                    List.fold_left
                      (fun acc s ->
                        match s with
                        | Spread_multiplier m -> acc *. (1.0 +. ((m -. 1.0) *. k))
                        | _ -> acc)
                      1.0 shocks in
                  let depth_mult =
                    List.fold_left
                      (fun acc s ->
                        match s with
                        | Depth_multiplier m -> acc *. (1.0 -. ((1.0 -. m) *. k))
                        | _ -> acc)
                      1.0 shocks in
                  let shocked =
                    match r with
                    | Data_source.Tick t ->
                      let price = t.price *. price_mult in
                      let widen v =
                        match v with
                        | Some x ->
                          let x' = x *. price_mult in
                          let dev = x' -. price in
                            Some (price +. (dev *. spread_mult))
                        | None -> None in
                        Data_source.Tick { t with price; bid = widen t.bid; ask = widen t.ask }
                    | Data_source.Trade_print t ->
                      Data_source.Trade_print { t with price = t.price *. price_mult }
                    | Data_source.Book b ->
                      let scale_level (l : Order_book.Price_level.t) =
                        Order_book.Price_level.
                          { l with price = l.price *. price_mult; size = l.size *. depth_mult }
                      in
                        Data_source.Book
                          (Order_book.create_order_book ~symbol:b.Order_book.symbol
                             ~timestamp:b.Order_book.timestamp ~sequence:b.Order_book.sequence
                             ~bids:(Array.map scale_level b.Order_book.bids)
                             ~asks:(Array.map scale_level b.Order_book.asks)) in
                    out := shocked :: !out)
          records ;
        Array.of_list (List.rev !out)


let conditional ~rng ~data ~worst_pct ~block_len ~n =
  let m = Array.length data in
    if m = 0 then [||]
    else
      let b = max 1 (min block_len m) in
      let n_windows = m - b + 1 in
      (* Score every window by its cumulative return; keep the worst tail and bootstrap from those
         blocks only. Empirical stress: the magnitudes are ones the instrument actually produced. *)
      let scores =
        Array.init n_windows (fun s ->
          let acc = ref 0.0 in
            for j = 0 to b - 1 do
              acc := !acc +. data.(s + j)
            done ;
            (!acc, s)) in
        Array.sort (fun (a, _) (c, _) -> compare a c) scores ;
        let pct = if worst_pct <= 0.0 then 0.05 else Float.min 1.0 worst_pct in
        let keep = max 1 (int_of_float (float_of_int n_windows *. pct)) in
        let out = Array.make n 0.0 in
        let filled = ref 0 in
          while !filled < n do
            let _, start = scores.(Rng.int_below rng keep) in
            let take = min b (n - !filled) in
              Array.blit data start out !filled take ;
              filled := !filled + take
          done ;
          out


let shock_to_string = function
  | Price_pct p -> Printf.sprintf "price %+.1f%%" (p *. 100.0)
  | Drift_pct_per_day d -> Printf.sprintf "drift %+.2f%%/day" (d *. 100.0)
  | Vol_multiplier m -> Printf.sprintf "vol x%.1f" m
  | Spread_multiplier m -> Printf.sprintf "spread x%.1f" m
  | Depth_multiplier m -> Printf.sprintf "depth x%.2f" m
  | Halt { duration_ns } -> Printf.sprintf "halt %.1fh" (Int64.to_float duration_ns /. 3.6e12)


let scenario_to_string sc =
  Printf.sprintf "%s: %s [%s] over %.1fd" sc.name sc.description
    (String.concat ", " (List.map (fun (_, s) -> shock_to_string s) sc.shocks))
    (Int64.to_float sc.duration_ns /. 86_400e9)
