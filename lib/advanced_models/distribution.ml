module Normal = struct
  let cdf ~x = Special.normal_cdf ~x

  let pdf ~x = Special.normal_pdf ~x

  let quantile ~p = Special.normal_quantile ~p
end

module Student_t = struct
  (* P(T ≤ x) where T ~ t(df). Uses I_y(df/2, 1/2) with y = df / (df + x²). *)
  let cdf ~x ~df =
    if df <= 0.0 then 0.5
    else
      let y = df /. (df +. (x *. x)) in
      let ib = Special.regularized_beta ~x:y ~a:(df /. 2.0) ~b:0.5 in
        if x >= 0.0 then 1.0 -. (0.5 *. ib) else 0.5 *. ib


  let pdf ~x ~df =
    let log_norm =
      Special.log_gamma ((df +. 1.0) /. 2.0)
      -. Special.log_gamma (df /. 2.0)
      -. (0.5 *. log (df *. Float.pi)) in
      exp (log_norm -. ((df +. 1.0) /. 2.0 *. log (1.0 +. (x *. x /. df))))
end

module Chi_squared = struct
  let cdf ~x ~df = if x <= 0.0 then 0.0 else Special.incomplete_gamma_p ~s:(df /. 2.0) ~x:(x /. 2.0)
end

module F = struct
  let cdf ~x ~d1 ~d2 =
    if x <= 0.0 then 0.0
    else
      let y = d1 *. x /. ((d1 *. x) +. d2) in
        Special.regularized_beta ~x:y ~a:(d1 /. 2.0) ~b:(d2 /. 2.0)
end
