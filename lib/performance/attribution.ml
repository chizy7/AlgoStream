module Regime = Algostream_analytics.Regime

type fill = {
  ts_ns : int64;
  symbol : string;
  signed_quantity : float;
  price : float;
  commission : float;
  slippage_cost : float;
  financing_cost : float;
  is_maker : bool;
  strategy_id : string;
  realized_pnl_after : float;
}

type contribution = {
  key : string;
  realized_pnl : float;
  commission : float;
  slippage_cost : float;
  financing_cost : float;
  net_pnl : float;
  gross_notional : float;
  n_fills : int;
  pct_of_net : float;
}

type acc = {
  mutable a_realized : float;
  mutable a_commission : float;
  mutable a_slippage : float;
  mutable a_financing : float;
  mutable a_notional : float;
  mutable a_n : int;
}

let new_acc () =
  {
    a_realized = 0.0;
    a_commission = 0.0;
    a_slippage = 0.0;
    a_financing = 0.0;
    a_notional = 0.0;
    a_n = 0;
  }


(* Realized P&L is carried as a running total on each fill, so a group's realized contribution is
   the sum of per-fill deltas. Fills are assumed to arrive in blotter order; the first fill's delta
   is measured against zero. *)
let group_by fills ~key_of =
  let table : (string, acc) Hashtbl.t = Hashtbl.create 32 in
  let order = ref [] in
  let prev_realized = ref 0.0 in
    Array.iter
      (fun f ->
        let k = key_of f in
        let a =
          match Hashtbl.find_opt table k with
          | Some a -> a
          | None ->
            let a = new_acc () in
              Hashtbl.replace table k a ;
              order := k :: !order ;
              a in
        let delta = f.realized_pnl_after -. !prev_realized in
          prev_realized := f.realized_pnl_after ;
          a.a_realized <- a.a_realized +. delta ;
          a.a_commission <- a.a_commission +. f.commission ;
          a.a_slippage <- a.a_slippage +. f.slippage_cost ;
          a.a_financing <- a.a_financing +. f.financing_cost ;
          a.a_notional <- a.a_notional +. (Float.abs f.signed_quantity *. f.price) ;
          a.a_n <- a.a_n + 1)
      fills ;
    let total_net = ref 0.0 in
      Hashtbl.iter
        (fun _ a ->
          total_net :=
            !total_net +. (a.a_realized -. a.a_commission -. a.a_slippage -. a.a_financing))
        table ;
      let contributions =
        List.rev !order
        |> List.map (fun k ->
             let a = Hashtbl.find table k in
             let net = a.a_realized -. a.a_commission -. a.a_slippage -. a.a_financing in
               {
                 key = k;
                 realized_pnl = a.a_realized;
                 commission = a.a_commission;
                 slippage_cost = a.a_slippage;
                 financing_cost = a.a_financing;
                 net_pnl = net;
                 gross_notional = a.a_notional;
                 n_fills = a.a_n;
                 pct_of_net = (if Float.abs !total_net < 1e-15 then 0.0 else net /. !total_net);
               })
        |> Array.of_list in
        Array.sort (fun x y -> compare (Float.abs y.net_pnl) (Float.abs x.net_pnl)) contributions ;
        contributions


let by_symbol fills = group_by fills ~key_of:(fun f -> f.symbol)

let by_strategy fills = group_by fills ~key_of:(fun f -> f.strategy_id)

let by_side fills =
  group_by fills ~key_of:(fun f -> if f.signed_quantity >= 0.0 then "buy" else "sell")


let by_liquidity fills = group_by fills ~key_of:(fun f -> if f.is_maker then "maker" else "taker")

let by_regime fills ~regimes =
  let n = Array.length regimes in
  (* Binary search for the last label at or before ts. *)
  let label_at ts =
    if n = 0 then "unlabelled"
    else if Int64.compare ts (fst regimes.(0)) < 0 then "unlabelled"
    else
      let lo = ref 0 and hi = ref (n - 1) in
        while !lo < !hi do
          let mid = (!lo + !hi + 1) / 2 in
            if Int64.compare (fst regimes.(mid)) ts <= 0 then lo := mid else hi := mid - 1
        done ;
        Regime.to_string (snd regimes.(!lo)) in
    group_by fills ~key_of:(fun f -> label_at f.ts_ns)


let by_holding_bucket fills ~buckets_ns =
  (* Track when each symbol's position was opened so a closing fill can be bucketed by holding
     period. A fill that increases exposure is attributed to the bucket its open began. *)
  let opened : (string, int64) Hashtbl.t = Hashtbl.create 16 in
  let net_qty : (string, float) Hashtbl.t = Hashtbl.create 16 in
  let nb = Array.length buckets_ns in
  let bucket_name held =
    let rec find i =
      if i >= nb then Printf.sprintf ">%Ldns" buckets_ns.(nb - 1)
      else if Int64.compare held buckets_ns.(i) <= 0 then Printf.sprintf "<=%Ldns" buckets_ns.(i)
      else find (i + 1) in
      if nb = 0 then "all" else find 0 in
    group_by fills ~key_of:(fun f ->
      let prev = try Hashtbl.find net_qty f.symbol with Not_found -> 0.0 in
      let next = prev +. f.signed_quantity in
      let open_ts =
        if Float.abs prev < 1e-12 then (
          Hashtbl.replace opened f.symbol f.ts_ns ;
          f.ts_ns)
        else try Hashtbl.find opened f.symbol with Not_found -> f.ts_ns in
        Hashtbl.replace net_qty f.symbol next ;
        if Float.abs next < 1e-12 then Hashtbl.remove opened f.symbol ;
        bucket_name (Int64.sub f.ts_ns open_ts))


type waterfall = {
  gross_pnl : float;
  commission : float;
  slippage : float;
  financing : float;
  net_pnl : float;
  cost_ratio : float;
}

let cost_waterfall fills =
  let n = Array.length fills in
    if n = 0 then
      {
        gross_pnl = 0.0;
        commission = 0.0;
        slippage = 0.0;
        financing = 0.0;
        net_pnl = 0.0;
        cost_ratio = 0.0;
      }
    else
      let gross = fills.(n - 1).realized_pnl_after in
      let commission = Array.fold_left (fun a (f : fill) -> a +. f.commission) 0.0 fills in
      let slippage = Array.fold_left (fun a (f : fill) -> a +. f.slippage_cost) 0.0 fills in
      let financing = Array.fold_left (fun a (f : fill) -> a +. f.financing_cost) 0.0 fills in
      let costs = commission +. slippage +. financing in
        {
          gross_pnl = gross;
          commission;
          slippage;
          financing;
          net_pnl = gross -. costs;
          cost_ratio = (if Float.abs gross < 1e-15 then 0.0 else costs /. Float.abs gross);
        }


let contribution_to_string c =
  Printf.sprintf "%-14s net=%12.2f (%6.2f%%) realized=%12.2f fees=%9.2f slip=%9.2f n=%d" c.key
    c.net_pnl (c.pct_of_net *. 100.0) c.realized_pnl c.commission c.slippage_cost c.n_fills


let waterfall_to_string w =
  Printf.sprintf
    "gross=%.2f  - commission=%.2f  - slippage=%.2f  - financing=%.2f  = net=%.2f (costs are \
     %.1f%% of gross)"
    w.gross_pnl w.commission w.slippage w.financing w.net_pnl (w.cost_ratio *. 100.0)
