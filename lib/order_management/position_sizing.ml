module Kelly = struct
  let full ~mean ~variance = if variance <= 0.0 then 0.0 else mean /. variance

  let fractional ~mean ~variance ~fraction = fraction *. full ~mean ~variance

  let from_winrate ~win_prob ~win_loss_ratio =
    if win_loss_ratio <= 0.0 then 0.0
    else
      let p = win_prob in
      let q = 1.0 -. p in
        p -. (q /. win_loss_ratio)


  let size_position ~capital ~kelly_fraction ~price ?(cap_pct = 1.0) () =
    let f = if kelly_fraction <> kelly_fraction then 0.0 else max 0.0 kelly_fraction in
    let f = min cap_pct f in
      if price <= 0.0 then 0.0 else capital *. f /. price
end

module Volatility_scaling = struct
  let size ~capital ~target_vol ~asset_vol ~price =
    if asset_vol <= 0.0 || price <= 0.0 then 0.0
    else
      let raw = target_vol /. (price *. asset_vol) in
        if capital > 0.0 then Float.min raw (capital /. price) else raw


  let atr_size ~capital ~risk_pct ~atr ~price =
    if atr <= 0.0 then 0.0
    else
      let raw = capital *. risk_pct /. atr in
        if price > 0.0 then Float.min raw (capital /. price) else raw
end
