module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book

type estimate = {
  avg_fill_price : float;
  worst_fill_price : float;
  slippage_bps : float;
  quantity_filled : float;
  levels_consumed : int;
  unfilled_quantity : float;
}

let estimate_from_book ~side ~quantity ~(book : Order_book.order_book) =
  let levels = match side with Order.Buy -> book.asks | Order.Sell -> book.bids in
  let mid = match Order_book.mid_price book with Some m -> m | None -> 0.0 in
  let n = Array.length levels in
  let remaining = ref quantity in
  let cum_qty = ref 0.0 in
  let cum_value = ref 0.0 in
  let worst = ref 0.0 in
  let consumed = ref 0 in
  let i = ref 0 in
    while !i < n && !remaining > 0.0 do
      let level = levels.(!i) in
      let take = Float.min !remaining level.Order_book.Price_level.size in
        cum_qty := !cum_qty +. take ;
        cum_value := !cum_value +. (take *. level.Order_book.Price_level.price) ;
        worst := level.Order_book.Price_level.price ;
        remaining := !remaining -. take ;
        incr consumed ;
        incr i
    done ;
    let avg = if !cum_qty > 0.0 then !cum_value /. !cum_qty else 0.0 in
    let slippage_bps =
      if mid > 0.0 && !cum_qty > 0.0 then
        let raw = (avg -. mid) /. mid *. 1e4 in
          match side with Order.Buy -> raw | Order.Sell -> -.raw
      else 0.0 in
      {
        avg_fill_price = avg;
        worst_fill_price = !worst;
        slippage_bps;
        quantity_filled = !cum_qty;
        levels_consumed = !consumed;
        unfilled_quantity = !remaining;
      }


type permanent_impact = {
  impact_bps : float;
  participation_rate : float;
}

let permanent_impact ~quantity ~daily_volume ~daily_vol ?(gamma = 0.5) () =
  let participation = if daily_volume > 0.0 then Float.min 1.0 (quantity /. daily_volume) else 1.0 in
  let impact_bps =
    if participation <= 0.0 then 0.0 else gamma *. daily_vol *. sqrt participation *. 1e4 in
    { impact_bps; participation_rate = participation }
