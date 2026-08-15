module Order_book = Algostream_domain_market.Order_book
module Regime = Algostream_analytics.Regime
module Analytics_config = Algostream_analytics.Config
module Timestamp = Algostream_domain_common.Timestamp

type sym_state = {
  mutable last : float;
  mutable bid : float option;
  mutable ask : float option;
  mutable book : Order_book.order_book option;
  mutable mark_adjust : float;  (** cumulative permanent-impact multiplier *)
  (* Rolling log returns for realized vol. *)
  ret_buf : float array;
  mutable ret_pos : int;
  mutable ret_n : int;
  mutable prev_price : float;
  (* Volume in a trailing window, for ADV. *)
  mutable vol_sum : float;
  mutable vol_start_ns : int64;
  mutable last_ts_ns : int64;
  (* Running VWAP over the whole run. *)
  mutable vwap_num : float;
  mutable vwap_den : float;
  detector : Regime.detector;
  mutable regime : Regime.t option;
  mutable n_obs : int;
}

type t = {
  vol_window : int;
  adv_window_ns : int64;
  table : (string, sym_state) Hashtbl.t;
  cfg : Analytics_config.t;
}

let create ?(vol_window = 64) ?(adv_window_ns = 86_400_000_000_000L) () =
  { vol_window; adv_window_ns; table = Hashtbl.create 16; cfg = Analytics_config.default }


let get t symbol =
  match Hashtbl.find_opt t.table symbol with
  | Some s -> s
  | None ->
    let s =
      {
        last = 0.0;
        bid = None;
        ask = None;
        book = None;
        mark_adjust = 1.0;
        ret_buf = Array.make t.vol_window 0.0;
        ret_pos = 0;
        ret_n = 0;
        prev_price = 0.0;
        vol_sum = 0.0;
        vol_start_ns = 0L;
        last_ts_ns = 0L;
        vwap_num = 0.0;
        vwap_den = 0.0;
        detector = Regime.create t.cfg;
        regime = None;
        n_obs = 0;
      } in
      Hashtbl.replace t.table symbol s ;
      s


let push_return s r =
  s.ret_buf.(s.ret_pos) <- r ;
  s.ret_pos <- (s.ret_pos + 1) mod Array.length s.ret_buf ;
  if s.ret_n < Array.length s.ret_buf then s.ret_n <- s.ret_n + 1


let realized_vol s =
  if s.ret_n < 8 then None
  else
    let n = s.ret_n in
    let sum = ref 0.0 in
      for i = 0 to n - 1 do
        sum := !sum +. s.ret_buf.(i)
      done ;
      let m = !sum /. float_of_int n in
      let ss = ref 0.0 in
        for i = 0 to n - 1 do
          let d = s.ret_buf.(i) -. m in
            ss := !ss +. (d *. d)
        done ;
        let v = sqrt (!ss /. float_of_int (n - 1)) in
          if Float.is_finite v && v > 0.0 then Some v else None


let observe_price t s ~ts_ns ~price ~volume =
  ignore t ;
  if price > 0.0 then (
    if s.prev_price > 0.0 then push_return s (log (price /. s.prev_price)) ;
    s.prev_price <- price ;
    s.last <- price ;
    s.n_obs <- s.n_obs + 1 ;
    (* Drive the regime detector on the same event-time cadence the analytics layer would. *)
    (match realized_vol s with
    | Some v ->
      let r =
        Regime.update s.detector ~ts_ns ~ewma_vol:v ~vol_band_median:v ~drawdown_from_peak:0.0
          ~return_run_length:0 ~return_run_sign:0 in
        s.regime <- Some r
    | None -> ()) ;
    if volume > 0.0 then (
      s.vwap_num <- s.vwap_num +. (price *. volume) ;
      s.vwap_den <- s.vwap_den +. volume)) ;
  if volume > 0.0 then (
    if Int64.equal s.vol_start_ns 0L then s.vol_start_ns <- ts_ns ;
    s.vol_sum <- s.vol_sum +. volume) ;
  s.last_ts_ns <- ts_ns


let observe t record =
  match record with
  | Data_source.Tick { symbol; ts_ns; price; volume; bid; ask } ->
    let s = get t symbol in
      s.bid <- bid ;
      s.ask <- ask ;
      observe_price t s ~ts_ns ~price ~volume
  | Data_source.Trade_print { symbol; ts_ns; price; size; _ } ->
    let s = get t symbol in
      observe_price t s ~ts_ns ~price ~volume:size
  | Data_source.Book b ->
    let s = get t b.Order_book.symbol in
    let level_price = function
      | Some (l : Order_book.Price_level.t) -> Some l.price
      | None -> None in
      s.book <- Some b ;
      s.bid <- level_price (Order_book.best_bid b) ;
      s.ask <- level_price (Order_book.best_ask b) ;
      (match Order_book.mid_price b with
      | Some m ->
        observe_price t s ~ts_ns:(Timestamp.to_ns b.Order_book.timestamp) ~price:m ~volume:0.0
      | None -> ())


let find t symbol = Hashtbl.find_opt t.table symbol

let last_price t symbol =
  match find t symbol with Some s when s.last > 0.0 -> Some (s.last *. s.mark_adjust) | _ -> None


let quote t symbol =
  match find t symbol with
  | Some s ->
    (match (s.bid, s.ask) with
    | Some b, Some a -> Some (b *. s.mark_adjust, a *. s.mark_adjust)
    | _ -> None)
  | None -> None


let book t symbol = match find t symbol with Some s -> s.book | None -> None

let mid t symbol =
  match quote t symbol with Some (b, a) -> Some ((b +. a) /. 2.0) | None -> last_price t symbol


let sigma t symbol = match find t symbol with Some s -> realized_vol s | None -> None

let adv t symbol =
  match find t symbol with
  | None -> None
  | Some s ->
    let span = Int64.sub s.last_ts_ns s.vol_start_ns in
      (* Refuse to extrapolate from less than an hour of history — scaling ten seconds of volume up
         to a day produces a number that looks authoritative and is meaningless. *)
      if Int64.compare span 3_600_000_000_000L < 0 || s.vol_sum <= 0.0 then None
      else
        let days = Int64.to_float span /. 86_400e9 in
          if days <= 0.0 then None else Some (s.vol_sum /. days)


let regime t symbol = match find t symbol with Some s -> s.regime | None -> None

let slippage_ctx t symbol =
  match find t symbol with
  | None -> None
  | Some s ->
    if s.last <= 0.0 then None
    else
      Some
        {
          Slippage.bid = (match s.bid with Some b -> Some (b *. s.mark_adjust) | None -> None);
          ask = (match s.ask with Some a -> Some (a *. s.mark_adjust) | None -> None);
          last = s.last *. s.mark_adjust;
          sigma = realized_vol s;
          adv = adv t symbol;
          regime = s.regime;
          book = s.book;
        }


let apply_permanent_impact t symbol ~bps =
  let s = get t symbol in
    (* Multiplicative so repeated impacts compound rather than drifting linearly off the mark. *)
    s.mark_adjust <- s.mark_adjust *. (1.0 +. (bps /. 10_000.0))


let vwap t symbol =
  match find t symbol with
  | Some s when s.vwap_den > 0.0 -> s.vwap_num /. s.vwap_den
  | Some s -> s.last
  | None -> 0.0


let symbols t = Hashtbl.fold (fun k _ acc -> k :: acc) t.table [] |> List.sort String.compare
