open Base
module Portfolio = Algostream_domain_portfolio.Portfolio
module Position = Algostream_domain_portfolio.Position

type per_symbol_entry = {
  symbol : string;
  market_value : float;
  pct_of_nav : float;
}

type t = {
  nav : float;
  gross_exposure : float;
  net_exposure : float;
  leverage_ratio : float;
  largest_position_pct : float;
  n_positions : int;
  per_symbol : per_symbol_entry list;
  per_asset_class : (string * float) list;
}

let compute ~(portfolio : Portfolio.portfolio) ?(asset_class_lookup = fun _ -> "unknown") () =
  let nav = Portfolio.net_asset_value portfolio in
  let gross = Portfolio.gross_exposure portfolio in
  let net = Portfolio.net_exposure portfolio in
  let leverage = if Float.( > ) nav 0.0 then gross /. nav else 0.0 in
  let n_positions = Portfolio.position_count portfolio in
  let per_symbol =
    Map.Poly.fold portfolio.positions ~init:[] ~f:(fun ~key:symbol ~data:position acc ->
      if Position.is_flat position then acc
      else
        let mv = Position.market_value position in
        let pct = if Float.( > ) nav 0.0 then mv /. nav else 0.0 in
          { symbol; market_value = mv; pct_of_nav = pct } :: acc) in
  let per_symbol_sorted =
    List.sort per_symbol ~compare:(fun a b ->
      Float.compare (Float.abs b.pct_of_nav) (Float.abs a.pct_of_nav)) in
  let largest_pct =
    match per_symbol_sorted with [] -> 0.0 | first :: _ -> Float.abs first.pct_of_nav in
  let per_asset_class_tbl = Hashtbl.Poly.create () in
    List.iter per_symbol_sorted ~f:(fun e ->
      let cls = asset_class_lookup e.symbol in
      let cur = Option.value (Hashtbl.Poly.find per_asset_class_tbl cls) ~default:0.0 in
        Hashtbl.Poly.set per_asset_class_tbl ~key:cls ~data:(cur +. Float.abs e.market_value)) ;
    let per_asset_class =
      Hashtbl.Poly.fold per_asset_class_tbl ~init:[] ~f:(fun ~key ~data acc -> (key, data) :: acc)
      |> List.sort ~compare:(fun (_, a) (_, b) -> Float.compare b a) in
      {
        nav;
        gross_exposure = gross;
        net_exposure = net;
        leverage_ratio = leverage;
        largest_position_pct = largest_pct;
        n_positions;
        per_symbol = per_symbol_sorted;
        per_asset_class;
      }
