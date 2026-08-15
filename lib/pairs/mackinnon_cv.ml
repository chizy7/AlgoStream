(* MacKinnon (1996), "Numerical Distribution Functions for Unit Root and Cointegration Tests",
   Journal of Applied Econometrics 11(6), 601–618.

   Asymptotic (β_infinity) critical values from Tables 1 (unit root) and 2 (cointegration k=2).

   The pvalue interpolation is intentionally coarse — piecewise-linear between the published 1%, 5%,
   10% anchors with simple clamps outside that range. We do not claim precision beyond two
   significant figures. Strategies should treat the returned p-value as a coarse signal, not a
   research-grade statistic. *)

type variant =
  | No_constant
  | With_constant
  | With_trend

let unit_root_cv = function
  | No_constant -> (-2.5658, -1.9393, -1.6156)
  | With_constant -> (-3.4336, -2.8621, -2.5671)
  | With_trend -> (-3.9638, -3.4126, -3.1279)


let cointegration_k2_cv = (-3.9001, -3.3377, -3.0462)

(* ADF t-statistics are negative; more negative ⇒ stronger evidence of stationarity ⇒ smaller p. *)
let interp ~cv1 ~cv5 ~cv10 t =
  if t <= cv1 then 0.001
  else if t <= cv5 then
    let frac = (t -. cv1) /. (cv5 -. cv1) in
      0.01 +. (frac *. (0.05 -. 0.01))
  else if t <= cv10 then
    let frac = (t -. cv5) /. (cv10 -. cv5) in
      0.05 +. (frac *. (0.10 -. 0.05))
  else min 0.20 (0.10 +. ((t -. cv10) *. 0.05))


let pvalue variant ~t_stat =
  let cv1, cv5, cv10 = unit_root_cv variant in
    interp ~cv1 ~cv5 ~cv10 t_stat


let cointegration_pvalue ~t_stat =
  let cv1, cv5, cv10 = cointegration_k2_cv in
    interp ~cv1 ~cv5 ~cv10 t_stat
