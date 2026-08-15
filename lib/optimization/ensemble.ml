module Metrics = Algostream_performance.Metrics
module Cholesky = Algostream_stochastic.Cholesky

type weighting =
  | Equal
  | Inverse_volatility
  | Sharpe_weighted
  | Risk_parity
  | Min_variance
  | Custom of float array

type member = {
  name : string;
  returns : float array;
}

type result = {
  weights : (string * float) array;
  combined : Metrics.t;
  diversification_ratio : float;
  effective_n : float;
  avg_pairwise_correlation : float;
  marginal_risk_contribution : (string * float) array;
  incremental_sharpe : (string * float) array;
  correlation_matrix : float array array;
}

type error =
  [ `Empty
  | `Length_mismatch
  | `Not_positive_definite of int
  ]

let mean a =
  let n = Array.length a in
    if n = 0 then 0.0 else Array.fold_left ( +. ) 0.0 a /. float_of_int n


let covariance xs ys =
  let n = min (Array.length xs) (Array.length ys) in
    if n < 2 then 0.0
    else
      let mx = mean (Array.sub xs 0 n) and my = mean (Array.sub ys 0 n) in
      let s = ref 0.0 in
        for i = 0 to n - 1 do
          s := !s +. ((xs.(i) -. mx) *. (ys.(i) -. my))
        done ;
        !s /. float_of_int (n - 1)


let cov_matrix members =
  let k = Array.length members in
    Array.init k (fun i ->
      Array.init k (fun j -> covariance members.(i).returns members.(j).returns))


let corr_of_cov cov =
  let k = Array.length cov in
    Array.init k (fun i ->
      Array.init k (fun j ->
        let d = sqrt (cov.(i).(i) *. cov.(j).(j)) in
          if d <= 0.0 then 0.0 else cov.(i).(j) /. d))


let normalize_nonneg w =
  let w = Array.map (fun x -> if x > 0.0 || (Float.is_nan x = false && x > 0.0) then x else 0.0) w in
  let total = Array.fold_left ( +. ) 0.0 w in
    if total <= 0.0 then Array.make (Array.length w) (1.0 /. float_of_int (max 1 (Array.length w)))
    else Array.map (fun x -> x /. total) w


(* Solve Sigma w = 1 by Cholesky forward/back substitution, then normalize. Clipping negatives
   afterwards is what makes this approximate under a long-only constraint — see the .mli. *)
let min_variance_weights cov =
  match Cholesky.factor_jittered cov with
  | Error (`Not_positive_definite i) -> Error (`Not_positive_definite i)
  | Error (`Not_square _) -> Error `Length_mismatch
  | Ok l ->
    let k = Array.length cov in
    let ones = Array.make k 1.0 in
    (* forward: L y = 1 *)
    let y = Array.make k 0.0 in
      for i = 0 to k - 1 do
        let s = ref ones.(i) in
          for j = 0 to i - 1 do
            s := !s -. (l.(i).(j) *. y.(j))
          done ;
          y.(i) <- (if Float.abs l.(i).(i) < 1e-15 then 0.0 else !s /. l.(i).(i))
      done ;
      (* back: L^T w = y *)
      let w = Array.make k 0.0 in
        for i = k - 1 downto 0 do
          let s = ref y.(i) in
            for j = i + 1 to k - 1 do
              s := !s -. (l.(j).(i) *. w.(j))
            done ;
            w.(i) <- (if Float.abs l.(i).(i) < 1e-15 then 0.0 else !s /. l.(i).(i))
        done ;
        Ok (normalize_nonneg w)


let risk_parity_weights cov =
  let k = Array.length cov in
  let w = ref (Array.make k (1.0 /. float_of_int k)) in
    (* Fixed point: w_i <- w_i * (target / MRC_i), renormalized. Converges quickly for a PSD
       covariance and small k. *)
    for _ = 1 to 256 do
      let mrc =
        Array.init k (fun i ->
          let s = ref 0.0 in
            for j = 0 to k - 1 do
              s := !s +. (cov.(i).(j) *. !w.(j))
            done ;
            !w.(i) *. !s) in
      let total = Array.fold_left ( +. ) 0.0 mrc in
        if total > 0.0 then
          let target = total /. float_of_int k in
          let next =
            Array.mapi (fun i wi -> if mrc.(i) <= 0.0 then wi else wi *. (target /. mrc.(i))) !w
          in
            w := normalize_nonneg next
    done ;
    !w


let weights_for ~weighting ~members ~cov ~periods_per_year =
  let k = Array.length members in
    match weighting with
    | Equal -> Ok (Array.make k (1.0 /. float_of_int k))
    | Custom w -> if Array.length w <> k then Error `Length_mismatch else Ok (normalize_nonneg w)
    | Inverse_volatility ->
      Ok
        (normalize_nonneg
           (Array.init k (fun i ->
              let v = sqrt cov.(i).(i) in
                if v <= 0.0 then 0.0 else 1.0 /. v)))
    | Sharpe_weighted ->
      Ok
        (normalize_nonneg
           (Array.map
              (fun m ->
                let mm = Metrics.of_returns ~returns:m.returns ~periods_per_year () in
                  Float.max 0.0 mm.Metrics.sharpe)
              members))
    | Risk_parity -> Ok (risk_parity_weights cov)
    | Min_variance -> min_variance_weights cov


let portfolio_returns members w =
  let k = Array.length members in
    if k = 0 then [||]
    else
      let n = Array.fold_left (fun a m -> min a (Array.length m.returns)) max_int members in
        Array.init n (fun t ->
          let s = ref 0.0 in
            for i = 0 to k - 1 do
              s := !s +. (w.(i) *. members.(i).returns.(t))
            done ;
            !s)


let build_result ~members ~w ~cov ~periods_per_year ~risk_free_rate_ann =
  let k = Array.length members in
  let corr = corr_of_cov cov in
  let combined_returns = portfolio_returns members w in
  let combined =
    Metrics.of_returns ~returns:combined_returns ~periods_per_year ~risk_free_rate_ann () in
  let port_var =
    let s = ref 0.0 in
      for i = 0 to k - 1 do
        for j = 0 to k - 1 do
          s := !s +. (w.(i) *. w.(j) *. cov.(i).(j))
        done
      done ;
      !s in
  let port_vol = sqrt (Float.max 0.0 port_var) in
  let weighted_vol =
    let s = ref 0.0 in
      for i = 0 to k - 1 do
        s := !s +. (w.(i) *. sqrt (Float.max 0.0 cov.(i).(i)))
      done ;
      !s in
  let mrc =
    Array.init k (fun i ->
      let s = ref 0.0 in
        for j = 0 to k - 1 do
          s := !s +. (cov.(i).(j) *. w.(j))
        done ;
        if port_var <= 0.0 then 0.0 else w.(i) *. !s /. port_var) in
  let pair_sum = ref 0.0 and pair_n = ref 0 in
    for i = 0 to k - 1 do
      for j = i + 1 to k - 1 do
        pair_sum := !pair_sum +. corr.(i).(j) ;
        incr pair_n
      done
    done ;
    (* Drop each member in turn and see what the combined Sharpe does. A member with a positive
       standalone Sharpe can still be subtracting value here. *)
    let incremental =
      Array.init k (fun drop ->
        if k <= 1 then (members.(drop).name, 0.0)
        else
          let kept = Array.of_list (List.filteri (fun i _ -> i <> drop) (Array.to_list members)) in
          let kept_w =
            normalize_nonneg (Array.of_list (List.filteri (fun i _ -> i <> drop) (Array.to_list w)))
          in
          let r = portfolio_returns kept kept_w in
          let m = Metrics.of_returns ~returns:r ~periods_per_year ~risk_free_rate_ann () in
            (members.(drop).name, combined.Metrics.sharpe -. m.Metrics.sharpe)) in
      {
        weights = Array.mapi (fun i m -> (m.name, w.(i))) members;
        combined;
        diversification_ratio = (if port_vol <= 0.0 then 0.0 else weighted_vol /. port_vol);
        effective_n =
          (let ss = Array.fold_left (fun a x -> a +. (x *. x)) 0.0 w in
             if ss <= 0.0 then 0.0 else 1.0 /. ss);
        avg_pairwise_correlation = (if !pair_n = 0 then 0.0 else !pair_sum /. float_of_int !pair_n);
        marginal_risk_contribution = Array.mapi (fun i m -> (m.name, mrc.(i))) members;
        incremental_sharpe = incremental;
        correlation_matrix = corr;
      }


let combine ~members ~weighting ~periods_per_year ?(risk_free_rate_ann = 0.0) () =
  let k = Array.length members in
    if k = 0 then Error `Empty
    else
      let cov = cov_matrix members in
        match weights_for ~weighting ~members ~cov ~periods_per_year with
        | Error e -> Error e
        | Ok w -> Ok (build_result ~members ~w ~cov ~periods_per_year ~risk_free_rate_ann)


let rolling_combine ~members ~weighting ~lookback ~rebalance_every ~periods_per_year
  ?(risk_free_rate_ann = 0.0) () =
  let k = Array.length members in
    if k = 0 then Error `Empty
    else
      let n = Array.fold_left (fun a m -> min a (Array.length m.returns)) max_int members in
        if n <= lookback then Error `Length_mismatch
        else
          let out = Array.make (n - lookback) 0.0 in
          let current_w = ref (Array.make k (1.0 /. float_of_int k)) in
          let failed = ref None in
            for t = lookback to n - 1 do
              (* Re-estimate on the trailing window and apply FORWARD — the weights used at t were
                 fitted on data strictly before t. *)
              (if (t - lookback) mod max 1 rebalance_every = 0 then
                 let window =
                   Array.map
                     (fun m -> { m with returns = Array.sub m.returns (t - lookback) lookback })
                     members in
                 let cov = cov_matrix window in
                   match weights_for ~weighting ~members:window ~cov ~periods_per_year with
                   | Ok w -> current_w := w
                   | Error e -> if !failed = None then failed := Some e) ;
              let s = ref 0.0 in
                for i = 0 to k - 1 do
                  s := !s +. (!current_w.(i) *. members.(i).returns.(t))
                done ;
                out.(t - lookback) <- !s
            done ;
            match !failed with
            | Some e -> Error e
            | None ->
              let cov = cov_matrix members in
              let combined =
                Metrics.of_returns ~returns:out ~periods_per_year ~risk_free_rate_ann () in
              let base =
                build_result ~members ~w:!current_w ~cov ~periods_per_year ~risk_free_rate_ann in
                Ok { base with combined }


let select_uncorrelated ~members ~max_corr ~max_n =
  let k = Array.length members in
    if k = 0 then [||]
    else
      let cov = cov_matrix members in
      let corr = corr_of_cov cov in
      (* Greedy: take members in order, admitting one only if it stays below max_corr against every
         member already admitted. *)
      let chosen = ref [] in
        for i = 0 to k - 1 do
          if List.length !chosen < max_n then
            let ok = List.for_all (fun j -> Float.abs corr.(i).(j) <= max_corr) !chosen in
              if ok then chosen := i :: !chosen
        done ;
        Array.of_list (List.rev_map (fun i -> members.(i).name) !chosen)


let result_to_string r =
  let b = Buffer.create 256 in
    Buffer.add_string b
      (Printf.sprintf "ensemble: sharpe=%.3f div_ratio=%.3f eff_n=%.2f avg_corr=%.3f\n"
         r.combined.Metrics.sharpe r.diversification_ratio r.effective_n r.avg_pairwise_correlation) ;
    Array.iteri
      (fun i (name, w) ->
        let _, mrc = r.marginal_risk_contribution.(i) in
        let _, inc = r.incremental_sharpe.(i) in
          Buffer.add_string b
            (Printf.sprintf "  %-16s w=%.4f  mrc=%.4f  incremental_sharpe=%+.4f\n" name w mrc inc))
      r.weights ;
    Buffer.contents b
