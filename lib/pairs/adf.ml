type variant = Config.adf_variant =
  | No_constant
  | With_constant
  | With_trend

type result = {
  t_stat : float;
  lag : int;
  n : int;
  p_value : float;
  variant : variant;
}

type error = [ `Insufficient_data of int * int ]

let empty_result = { t_stat = 0.0; lag = 0; n = 0; p_value = 1.0; variant = With_constant }

let schwert_lag ~n =
  if n <= 0 then 1
  else
    let raw = int_of_float (12.0 *. ((float_of_int n /. 100.0) ** 0.25)) in
      max 1 (min 4 raw)


(* Map our variant to MacKinnon's, which uses identical labels. *)
let mk_variant : variant -> Mackinnon_cv.variant = function
  | No_constant -> Mackinnon_cv.No_constant
  | With_constant -> Mackinnon_cv.With_constant
  | With_trend -> Mackinnon_cv.With_trend


let test ?(variant = With_constant) ?(lag = 1) series =
  let nseries = Array.length series in
  let n_obs = nseries - lag - 1 in
  let n_intercept = match variant with No_constant -> 0 | _ -> 1 in
  let n_trend = match variant with With_trend -> 1 | _ -> 0 in
  let p = 1 + lag + n_intercept + n_trend in
  let need = p + 4 in
    if n_obs < need then Error (`Insufficient_data (n_obs, need))
    else
      let x = Array.make_matrix n_obs p 0.0 in
      let y = Array.make n_obs 0.0 in
      let intercept_col = if n_intercept = 1 then 0 else -1 in
      let trend_col = if n_trend = 1 then n_intercept else -1 in
      let level_col = n_intercept + n_trend in
      let lag_col0 = level_col + 1 in
        for t = 0 to n_obs - 1 do
          let row_idx = t + lag + 1 in
            y.(t) <- series.(row_idx) -. series.(row_idx - 1) ;
            if intercept_col >= 0 then x.(t).(intercept_col) <- 1.0 ;
            if trend_col >= 0 then x.(t).(trend_col) <- float_of_int row_idx ;
            x.(t).(level_col) <- series.(row_idx - 1) ;
            for i = 0 to lag - 1 do
              let li = row_idx - 1 - i in
                x.(t).(lag_col0 + i) <- series.(li) -. series.(li - 1)
            done
        done ;
        match Ols.solve ~x ~y ~p with
        | Error _ -> Error (`Insufficient_data (n_obs, need))
        | Ok fit ->
          let rho_hat = fit.beta.(level_col) in
          let se_rho = fit.se.(level_col) in
          let t_stat = if se_rho > 1e-15 then rho_hat /. se_rho else 0.0 in
          let p_value = Mackinnon_cv.pvalue (mk_variant variant) ~t_stat in
            Ok { t_stat; lag; n = n_obs; p_value; variant }
