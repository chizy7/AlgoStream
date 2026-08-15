module Asset = Algostream_domain_market.Asset

type extra_verdict =
  | Tick_size_violation of {
      price : float;
      tick_size : float;
    }
  | Min_trade_size_violation of {
      size : float;
      min_size : float;
    }

(* tick_size is float; binary representation can prevent equality. We accept anything within half a
   tick of the grid. *)
let on_tick_grid ~price ~tick_size =
  if tick_size <= 0.0 then true
  else
    let q = price /. tick_size in
      abs_float (q -. Float.round q) < 1e-6


let check_tick (asset : Asset.asset) ~price ~size =
  if size > 0.0 && size < asset.min_trade_size then
    Some (Min_trade_size_violation { size; min_size = asset.min_trade_size })
  else if not (on_tick_grid ~price ~tick_size:asset.tick_size) then
    Some (Tick_size_violation { price; tick_size = asset.tick_size })
  else None
