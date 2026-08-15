module Engle_granger = struct
  type result = {
    beta : float;
    intercept : float;
    residuals : float array;
    residual_adf : Adf.result;
    cointegrated : bool;
  }

  type error =
    [ Adf.error
    | `Length_mismatch
    | `Ols of Ols.error
    ]

  let test ~y ~x ?(signif = 0.05) ?(adf_variant = Adf.No_constant) ?(adf_lag = 1) () =
    let n = Array.length y in
      if Array.length x <> n then Error `Length_mismatch
      else
        match Ols.regress2 ~x ~y with
        | Error e -> Error (`Ols e)
        | Ok (intercept, beta, _r2) ->
          let residuals = Array.make n 0.0 in
            for i = 0 to n - 1 do
              residuals.(i) <- y.(i) -. (beta *. x.(i)) -. intercept
            done ;
            (* Cointegration test uses MacKinnon's k=2 critical values, not the standard ADF
               unit-root values. Adf.test returns the t-stat from the standard regression; we
               override its p-value with the cointegration table here. *)
            (match Adf.test ~variant:adf_variant ~lag:adf_lag residuals with
            | Error e -> Error (e :> error)
            | Ok r ->
              let coint_p = Mackinnon_cv.cointegration_pvalue ~t_stat:r.t_stat in
              let r' = { r with p_value = coint_p } in
              let cointegrated = coint_p < signif && abs_float beta > 1e-9 in
                Ok { beta; intercept; residuals; residual_adf = r'; cointegrated })
end

module Johansen = struct
  type result = {
    trace_stats : float array;
    max_eig_stats : float array;
    rank : int;
  }

  let test _ = Error `Not_supported_in_v1
end
