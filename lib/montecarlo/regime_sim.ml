module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate
module Regime = Algostream_analytics.Regime
module Per_symbol = Algostream_analytics.Per_symbol
module Tick_event = Algostream_analytics.Tick_event
module Analytics_config = Algostream_analytics.Config
module Snapshot = Algostream_analytics.Snapshot

type state_params = {
  label : Regime.t;
  mu : float;
  sigma : float;
  n_observed : int;
}

type spec = {
  states : state_params array;
  transition : float array array;
  initial : float array;
}

(* The four detector states, in a fixed order so a fitted spec's indices are stable. Trending is
   collapsed to a single state: direction is a property of the emission (the mean return), not of
   the regime, and splitting it would halve the observations backing each estimate. *)
let canonical_states =
  [|
    Regime.Calm; Regime.Trending { direction = 1; strength = 0.0 }; Regime.Volatile; Regime.Crisis;
  |]


let state_index (r : Regime.t) =
  match r with
  | Regime.Calm -> 0
  | Regime.Trending _ -> 1
  | Regime.Volatile -> 2
  | Regime.Crisis -> 3


let n_states = 4

let label_series ~returns ~start_ts_ns ~interval_ns ~s0 =
  let n = Array.length returns in
  (* Drive Per_symbol headlessly — no bus, no Domain. Same pattern as
     test/pairs/test_determinism. *)
  let ps = Per_symbol.create ~symbol:"SIM" ~config:Analytics_config.default in
  let out = Array.make n Regime.Calm in
  let price = ref s0 in
    for i = 0 to n - 1 do
      price := !price *. (1.0 +. returns.(i)) ;
      let ts = Int64.add start_ts_ns (Int64.mul (Int64.of_int i) interval_ns) in
      let te =
        {
          Tick_event.symbol = "SIM";
          timestamp_ns = ts;
          price = !price;
          size = 1.0;
          bid = !price;
          ask = !price;
          kind = Tick_event.Market;
        } in
        Per_symbol.on_tick ps te ;
        (* Per_symbol throttles snapshot publication (min_publish_interval_ns, default 10ms), so at
           a tick cadence finer than that the label lags slightly. Calibrating at bar cadence avoids
           it; the .mli says so. *)
        out.(i) <- (Per_symbol.snapshot ps).Snapshot.regime
    done ;
    out


let fit_from_labels ~labels ~returns ?(smoothing = 1.0) () =
  let n = min (Array.length labels) (Array.length returns) in
  let counts = Array.make_matrix n_states n_states smoothing in
  let sums = Array.make n_states 0.0 in
  let sq = Array.make n_states 0.0 in
  let obs = Array.make n_states 0 in
  let init_counts = Array.make n_states smoothing in
    if n > 0 then
      init_counts.(state_index labels.(0)) <- init_counts.(state_index labels.(0)) +. 1.0 ;
    for i = 0 to n - 1 do
      let si = state_index labels.(i) in
        sums.(si) <- sums.(si) +. returns.(i) ;
        sq.(si) <- sq.(si) +. (returns.(i) *. returns.(i)) ;
        obs.(si) <- obs.(si) + 1 ;
        if i + 1 < n then
          let sj = state_index labels.(i + 1) in
            counts.(si).(sj) <- counts.(si).(sj) +. 1.0
    done ;
    let normalize row =
      let total = Array.fold_left ( +. ) 0.0 row in
        if total <= 0.0 then Array.make n_states (1.0 /. float_of_int n_states)
        else Array.map (fun c -> c /. total) row in
    let transition = Array.map normalize counts in
    let initial = normalize init_counts in
    let states =
      Array.init n_states (fun i ->
        let k = obs.(i) in
        let mu = if k > 0 then sums.(i) /. float_of_int k else 0.0 in
        let var = if k > 1 then Float.max 0.0 ((sq.(i) /. float_of_int k) -. (mu *. mu)) else 0.0 in
          { label = canonical_states.(i); mu; sigma = sqrt var; n_observed = k }) in
      { states; transition; initial }


let fit ~returns ~start_ts_ns ~interval_ns ~s0 ?(smoothing = 1.0) () =
  let labels = label_series ~returns ~start_ts_ns ~interval_ns ~s0 in
    fit_from_labels ~labels ~returns ~smoothing ()


let draw_state rng row = Variate.choose_weighted rng ~weights:row

let emit rng (sp : state_params) =
  if sp.sigma <= 0.0 then sp.mu else sp.mu +. (sp.sigma *. Variate.normal rng)


let simulate ~rng spec ~n =
  let labels = Array.make n Regime.Calm in
  let rets = Array.make n 0.0 in
  let s = ref (draw_state rng spec.initial) in
    for i = 0 to n - 1 do
      labels.(i) <- spec.states.(!s).label ;
      rets.(i) <- emit rng spec.states.(!s) ;
      s := draw_state rng spec.transition.(!s)
    done ;
    (labels, rets)


let simulate_with_break ~rng spec ~n ~to_state ~at_step =
  let labels = Array.make n Regime.Calm in
  let rets = Array.make n 0.0 in
  let forced = max 0 (min (n_states - 1) to_state) in
  let s = ref (draw_state rng spec.initial) in
    for i = 0 to n - 1 do
      if i = at_step then s := forced ;
      labels.(i) <- spec.states.(!s).label ;
      rets.(i) <- emit rng spec.states.(!s) ;
      (* After the break the chain runs freely again — the break sets the state, it does not pin it.
         A regime that the fitted chain leaves quickly will leave quickly here too, which is the
         honest behaviour. *)
      s := draw_state rng spec.transition.(!s)
    done ;
    (labels, rets)


let expected_dwell spec =
  Array.init n_states (fun i ->
    let p_ii = spec.transition.(i).(i) in
      if p_ii >= 1.0 then infinity else 1.0 /. (1.0 -. p_ii))


let stationary_distribution spec =
  (* Start from the chain's own initial distribution, not from uniform.

     For an irreducible chain the limit is the same either way. For a reducible one — which a fitted
     chain often is, because a regime the detector never labelled gets an absorbing self-loop from
     the Laplace smoothing — a uniform start parks mass in states the process can never actually
     reach, and reports a distribution the simulation does not produce. Starting from [initial]
     gives the limiting distribution of the process as specified, which is the quantity a caller is
     asking about. *)
  let v = ref (Array.copy spec.initial) in
    (* Power iteration. 512 steps is far past convergence for a 4-state chain. *)
    for _ = 1 to 512 do
      let next = Array.make n_states 0.0 in
        for i = 0 to n_states - 1 do
          for j = 0 to n_states - 1 do
            next.(j) <- next.(j) +. (!v.(i) *. spec.transition.(i).(j))
          done
        done ;
        let total = Array.fold_left ( +. ) 0.0 next in
          if total > 0.0 then Array.iteri (fun j x -> next.(j) <- x /. total) next ;
          v := next
    done ;
    !v


let spec_to_string spec =
  let b = Buffer.create 256 in
    Buffer.add_string b "regime chain:\n" ;
    Array.iteri
      (fun i sp ->
        Buffer.add_string b
          (Printf.sprintf "  %-10s mu=%+.6f sigma=%.6f n=%d dwell=%.1f  ->  [%s]\n"
             (Regime.to_string sp.label) sp.mu sp.sigma sp.n_observed
             (expected_dwell spec).(i)
             (String.concat " "
                (Array.to_list (Array.map (Printf.sprintf "%.3f") spec.transition.(i))))))
      spec.states ;
    Buffer.contents b
