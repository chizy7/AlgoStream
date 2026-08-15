module Normal = Algostream_advanced_models.Distribution.Normal

let of_sorted ~sorted ~p =
  let n = Array.length sorted in
    if n = 0 then invalid_arg "Quantile.of_sorted: empty sample" ;
    let p = if p < 0.0 then 0.0 else if p > 1.0 then 1.0 else p in
      if n = 1 then sorted.(0)
      else
        (* Type 7: h = (n - 1) * p, then linear interpolation between floor(h) and ceil(h). *)
        let h = float_of_int (n - 1) *. p in
        let lo = int_of_float (Float.floor h) in
        let hi = if lo + 1 >= n then n - 1 else lo + 1 in
        let frac = h -. float_of_int lo in
          sorted.(lo) +. (frac *. (sorted.(hi) -. sorted.(lo)))


let sorted_copy a =
  let c = Array.copy a in
    Array.sort Float.compare c ;
    c


let quantile a ~p = of_sorted ~sorted:(sorted_copy a) ~p

let median a = quantile a ~p:0.5

let tail_of_level level =
  let level = if level <= 0.0 then 0.95 else if level >= 1.0 then 0.99 else level in
  let alpha = 1.0 -. level in
    (alpha /. 2.0, 1.0 -. (alpha /. 2.0))


let percentile_interval a ~level =
  let sorted = sorted_copy a in
  let lo_p, hi_p = tail_of_level level in
    (of_sorted ~sorted ~p:lo_p, of_sorted ~sorted ~p:hi_p)


let basic_interval a ~point_estimate ~level =
  let lo, hi = percentile_interval a ~level in
    ((2.0 *. point_estimate) -. hi, (2.0 *. point_estimate) -. lo)


let mean_of a =
  let n = Array.length a in
    if n = 0 then 0.0
    else
      let s = Array.fold_left ( +. ) 0.0 a in
        s /. float_of_int n


let bca a ~point_estimate ~jackknife ~level =
  let n = Array.length a in
    if n < 2 then percentile_interval a ~level
    else
      let sorted = sorted_copy a in
      (* Bias correction z0: how far the bootstrap median sits from the point estimate, in normal
         quantile units. *)
      let below = Array.fold_left (fun acc x -> if x < point_estimate then acc + 1 else acc) 0 a in
      let prop = float_of_int below /. float_of_int n in
        if prop <= 0.0 || prop >= 1.0 then percentile_interval a ~level
        else
          let z0 = Normal.quantile ~p:prop in
          (* Acceleration from the jackknife skewness. *)
          let jn = Array.length jackknife in
            if jn < 2 then percentile_interval a ~level
            else
              let jbar = mean_of jackknife in
              let num = ref 0.0 and den = ref 0.0 in
                Array.iter
                  (fun j ->
                    let d = jbar -. j in
                      num := !num +. (d *. d *. d) ;
                      den := !den +. (d *. d))
                  jackknife ;
                let den_pow = !den ** 1.5 in
                let acc = if den_pow <= 0.0 then 0.0 else !num /. (6.0 *. den_pow) in
                let lo_p, hi_p = tail_of_level level in
                let adjust p =
                  let z = Normal.quantile ~p in
                  let zz = z0 +. z in
                  let denom = 1.0 -. (acc *. zz) in
                    if Float.abs denom < 1e-12 then p
                    else
                      let adj = z0 +. (zz /. denom) in
                      let q = Normal.cdf ~x:adj in
                        if q < 0.0 then 0.0 else if q > 1.0 then 1.0 else q in
                  (of_sorted ~sorted ~p:(adjust lo_p), of_sorted ~sorted ~p:(adjust hi_p))


let mc_standard_error a ~p =
  let n = Array.length a in
    if n < 3 then 0.0
    else
      let sorted = sorted_copy a in
      let p = if p < 0.0 then 0.0 else if p > 1.0 then 1.0 else p in
      (* Estimate the density at q_p by a symmetric finite difference of the empirical quantile
         function; h shrinks with n so the estimate stays local as the sample grows. *)
      let h = Float.max (1.0 /. float_of_int n) 0.01 in
      let lo = of_sorted ~sorted ~p:(Float.max 0.0 (p -. h)) in
      let hi = of_sorted ~sorted ~p:(Float.min 1.0 (p +. h)) in
      let dq = hi -. lo in
        if Float.abs dq < 1e-15 then 0.0
        else
          let density = (Float.min 1.0 (p +. h) -. Float.max 0.0 (p -. h)) /. dq in
            if density <= 0.0 then 0.0 else sqrt (p *. (1.0 -. p) /. float_of_int n) /. density


type summary = {
  n : int;
  mean : float;
  stddev : float;
  min : float;
  max : float;
  p01 : float;
  p05 : float;
  p25 : float;
  p50 : float;
  p75 : float;
  p95 : float;
  p99 : float;
  ci95_lo : float;
  ci95_hi : float;
  ci99_lo : float;
  ci99_hi : float;
  prob_negative : float;
  skewness : float;
  excess_kurtosis : float;
  mc_se_p05 : float;
  mc_se_p95 : float;
}

let empty_summary =
  {
    n = 0;
    mean = 0.0;
    stddev = 0.0;
    min = 0.0;
    max = 0.0;
    p01 = 0.0;
    p05 = 0.0;
    p25 = 0.0;
    p50 = 0.0;
    p75 = 0.0;
    p95 = 0.0;
    p99 = 0.0;
    ci95_lo = 0.0;
    ci95_hi = 0.0;
    ci99_lo = 0.0;
    ci99_hi = 0.0;
    prob_negative = 0.0;
    skewness = 0.0;
    excess_kurtosis = 0.0;
    mc_se_p05 = 0.0;
    mc_se_p95 = 0.0;
  }


let summarize a =
  let n = Array.length a in
    if n = 0 then empty_summary
    else
      let sorted = sorted_copy a in
      let nf = float_of_int n in
      let mean = mean_of a in
      let m2 = ref 0.0 and m3 = ref 0.0 and m4 = ref 0.0 and neg = ref 0 in
        Array.iter
          (fun x ->
            let d = x -. mean in
            let d2 = d *. d in
              m2 := !m2 +. d2 ;
              m3 := !m3 +. (d2 *. d) ;
              m4 := !m4 +. (d2 *. d2) ;
              if x < 0.0 then incr neg)
          a ;
        (* Sample stddev (n-1); the moment ratios use the population (n) form, which is the
           convention Jarque-Bera and Hypothesis_test.jarque_bera assume. *)
        let var_sample = if n > 1 then !m2 /. (nf -. 1.0) else 0.0 in
        let stddev = sqrt var_sample in
        let var_pop = !m2 /. nf in
        let sd_pop = sqrt var_pop in
        let skewness = if sd_pop <= 0.0 then 0.0 else !m3 /. nf /. (sd_pop ** 3.0) in
        let excess_kurtosis =
          if var_pop <= 0.0 then 0.0 else (!m4 /. nf /. (var_pop *. var_pop)) -. 3.0 in
        let ci95_lo, ci95_hi = (of_sorted ~sorted ~p:0.025, of_sorted ~sorted ~p:0.975) in
        let ci99_lo, ci99_hi = (of_sorted ~sorted ~p:0.005, of_sorted ~sorted ~p:0.995) in
          {
            n;
            mean;
            stddev;
            min = sorted.(0);
            max = sorted.(n - 1);
            p01 = of_sorted ~sorted ~p:0.01;
            p05 = of_sorted ~sorted ~p:0.05;
            p25 = of_sorted ~sorted ~p:0.25;
            p50 = of_sorted ~sorted ~p:0.50;
            p75 = of_sorted ~sorted ~p:0.75;
            p95 = of_sorted ~sorted ~p:0.95;
            p99 = of_sorted ~sorted ~p:0.99;
            ci95_lo;
            ci95_hi;
            ci99_lo;
            ci99_hi;
            prob_negative = float_of_int !neg /. nf;
            skewness;
            excess_kurtosis;
            mc_se_p05 = mc_standard_error a ~p:0.05;
            mc_se_p95 = mc_standard_error a ~p:0.95;
          }


let summary_to_string s =
  Printf.sprintf
    "n=%d mean=%.6g sd=%.6g min=%.6g max=%.6g\n\
    \  p01=%.6g p05=%.6g p25=%.6g p50=%.6g p75=%.6g p95=%.6g p99=%.6g\n\
    \  ci95=[%.6g, %.6g] ci99=[%.6g, %.6g]\n\
    \  P(<0)=%.4f skew=%.4g exkurt=%.4g mc_se(p05)=%.4g mc_se(p95)=%.4g"
    s.n s.mean s.stddev s.min s.max s.p01 s.p05 s.p25 s.p50 s.p75 s.p95 s.p99 s.ci95_lo s.ci95_hi
    s.ci99_lo s.ci99_hi s.prob_negative s.skewness s.excess_kurtosis s.mc_se_p05 s.mc_se_p95
