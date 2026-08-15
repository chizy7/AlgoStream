module Order_book = Algostream_domain_market.Order_book
module Regime = Algostream_analytics.Regime
module Side = Algostream_strategy.Side
module Book_impact = Algostream_order_management.Book_impact

type market_ctx = {
  bid : float option;
  ask : float option;
  last : float;
  sigma : float option;
  adv : float option;
  regime : Regime.t option;
  book : Order_book.order_book option;
}

type model =
  | Book_walk
  | Fixed_bps of float
  | Spread_fraction of float
  | Volatility_scaled of {
      k : float;
      participation_floor : float;
    }
  | Regime_scaled of {
      base : model;
      multipliers : (Regime.t * float) list;
    }
  | Composite of model list

let default_regime_multipliers =
  [
    (Regime.Calm, 1.0);
    (Regime.Trending { direction = 1; strength = 0.0 }, 1.2);
    (Regime.Volatile, 1.8);
    (Regime.Crisis, 3.0);
  ]


type outcome = {
  executed_price : float;
  filled_quantity : float;
  unfilled_quantity : float;
  slippage_bps : float;
  levels_consumed : int;
  permanent_impact_bps : float;
}

let mid ctx =
  match (ctx.bid, ctx.ask) with
  | Some b, Some a when b > 0.0 && a > 0.0 -> (b +. a) /. 2.0
  | _ -> ctx.last


let half_spread ctx =
  match (ctx.bid, ctx.ask) with Some b, Some a when b > 0.0 && a > b -> (a -. b) /. 2.0 | _ -> 0.0


(* Regime equality ignores the payload on Trending: a multiplier table keyed on a specific
   direction/strength would never match a live detector's output. *)
let regime_key_equal (a : Regime.t) (b : Regime.t) =
  match (a, b) with
  | Regime.Calm, Regime.Calm
  | Regime.Volatile, Regime.Volatile
  | Regime.Crisis, Regime.Crisis
  | Regime.Trending _, Regime.Trending _ ->
    true
  | _ -> false


let regime_multiplier multipliers = function
  | None -> 1.0
  | Some r ->
    (match List.find_opt (fun (k, _) -> regime_key_equal k r) multipliers with
    | Some (_, m) -> m
    | None -> 1.0)


(* Adverse price move in bps, before any book walk. Each model returns a cost in bps of mid. *)
let rec cost_bps model ~quantity ~ctx =
  match model with
  | Fixed_bps b -> b
  | Spread_fraction f ->
    let m = mid ctx in
      if m <= 0.0 then 0.0 else f *. half_spread ctx /. m *. 10_000.0
  | Volatility_scaled { k; participation_floor } ->
    let sigma = match ctx.sigma with Some s when s > 0.0 -> s | _ -> 0.0 in
    let adv = match ctx.adv with Some a when a > 0.0 -> a | _ -> 0.0 in
      if sigma <= 0.0 || adv <= 0.0 then 0.0
      else
        let participation = Float.max participation_floor (Float.abs quantity /. adv) in
          k *. sigma *. sqrt participation *. 10_000.0
  | Regime_scaled { base; multipliers } ->
    cost_bps base ~quantity ~ctx *. regime_multiplier multipliers ctx.regime
  | Composite ms -> List.fold_left (fun acc m -> acc +. cost_bps m ~quantity ~ctx) 0.0 ms
  | Book_walk ->
    (* Handled in [apply]; if it reaches here it is nested inside a Composite/Regime_scaled without
       a book, so degrade to fully crossing the spread. *)
    cost_bps (Spread_fraction 1.0) ~quantity ~ctx


let permanent_impact_bps ~quantity ~ctx ~daily_vol =
  match ctx.adv with
  | Some adv when adv > 0.0 && daily_vol > 0.0 ->
    let pi = Book_impact.permanent_impact ~quantity ~daily_volume:adv ~daily_vol () in
      pi.Book_impact.impact_bps
  | _ -> 0.0


let rec uses_book = function
  | Book_walk -> true
  | Regime_scaled { base; _ } -> uses_book base
  | Composite ms -> List.exists uses_book ms
  | Fixed_bps _ | Spread_fraction _ | Volatility_scaled _ -> false


let apply model ~side ~quantity ~ctx ?(daily_vol = 0.0) () =
  let m = mid ctx in
  let q = Float.abs quantity in
  let perm = permanent_impact_bps ~quantity:q ~ctx ~daily_vol in
    match (uses_book model, ctx.book) with
    | true, Some book ->
      (* Real depth walk. This is the one path that can report unfilled quantity. *)
      let est =
        Book_impact.estimate_from_book
          ~side:(side : Side.t :> Algostream_domain_orders.Order.order_side)
          ~quantity:q ~book in
      (* Regime conditioning still applies on top of the walk: a book snapshot taken in a calm
         moment understates what the same order costs in a crisis. *)
      let mult =
        match model with
        | Regime_scaled { multipliers; _ } -> regime_multiplier multipliers ctx.regime
        | _ -> 1.0 in
      let extra_bps = est.Book_impact.slippage_bps *. (mult -. 1.0) in
      let px =
        if m <= 0.0 then est.Book_impact.avg_fill_price
        else est.Book_impact.avg_fill_price +. (Side.sign side *. m *. extra_bps /. 10_000.0) in
        {
          executed_price = px;
          filled_quantity = est.Book_impact.quantity_filled;
          unfilled_quantity = est.Book_impact.unfilled_quantity;
          slippage_bps = est.Book_impact.slippage_bps *. mult;
          levels_consumed = est.Book_impact.levels_consumed;
          permanent_impact_bps = perm;
        }
    | _ ->
      let bps = cost_bps model ~quantity:q ~ctx in
      (* Slippage is always adverse: a buy pays up, a sell receives less. *)
      let px = if m <= 0.0 then ctx.last else m *. (1.0 +. (Side.sign side *. bps /. 10_000.0)) in
        {
          executed_price = px;
          filled_quantity = q;
          unfilled_quantity = 0.0;
          slippage_bps = bps;
          levels_consumed = 0;
          permanent_impact_bps = perm;
        }


let rec model_to_string = function
  | Book_walk -> "book_walk"
  | Fixed_bps b -> Printf.sprintf "fixed_%gbps" b
  | Spread_fraction f -> Printf.sprintf "spread_%g" f
  | Volatility_scaled { k; participation_floor } ->
    Printf.sprintf "vol_scaled(k=%g,floor=%g)" k participation_floor
  | Regime_scaled { base; _ } -> Printf.sprintf "regime_scaled(%s)" (model_to_string base)
  | Composite ms -> Printf.sprintf "composite[%s]" (String.concat "+" (List.map model_to_string ms))
