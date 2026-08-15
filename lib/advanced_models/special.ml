let pi = 4.0 *. atan 1.0

let sqrt_2 = sqrt 2.0

let sqrt_2pi = sqrt (2.0 *. pi)

(* ─── erf, erfc — Abramowitz & Stegun 7.1.26 (max abs error ~1.5e-7) ─── *)

let erf x =
  let sign = if x < 0.0 then -1.0 else 1.0 in
  let ax = abs_float x in
  let p = 0.3275911 in
  let a1 = 0.254829592 in
  let a2 = -0.284496736 in
  let a3 = 1.421413741 in
  let a4 = -1.453152027 in
  let a5 = 1.061405429 in
  let t = 1.0 /. (1.0 +. (p *. ax)) in
  let t2 = t *. t in
  let t3 = t2 *. t in
  let t4 = t3 *. t in
  let t5 = t4 *. t in
  let poly = (a1 *. t) +. (a2 *. t2) +. (a3 *. t3) +. (a4 *. t4) +. (a5 *. t5) in
  let y = 1.0 -. (poly *. exp (-.ax *. ax)) in
    sign *. y


let erfc x = 1.0 -. erf x

let normal_cdf ~x = 0.5 *. erfc (-.x /. sqrt_2)

let normal_pdf ~x = exp (-.x *. x /. 2.0) /. sqrt_2pi

(* ─── normal_quantile — Beasley-Springer-Moro ─── *)

let normal_quantile ~p =
  if p <= 0.0 then neg_infinity
  else if p >= 1.0 then infinity
  else
    let a0 = -3.969683028665376e+01 in
    let a1 = 2.209460984245205e+02 in
    let a2 = -2.759285104469687e+02 in
    let a3 = 1.383577518672690e+02 in
    let a4 = -3.066479806614716e+01 in
    let a5 = 2.506628277459239e+00 in
    let b1 = -5.447609879822406e+01 in
    let b2 = 1.615858368580409e+02 in
    let b3 = -1.556989798598866e+02 in
    let b4 = 6.680131188771972e+01 in
    let b5 = -1.328068155288572e+01 in
    let c0 = -7.784894002430293e-03 in
    let c1 = -3.223964580411365e-01 in
    let c2 = -2.400758277161838e+00 in
    let c3 = -2.549732539343734e+00 in
    let c4 = 4.374664141464968e+00 in
    let c5 = 2.938163982698783e+00 in
    let d1 = 7.784695709041462e-03 in
    let d2 = 3.224671290700398e-01 in
    let d3 = 2.445134137142996e+00 in
    let d4 = 3.754408661907416e+00 in
    let plow = 0.02425 in
    let phigh = 1.0 -. plow in
      if p < plow then
        let q = sqrt (-2.0 *. log p) in
          ((((((((((c0 *. q) +. c1) *. q) +. c2) *. q) +. c3) *. q) +. c4) *. q) +. c5)
          /. ((((((((d1 *. q) +. d2) *. q) +. d3) *. q) +. d4) *. q) +. 1.0)
      else if p <= phigh then
        let q = p -. 0.5 in
        let r = q *. q in
          ((((((((((a0 *. r) +. a1) *. r) +. a2) *. r) +. a3) *. r) +. a4) *. r) +. a5)
          *. q
          /. ((((((((((b1 *. r) +. b2) *. r) +. b3) *. r) +. b4) *. r) +. b5) *. r) +. 1.0)
      else
        let q = sqrt (-2.0 *. log (1.0 -. p)) in
          -.((((((((((c0 *. q) +. c1) *. q) +. c2) *. q) +. c3) *. q) +. c4) *. q) +. c5)
          /. ((((((((d1 *. q) +. d2) *. q) +. d3) *. q) +. d4) *. q) +. 1.0)


(* ─── log_gamma — Lanczos approximation, g = 7 ─── *)

let lanczos_coeffs =
  [|
    0.99999999999980993;
    676.5203681218851;
    -1259.1392167224028;
    771.32342877765313;
    -176.61502916214059;
    12.507343278686905;
    -0.13857109526572012;
    9.9843695780195716e-6;
    1.5056327351493116e-7;
  |]


let rec log_gamma x =
  if x < 0.5 then log pi -. log (abs_float (sin (pi *. x))) -. log_gamma (1.0 -. x)
  else
    let x = x -. 1.0 in
    let a = ref lanczos_coeffs.(0) in
      for i = 1 to 8 do
        a := !a +. (lanczos_coeffs.(i) /. (x +. float_of_int i))
      done ;
      let g = 7.0 in
      let t = x +. g +. 0.5 in
        (0.5 *. log (2.0 *. pi)) +. ((x +. 0.5) *. log t) -. t +. log !a


(* ─── incomplete gamma — Press et al. Numerical Recipes §6.2 ─── *)

let gser ~s ~x =
  let max_iter = 200 in
  let eps = 3e-9 in
    if x <= 0.0 then 0.0
    else
      let ap = ref s in
      let sum = ref (1.0 /. s) in
      let del = ref !sum in
      let converged = ref false in
      let n = ref 1 in
        while (not !converged) && !n <= max_iter do
          ap := !ap +. 1.0 ;
          del := !del *. x /. !ap ;
          sum := !sum +. !del ;
          if abs_float !del < abs_float !sum *. eps then converged := true ;
          incr n
        done ;
        !sum *. exp (-.x +. (s *. log x) -. log_gamma s)


let gcf ~s ~x =
  let max_iter = 200 in
  let eps = 3e-9 in
  let fpmin = 1e-300 in
  let b = ref (x +. 1.0 -. s) in
  let c = ref (1.0 /. fpmin) in
  let d = ref (1.0 /. !b) in
  let h = ref !d in
  let converged = ref false in
  let i = ref 1 in
    while (not !converged) && !i <= max_iter do
      let i_f = float_of_int !i in
      let an = -.i_f *. (i_f -. s) in
        b := !b +. 2.0 ;
        d := (an *. !d) +. !b ;
        if abs_float !d < fpmin then d := fpmin ;
        c := !b +. (an /. !c) ;
        if abs_float !c < fpmin then c := fpmin ;
        d := 1.0 /. !d ;
        let del = !d *. !c in
          h := !h *. del ;
          if abs_float (del -. 1.0) < eps then converged := true ;
          incr i
    done ;
    exp (-.x +. (s *. log x) -. log_gamma s) *. !h


let incomplete_gamma_p ~s ~x =
  if x < 0.0 || s <= 0.0 then 0.0 else if x < s +. 1.0 then gser ~s ~x else 1.0 -. gcf ~s ~x


let incomplete_gamma_q ~s ~x = 1.0 -. incomplete_gamma_p ~s ~x

(* ─── regularized incomplete beta — Press §6.4 ─── *)

let betacf ~a ~b ~x =
  let max_iter = 200 in
  let eps = 3e-9 in
  let fpmin = 1e-300 in
  let qab = a +. b in
  let qap = a +. 1.0 in
  let qam = a -. 1.0 in
  let c = ref 1.0 in
  let d = ref (1.0 -. (qab *. x /. qap)) in
    if abs_float !d < fpmin then d := fpmin ;
    d := 1.0 /. !d ;
    let h = ref !d in
    let converged = ref false in
    let m = ref 1 in
      while (not !converged) && !m <= max_iter do
        let m2 = 2 * !m in
        let m_f = float_of_int !m in
        let m2_f = float_of_int m2 in
        let aa = m_f *. (b -. m_f) *. x /. ((qam +. m2_f) *. (a +. m2_f)) in
          d := 1.0 +. (aa *. !d) ;
          if abs_float !d < fpmin then d := fpmin ;
          c := 1.0 +. (aa /. !c) ;
          if abs_float !c < fpmin then c := fpmin ;
          d := 1.0 /. !d ;
          h := !h *. !d *. !c ;
          let aa = -.(a +. m_f) *. (qab +. m_f) *. x /. ((a +. m2_f) *. (qap +. m2_f)) in
            d := 1.0 +. (aa *. !d) ;
            if abs_float !d < fpmin then d := fpmin ;
            c := 1.0 +. (aa /. !c) ;
            if abs_float !c < fpmin then c := fpmin ;
            d := 1.0 /. !d ;
            let del = !d *. !c in
              h := !h *. del ;
              if abs_float (del -. 1.0) < eps then converged := true ;
              incr m
      done ;
      !h


let regularized_beta ~x ~a ~b =
  if x <= 0.0 then 0.0
  else if x >= 1.0 then 1.0
  else
    let bt =
      exp (log_gamma (a +. b) -. log_gamma a -. log_gamma b +. (a *. log x) +. (b *. log (1.0 -. x)))
    in
      if x < (a +. 1.0) /. (a +. b +. 2.0) then bt *. betacf ~a ~b ~x /. a
      else 1.0 -. (bt *. betacf ~a:b ~b:a ~x:(1.0 -. x) /. b)
