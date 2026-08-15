module Order = Algostream_domain_orders.Order

type fill = {
  ts_ns : int64;
  price : float;
  quantity : float;
  venue : string;
  commission : float;
}

type report = {
  decision_price : float;
  total_quantity : float;
  filled_quantity : float;
  fill_rate : float;
  avg_fill_price : float;
  total_commission : float;
  slippage_bps : float;
  vwap_diff_bps : float;
  implementation_shortfall_bps : float;
  time_to_full_fill_ns : int64 option;
  first_fill_latency_ns : int64;
}

let analyze ~(order : Order.order) ~decision_price ~decision_ts_ns ~fills ~market_vwap =
  let total_qty = order.quantity in
  let filled_qty = List.fold_left (fun acc f -> acc +. f.quantity) 0.0 fills in
  let fill_rate = if total_qty > 0.0 then filled_qty /. total_qty else 0.0 in
  let total_value = List.fold_left (fun acc f -> acc +. (f.quantity *. f.price)) 0.0 fills in
  let avg_fill = if filled_qty > 0.0 then total_value /. filled_qty else 0.0 in
  let total_comm = List.fold_left (fun acc f -> acc +. f.commission) 0.0 fills in
  let side_sign = match order.side with Order.Buy -> 1.0 | Order.Sell -> -1.0 in
  let slippage_bps =
    if decision_price > 0.0 && filled_qty > 0.0 then
      side_sign *. (avg_fill -. decision_price) /. decision_price *. 1e4
    else 0.0 in
  let vwap_diff_bps =
    if market_vwap > 0.0 && filled_qty > 0.0 then
      side_sign *. (avg_fill -. market_vwap) /. market_vwap *. 1e4
    else 0.0 in
  let comm_bps =
    if decision_price > 0.0 && filled_qty > 0.0 then
      total_comm /. (decision_price *. filled_qty) *. 1e4
    else 0.0 in
  let impl_shortfall_bps = Float.abs slippage_bps +. comm_bps in
  let first_fill_latency_ns =
    match fills with [] -> 0L | f :: _ -> Int64.sub f.ts_ns decision_ts_ns in
  let time_to_full_fill_ns =
    if fill_rate >= 1.0 -. 1e-9 then
      match List.rev fills with
      | [] -> None
      | last :: _ -> Some (Int64.sub last.ts_ns decision_ts_ns)
    else None in
    {
      decision_price;
      total_quantity = total_qty;
      filled_quantity = filled_qty;
      fill_rate;
      avg_fill_price = avg_fill;
      total_commission = total_comm;
      slippage_bps;
      vwap_diff_bps;
      implementation_shortfall_bps = impl_shortfall_bps;
      time_to_full_fill_ns;
      first_fill_latency_ns;
    }


let report_to_string r =
  Printf.sprintf
    "[TCA] fill_rate=%.2f%% avg=%.4f slip=%+.1fbps vwap_diff=%+.1fbps IS=%.1fbps t_first=%Ldns"
    (r.fill_rate *. 100.0) r.avg_fill_price r.slippage_bps r.vwap_diff_bps
    r.implementation_shortfall_bps r.first_fill_latency_ns
