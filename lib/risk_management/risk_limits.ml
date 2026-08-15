open Base
module Portfolio = Algostream_domain_portfolio.Portfolio
module Position = Algostream_domain_portfolio.Position
module Order = Algostream_domain_orders.Order

type t = {
  max_drawdown : float;
  max_daily_loss : float;
  max_leverage : float;
  max_var_pct : float;
  max_position_concentration : float;
  max_gross_exposure : float;
  correlation_breakdown_threshold : float;
}

let default =
  {
    max_drawdown = 0.20;
    max_daily_loss = 0.05;
    max_leverage = 3.0;
    max_var_pct = 0.05;
    max_position_concentration = 0.25;
    max_gross_exposure = 5.0;
    correlation_breakdown_threshold = 0.3;
  }


type breach =
  | Drawdown of {
      current : float;
      limit : float;
    }
  | Daily_loss of {
      current : float;
      limit : float;
    }
  | Leverage of {
      current : float;
      limit : float;
    }
  | Var of {
      current : float;
      limit : float;
    }
  | Position_concentration of {
      symbol : string;
      current : float;
      limit : float;
    }
  | Gross_exposure of {
      current : float;
      limit : float;
    }

(* Does this order move the position towards flat?

   A gate that blocks risk-reducing orders is worse than no gate: once drawdown breaches the
   ceiling, the strategy cannot close the position that caused it, and the loss it was supposed to
   cap runs unbounded. That is not hypothetical — measured on a real capture, a binding ceiling
   rejected 10 of 12 orders and left max drawdown *higher* and total return *lower* than with no
   limits at all, because the flattening orders were refused along with the entries.

   "Reducing" is deliberately strict: the order must be opposite in sign to the current position and
   no larger than it. An order that crosses through flat and opens the other side is an entry
   wearing a reduction's clothes, and is gated normally. *)
let is_risk_reducing (portfolio : Portfolio.portfolio) (order : Order.order) =
  match Portfolio.get_position portfolio ~symbol:order.Order.symbol with
  | None -> false
  | Some pos ->
    let held = pos.Position.quantity in
    let signed =
      match order.Order.side with
      | Order.Buy -> order.Order.quantity
      | Order.Sell -> -.order.Order.quantity in
      Float.( <> ) held 0.0
      && Float.( < ) (held *. signed) 0.0
      && Float.( <= ) (Float.abs signed) (Float.abs held)


let pre_trade_check t ~(portfolio : Portfolio.portfolio) ~(proposed_order : Order.order)
  ?(proposed_price = 0.0) ?(current_drawdown = 0.0) ?(daily_pnl_pct = 0.0) () =
  if is_risk_reducing portfolio proposed_order then []
  else
    let breaches = ref [] in
    let nav = Portfolio.net_asset_value portfolio in
    let add b = breaches := b :: !breaches in
      (* Portfolio-level, path-dependent checks first: if equity has already fallen through the
         drawdown floor the order is refused whatever it would do to concentration. Both comparisons
         match Monitor.update so the gate and the risk snapshot never disagree. *)
      if Float.( > ) current_drawdown t.max_drawdown then
        add (Drawdown { current = current_drawdown; limit = t.max_drawdown }) ;
      if Float.( > ) (-.daily_pnl_pct) t.max_daily_loss then
        add (Daily_loss { current = -.daily_pnl_pct; limit = t.max_daily_loss }) ;
      (* Current leverage check *)
      let lev = Portfolio.leverage portfolio in
        if Float.( > ) lev t.max_leverage then
          add (Leverage { current = lev; limit = t.max_leverage }) ;
        (* Current gross exposure check *)
        let gross = Portfolio.gross_exposure portfolio in
        let gross_mult = if Float.( > ) nav 0.0 then gross /. nav else 0.0 in
          if Float.( > ) gross_mult t.max_gross_exposure then
            add (Gross_exposure { current = gross_mult; limit = t.max_gross_exposure }) ;
          (* Per-symbol concentration: check existing positions *)
          Map.Poly.iteri portfolio.positions ~f:(fun ~key:symbol ~data:position ->
            if not (Position.is_flat position) then
              let exposure = Position.exposure position in
              let pct = if Float.( > ) nav 0.0 then exposure /. nav else 0.0 in
                if Float.( > ) pct t.max_position_concentration then
                  add
                    (Position_concentration
                       { symbol; current = pct; limit = t.max_position_concentration })) ;
          (* Simulate the proposed order's effect on position concentration *)
          if Float.( > ) proposed_price 0.0 && Float.( > ) proposed_order.quantity 0.0 then (
            let order_value = proposed_order.quantity *. proposed_price in
            let existing_exposure =
              match Portfolio.get_position portfolio ~symbol:proposed_order.symbol with
              | Some pos -> Position.exposure pos
              | None -> 0.0 in
            let new_exposure = existing_exposure +. order_value in
            let new_pct = if Float.( > ) nav 0.0 then new_exposure /. nav else 0.0 in
              if Float.( > ) new_pct t.max_position_concentration then
                add
                  (Position_concentration
                     {
                       symbol = proposed_order.symbol;
                       current = new_pct;
                       limit = t.max_position_concentration;
                     }) ;
              (* Simulate post-trade gross exposure *)
              let new_gross = gross +. order_value in
              let new_gross_mult = if Float.( > ) nav 0.0 then new_gross /. nav else 0.0 in
                if Float.( > ) new_gross_mult t.max_gross_exposure then
                  add (Gross_exposure { current = new_gross_mult; limit = t.max_gross_exposure })) ;
          List.rev !breaches


let breach_to_string = function
  | Drawdown { current; limit } -> Printf.sprintf "Drawdown(%g > %g)" current limit
  | Daily_loss { current; limit } -> Printf.sprintf "Daily_loss(%g > %g)" current limit
  | Leverage { current; limit } -> Printf.sprintf "Leverage(%g > %g)" current limit
  | Var { current; limit } -> Printf.sprintf "Var(%g > %g)" current limit
  | Position_concentration { symbol; current; limit } ->
    Printf.sprintf "Position_concentration(%s: %g > %g)" symbol current limit
  | Gross_exposure { current; limit } -> Printf.sprintf "Gross_exposure(%g > %g)" current limit
