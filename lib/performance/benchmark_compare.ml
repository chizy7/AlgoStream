type t = {
  n_periods : int;
  alpha_ann : float;
  beta : float;
  r_squared : float;
  correlation : float;
  tracking_error_ann : float;
  information_ratio : float;
  active_return_ann : float;
  up_capture : float;
  down_capture : float;
  capture_ratio : float;
  treynor : float;
}

let empty =
  {
    n_periods = 0;
    alpha_ann = 0.0;
    beta = 0.0;
    r_squared = 0.0;
    correlation = 0.0;
    tracking_error_ann = 0.0;
    information_ratio = 0.0;
    active_return_ann = 0.0;
    up_capture = 0.0;
    down_capture = 0.0;
    capture_ratio = 0.0;
    treynor = 0.0;
  }


let safe_div num den = if Float.abs den < 1e-15 then 0.0 else num /. den

let compare ~strategy ~benchmark ~periods_per_year ?(risk_free_rate_ann = 0.0) () =
  let n = min (Array.length strategy) (Array.length benchmark) in
    if n < 2 then empty
    else
      let s = Array.sub strategy 0 n in
      let b = Array.sub benchmark 0 n in
      let nf = float_of_int n in
      let ms = Returns.mean s and mb = Returns.mean b in
      (* Two-parameter OLS, computed inline. Calling Pairs.Ols.regress2 would pull algostream_pairs
         — and transitively event_bus, normalization and analytics — into a metrics library that a
         Monte Carlo worker links once per run. Twelve lines is the cheaper price; the test suite
         cross-checks this against Ols.regress2 at 1e-10. *)
      let cov = ref 0.0 and var_b = ref 0.0 and var_s = ref 0.0 in
        for i = 0 to n - 1 do
          let ds = s.(i) -. ms and db = b.(i) -. mb in
            cov := !cov +. (ds *. db) ;
            var_b := !var_b +. (db *. db) ;
            var_s := !var_s +. (ds *. ds)
        done ;
        let beta = safe_div !cov !var_b in
        let correlation = safe_div !cov (sqrt (!var_s *. !var_b)) in
        let r_squared = correlation *. correlation in
        let rf_pp = Returns.per_period_rate ~annual_rate:risk_free_rate_ann ~periods_per_year in
        (* Jensen: alpha = (Rs - Rf) - beta * (Rb - Rf), per period, then annualized. *)
        let alpha_pp = ms -. rf_pp -. (beta *. (mb -. rf_pp)) in
        let active = Array.init n (fun i -> s.(i) -. b.(i)) in
        let te_ann = Returns.stddev active *. sqrt periods_per_year in
        let active_ann = Returns.mean active *. periods_per_year in
        let up_s = ref 0.0 and up_b = ref 0.0 and up_n = ref 0 in
        let dn_s = ref 0.0 and dn_b = ref 0.0 and dn_n = ref 0 in
          for i = 0 to n - 1 do
            if b.(i) > 0.0 then (
              up_s := !up_s +. s.(i) ;
              up_b := !up_b +. b.(i) ;
              incr up_n)
            else if b.(i) < 0.0 then (
              dn_s := !dn_s +. s.(i) ;
              dn_b := !dn_b +. b.(i) ;
              incr dn_n)
          done ;
          let up_capture =
            if !up_n = 0 then 0.0
            else safe_div (!up_s /. float_of_int !up_n) (!up_b /. float_of_int !up_n) in
          let down_capture =
            if !dn_n = 0 then 0.0
            else safe_div (!dn_s /. float_of_int !dn_n) (!dn_b /. float_of_int !dn_n) in
          let ann_return_s = ms *. periods_per_year in
          let rf_ann_equiv = rf_pp *. periods_per_year in
            ignore nf ;
            {
              n_periods = n;
              alpha_ann = alpha_pp *. periods_per_year;
              beta;
              r_squared;
              correlation;
              tracking_error_ann = te_ann;
              information_ratio = safe_div active_ann te_ann;
              active_return_ann = active_ann;
              up_capture;
              down_capture;
              capture_ratio = safe_div up_capture down_capture;
              treynor = safe_div (ann_return_s -. rf_ann_equiv) beta;
            }


let to_string t =
  Printf.sprintf
    "n=%d alpha=%.2f%%/yr beta=%.3f R2=%.3f corr=%.3f\n\
    \  TE=%.2f%% IR=%.3f active=%.2f%%/yr treynor=%.3f\n\
    \  up_capture=%.3f down_capture=%.3f ratio=%.3f"
    t.n_periods (t.alpha_ann *. 100.0) t.beta t.r_squared t.correlation
    (t.tracking_error_ann *. 100.0) t.information_ratio (t.active_return_ann *. 100.0) t.treynor
    t.up_capture t.down_capture t.capture_ratio
