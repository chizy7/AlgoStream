module Normal = Algostream_advanced_models.Distribution.Normal

(* Euler-Mascheroni; appears in the expected-maximum-of-n-Gaussians approximation. *)
let euler_gamma = 0.5772156649015329

let expected_max_sharpe ~n_trials ~trial_sharpe_stdev =
  let n = max 2 n_trials in
  let nf = float_of_int n in
  (* Bailey & Lopez de Prado: E[max] ≈ σ · [(1−γ)·Φ⁻¹(1 − 1/N) + γ·Φ⁻¹(1 − 1/(N·e))]. Two order
     statistics blended by γ — accurate to about 1% for N ≥ 10. *)
  let z1 = Normal.quantile ~p:(1.0 -. (1.0 /. nf)) in
  let z2 = Normal.quantile ~p:(1.0 -. (1.0 /. (nf *. Float.exp 1.0))) in
    trial_sharpe_stdev *. (((1.0 -. euler_gamma) *. z1) +. (euler_gamma *. z2))


let sharpe_standard_error ~sharpe ~skewness ~excess_kurtosis ~n_obs =
  let n = max 2 n_obs in
  let nf = float_of_int n in
  (* Lo (2002): non-normality inflates the uncertainty of a Sharpe estimate well beyond 1/sqrt(n).
     Negative skew and fat tails — exactly what trading strategies produce — make it worse. *)
  let v =
    (1.0 -. (skewness *. sharpe) +. (excess_kurtosis /. 4.0 *. sharpe *. sharpe)) /. (nf -. 1.0)
  in
    if v <= 0.0 then 0.0 else sqrt v


let deflated_sharpe_ratio ~observed_sharpe ~n_trials ~trial_sharpe_stdev ~skewness ~excess_kurtosis
  ~n_obs =
  let expected_max = expected_max_sharpe ~n_trials ~trial_sharpe_stdev in
  let se = sharpe_standard_error ~sharpe:observed_sharpe ~skewness ~excess_kurtosis ~n_obs in
    if se <= 0.0 then if observed_sharpe > expected_max then 1.0 else 0.0
    else Normal.cdf ~x:((observed_sharpe -. expected_max) /. se)


let probability_of_backtest_overfitting ~is_ranks ~oos_ranks =
  let n = min (Array.length is_ranks) (Array.length oos_ranks) in
    if n = 0 then 0.0
    else
      (* For each split, the configuration that won in-sample: did its out-of-sample rank land in
         the bottom half? The fraction that did is the PBO. *)
      let below = ref 0 in
        for i = 0 to n - 1 do
          if oos_ranks.(i) < 0.5 then incr below
        done ;
        float_of_int !below /. float_of_int n


let minimum_backtest_length ~target_sharpe ~n_trials =
  if target_sharpe <= 0.0 then infinity
  else
    let n = max 2 n_trials in
    let nf = float_of_int n in
    let z1 = Normal.quantile ~p:(1.0 -. (1.0 /. nf)) in
    let z2 = Normal.quantile ~p:(1.0 -. (1.0 /. (nf *. Float.exp 1.0))) in
    let e_max = ((1.0 -. euler_gamma) *. z1) +. (euler_gamma *. z2) in
    (* Years such that the target Sharpe clears the expected maximum from n_trials of noise. *)
    let ratio = e_max /. target_sharpe in
      ratio *. ratio


let haircut_sharpe ~observed_sharpe ~n_trials ~trial_sharpe_stdev =
  let e_max = expected_max_sharpe ~n_trials ~trial_sharpe_stdev in
  let h = observed_sharpe -. e_max in
    if h < 0.0 then 0.0 else h
