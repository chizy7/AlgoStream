module Snapshot = Algostream_pairs.Snapshot
module Pair_id = Algostream_pairs.Pair_id
module Mean_reversion = Algostream_pairs.Mean_reversion
module Order = Algostream_domain_orders.Order

let name = "pairs_mean_reversion"

let version = "1.0"

type params = {
  target_gross_notional : float;
  max_gross_pct_of_nav : float;
  beta_hedge : float;
  min_half_life_bars : float;
  max_half_life_bars : float;
  max_adf_pvalue : float;
  min_abs_corr : float;
  use_limit_orders : float;
}

let default_params =
  {
    target_gross_notional = 10_000.0;
    max_gross_pct_of_nav = 0.30;
    beta_hedge = 1.0;
    min_half_life_bars = 2.0;
    max_half_life_bars = 100.0;
    max_adf_pvalue = 0.05;
    min_abs_corr = 0.70;
    use_limit_orders = 0.0;
  }


let param_bounds =
  [
    ("target_gross_notional", 1_000.0, 1_000_000.0);
    ("max_gross_pct_of_nav", 0.01, 1.0);
    ("beta_hedge", 0.0, 2.0);
    ("min_half_life_bars", 0.5, 50.0);
    ("max_half_life_bars", 5.0, 2000.0);
    ("max_adf_pvalue", 0.001, 0.5);
    ("min_abs_corr", 0.0, 0.99);
    ("use_limit_orders", 0.0, 1.0);
  ]


let params_to_assoc p =
  [
    ("target_gross_notional", p.target_gross_notional);
    ("max_gross_pct_of_nav", p.max_gross_pct_of_nav);
    ("beta_hedge", p.beta_hedge);
    ("min_half_life_bars", p.min_half_life_bars);
    ("max_half_life_bars", p.max_half_life_bars);
    ("max_adf_pvalue", p.max_adf_pvalue);
    ("min_abs_corr", p.min_abs_corr);
    ("use_limit_orders", p.use_limit_orders);
  ]


let ( let* ) = Result.bind

let params_of_assoc assoc =
  (* Range-check every dimension against its declared bounds, so a search that wanders outside the
     space gets a clear error rather than a silently clamped evaluation. *)
  let get key =
    match List.find_opt (fun (k, _, _) -> String.equal k key) param_bounds with
    | Some (_, lo, hi) -> Strategy.require_in assoc key ~lo ~hi
    | None -> Strategy.require assoc key in
    let* target_gross_notional = get "target_gross_notional" in
      let* max_gross_pct_of_nav = get "max_gross_pct_of_nav" in
        let* beta_hedge = get "beta_hedge" in
          let* min_half_life_bars = get "min_half_life_bars" in
            let* max_half_life_bars = get "max_half_life_bars" in
              let* max_adf_pvalue = get "max_adf_pvalue" in
                let* min_abs_corr = get "min_abs_corr" in
                  let* use_limit_orders = get "use_limit_orders" in
                    if min_half_life_bars >= max_half_life_bars then
                      Error
                        (Printf.sprintf
                           "min_half_life_bars (%g) must be below max_half_life_bars (%g)"
                           min_half_life_bars max_half_life_bars)
                    else
                      Ok
                        {
                          target_gross_notional;
                          max_gross_pct_of_nav;
                          beta_hedge;
                          min_half_life_bars;
                          max_half_life_bars;
                          max_adf_pvalue;
                          min_abs_corr;
                          use_limit_orders;
                        }


(* Per-pair bookkeeping. [acted] is what makes the strategy idempotent: the classifier repeats
   Long_spread for as long as z sits past the band, and without this we would submit an entry on
   every tick. *)
type pair_state = {
  pair : Pair_id.t;
  y_symbol : string;
  x_symbol : string;
  mutable acted : Mean_reversion.signal option;
  mutable open_side : Side.t option;  (** side of the y leg while a position is open *)
}

type state = {
  params : params;
  symbols : string list;
  pairs : (string, pair_state) Hashtbl.t;  (** keyed by Pair_id.to_string *)
  mutable seq : int;  (** client-order-id counter *)
  mutable n_signals : int;
  mutable n_entries : int;
  mutable n_exits : int;
  mutable n_skipped_not_ready : int;
  mutable n_skipped_screen : int;
  mutable n_skipped_idempotent : int;
  mutable n_forced_flat : int;
}

(* Build the Pair_id for a raw exchange symbol pair. Falls back to a synthetic canonical symbol so
   an unrecognised ticker still produces a usable identifier rather than dropping the pair. *)
let pair_id_of_raw y_raw x_raw =
  let canonical raw =
    match Pair_id.Symbol.parse ~exchange:"binance" ~raw with
    | Some s -> s
    | None -> { Pair_id.Symbol.base = raw; quote = "USD"; asset_class = Pair_id.Symbol.Crypto }
  in
    Pair_id.of_symbols (canonical y_raw) (canonical x_raw)


let create ~params ~symbols =
  let pairs = Hashtbl.create 16 in
  (* Register pairs eagerly, taking [symbols] as consecutive (y, x) couples. The engine reads
     [subscriptions] once at startup to decide which Per_pair drivers to run, so a table populated
     lazily on the first snapshot would never be consulted — no drivers, no snapshots, no trades. An
     odd trailing symbol is ignored: half a pair is not tradeable. *)
  let rec register = function
    | y :: x :: rest ->
      let pid = pair_id_of_raw y x in
        Hashtbl.replace pairs (Pair_id.to_string pid)
          { pair = pid; y_symbol = y; x_symbol = x; acted = None; open_side = None } ;
        register rest
    | [ _ ] | [] -> () in
    register symbols ;
    {
      params;
      symbols;
      pairs;
      seq = 0;
      n_signals = 0;
      n_entries = 0;
      n_exits = 0;
      n_skipped_not_ready = 0;
      n_skipped_screen = 0;
      n_skipped_idempotent = 0;
      n_forced_flat = 0;
    }


(* Pairs are registered in [create], so this is populated before the engine reads it at startup. *)
let subscriptions st =
  Hashtbl.fold
    (fun _ ps acc ->
      Strategy.Pair { pair = ps.pair; y_symbol = ps.y_symbol; x_symbol = ps.x_symbol } :: acc)
    st.pairs
    (List.map (fun s -> Strategy.Symbol s) st.symbols)


let next_id st tag =
  st.seq <- st.seq + 1 ;
  Printf.sprintf "%s-%s-%d" name tag st.seq


(* All five screens in one place so the reason a pair is untradeable is a single readable
   expression. *)
let passes_screen p (s : Snapshot.t) =
  s.cointegrated && s.adf_p_value <= p.max_adf_pvalue
  && Float.abs s.corr >= p.min_abs_corr
  && s.half_life_bars >= p.min_half_life_bars
  && s.half_life_bars <= p.max_half_life_bars
  && Float.is_finite s.half_life_bars


let order_type_for p ctx symbol side =
  if p.use_limit_orders < 0.5 then (Order.Market, Action.Normal)
  else
    match ctx.Context.quote symbol with
    | Some (bid, ask) when bid > 0.0 && ask > 0.0 ->
      (* Rest at the near touch — this is what exercises the fill engine's queue-position path. *)
      let px = match side with Side.Buy -> bid | Side.Sell -> ask in
        (Order.Limit px, Action.Passive)
    | _ -> (Order.Market, Action.Normal)


(* Size so that |y_notional| + |x_notional| meets the gross target, given the hedge ratio. *)
let leg_quantities p ~nav ~(s : Snapshot.t) =
  let hedge = p.beta_hedge *. s.beta in
  let py = s.last_price_y and px = s.last_price_x in
    if py <= 0.0 || px <= 0.0 then None
    else
      let gross_target = Float.min p.target_gross_notional (p.max_gross_pct_of_nav *. nav) in
      let per_unit_gross = py +. (Float.abs hedge *. px) in
        if per_unit_gross <= 0.0 || gross_target <= 0.0 then None
        else
          let qy = gross_target /. per_unit_gross in
          let qx = Float.abs hedge *. qy in
            if qy <= 0.0 || qx <= 0.0 then None else Some (qy, qx)


let submit_pair st ctx ps ~y_side ~qy ~qx ~tag =
  let p = st.params in
  let x_side = Side.opposite y_side in
  let oty, uy = order_type_for p ctx ps.y_symbol y_side in
  let otx, ux = order_type_for p ctx ps.x_symbol x_side in
    [
      Action.submit ~symbol:ps.y_symbol ~side:y_side ~quantity:qy ~order_type:oty ~urgency:uy ~tag
        ~client_order_id:(next_id st "y") ~strategy_id:name ();
      Action.submit ~symbol:ps.x_symbol ~side:x_side ~quantity:qx ~order_type:otx ~urgency:ux ~tag
        ~client_order_id:(next_id st "x") ~strategy_id:name ();
    ]


(* Flatten by reading the actual signed positions rather than by remembering what we sent — fills
   may have been partial, so the position is the only reliable statement of exposure. *)
let flatten st ctx ps ~tag =
  let close symbol =
    let q = ctx.Context.position symbol in
      if Float.abs q < 1e-12 then []
      else
        match Side.of_signed (-.q) with
        | None -> []
        | Some side ->
          [
            Action.submit ~symbol ~side ~quantity:(Float.abs q) ~order_type:Order.Market
              ~urgency:Action.Aggressive ~tag ~client_order_id:(next_id st "flat") ~strategy_id:name
              ();
          ] in
    close ps.y_symbol @ close ps.x_symbol


let on_pair_snapshot st ctx (s : Snapshot.t) ~y_symbol ~x_symbol =
  let p = st.params in
  let key = Pair_id.to_string s.pair in
  let ps =
    match Hashtbl.find_opt st.pairs key with
    | Some ps -> ps
    | None ->
      (* Raw exchange symbols arrive on the event: Pair_id carries canonical symbols ("BTC/USDT"),
         but orders go out against raw ones ("BTCUSDT"). *)
      let ps = { pair = s.pair; y_symbol; x_symbol; acted = None; open_side = None } in
        Hashtbl.replace st.pairs key ps ;
        ps in
    if not s.ready then (
      st.n_skipped_not_ready <- st.n_skipped_not_ready + 1 ;
      [])
    else if not (passes_screen p s) then (
      st.n_skipped_screen <- st.n_skipped_screen + 1 ;
      (* A pair that fails its screen while a position is open gets flattened: the statistical
         relationship the trade was predicated on is no longer demonstrable. *)
      match ps.open_side with
      | None -> []
      | Some _ ->
        ps.open_side <- None ;
        ps.acted <- None ;
        st.n_forced_flat <- st.n_forced_flat + 1 ;
        flatten st ctx ps ~tag:"screen_failed")
    else (
      st.n_signals <- st.n_signals + 1 ;
      let same_as_before = match ps.acted with Some prev -> prev = s.signal | None -> false in
        if same_as_before then (
          st.n_skipped_idempotent <- st.n_skipped_idempotent + 1 ;
          [])
        else (
          ps.acted <- Some s.signal ;
          match s.signal with
          | Mean_reversion.Hold -> []
          | Mean_reversion.Exit ->
            if ps.open_side = None then []
            else (
              ps.open_side <- None ;
              st.n_exits <- st.n_exits + 1 ;
              flatten st ctx ps ~tag:"exit")
          | Mean_reversion.Long_spread | Mean_reversion.Short_spread ->
            (* Long spread = spread is cheap = buy y, sell beta*x. *)
            let y_side =
              match s.signal with Mean_reversion.Long_spread -> Side.Buy | _ -> Side.Sell in
              if ps.open_side <> None then []
              else (
                match leg_quantities p ~nav:ctx.Context.nav ~s with
                | None -> []
                | Some (qy, qx) ->
                  ps.open_side <- Some y_side ;
                  st.n_entries <- st.n_entries + 1 ;
                  submit_pair st ctx ps ~y_side ~qy ~qx
                    ~tag:
                      (match s.signal with
                      | Mean_reversion.Long_spread -> "long_spread"
                      | _ -> "short_spread"))))


let on_event st ctx = function
  | Event.Pair_snapshot { snapshot; y_symbol; x_symbol } ->
    on_pair_snapshot st ctx snapshot ~y_symbol ~x_symbol
  (* Ticks, bars, books and order updates are consumed by the engine to build Context and the pair
     snapshots; this strategy needs nothing further from them. *)
  | Event.Tick _ | Event.Bar _ | Event.Book _ | Event.Fill _ | Event.Order_update _ | Event.Timer _
    ->
    []


let on_stop st ctx =
  Hashtbl.fold
    (fun _ ps acc ->
      match ps.open_side with
      | None -> acc
      | Some _ ->
        ps.open_side <- None ;
        flatten st ctx ps ~tag:"on_stop" @ acc)
    st.pairs []


let diagnostics st =
  [
    ("signals", float_of_int st.n_signals);
    ("entries", float_of_int st.n_entries);
    ("exits", float_of_int st.n_exits);
    ("skipped_not_ready", float_of_int st.n_skipped_not_ready);
    ("skipped_screen", float_of_int st.n_skipped_screen);
    ("skipped_idempotent", float_of_int st.n_skipped_idempotent);
    ("forced_flat", float_of_int st.n_forced_flat);
    ("active_pairs", float_of_int (Hashtbl.length st.pairs));
  ]
