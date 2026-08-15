module Ols = Algostream_pairs.Ols
module Rng = Algostream_rng.Rng

type params = {
  theta : float;
  mu : float;
  sigma : float;
}

type fit_result = {
  params : params;
  half_life : float;
  rss : float;
  tss : float;
  n : int;
}

type fit_error =
  [ `Insufficient_data of int * int
  | `Non_reverting
  | `Ols of Ols.error
  ]

let fit ~series ~dt =
  let n = Array.length series in
  let need = 8 in
    if n < need then Error (`Insufficient_data (n, need))
    else
      let m = n - 1 in
      let x = Array.make m 0.0 in
      let y = Array.make m 0.0 in
        for i = 0 to m - 1 do
          x.(i) <- series.(i) ;
          y.(i) <- series.(i + 1)
        done ;
        match Ols.regress2 ~x ~y with
        | Error e -> Error (`Ols e)
        | Ok (a, b, _r2) ->
          if b <= 0.0 || b >= 1.0 then Error `Non_reverting
          else
            let theta = -.log b /. dt in
            let mu = a /. (1.0 -. b) in
            let rss = ref 0.0 in
            let tss = ref 0.0 in
            let mean_y = ref 0.0 in
              for i = 0 to m - 1 do
                mean_y := !mean_y +. y.(i)
              done ;
              let my = !mean_y /. float_of_int m in
                for i = 0 to m - 1 do
                  let pred = a +. (b *. x.(i)) in
                  let r = y.(i) -. pred in
                    rss := !rss +. (r *. r) ;
                    let d = y.(i) -. my in
                      tss := !tss +. (d *. d)
                done ;
                let var_eps = if m > 2 then !rss /. float_of_int (m - 2) else !rss in
                let factor = (1.0 -. exp (-2.0 *. theta *. dt)) /. (2.0 *. theta) in
                let sigma = if factor > 0.0 then sqrt (var_eps /. factor) else 0.0 in
                let half_life = log 2.0 /. theta in
                  Ok { params = { theta; mu; sigma }; half_life; rss = !rss; tss = !tss; n = m }


let expected_value p ~r0 ~t = p.mu +. ((r0 -. p.mu) *. exp (-.p.theta *. t))

let expected_variance p ~t =
  if p.theta <= 0.0 then p.sigma *. p.sigma *. t
  else p.sigma *. p.sigma *. (1.0 -. exp (-2.0 *. p.theta *. t)) /. (2.0 *. p.theta)


(* Box-Muller over [Rng.uniform_pos], inlined rather than calling [Stochastic.Variate.normal].
   [algostream.stochastic] depends on this library (its [Quantile.bca] needs [Distribution.Normal]),
   so depending on it from here would close a cycle. Four lines of a textbook transform is the
   cheaper of the two prices. [uniform_pos] never returns 0.0, so [log] is always finite — the
   defect that makes [Math_utils.FastRandom.normal_sample] emit [nan]. *)
let two_pi = 8.0 *. atan 1.0

let standard_normal rng =
  let u1 = Rng.uniform_pos rng in
  let u2 = Rng.uniform_pos rng in
    sqrt (-2.0 *. log u1) *. cos (two_pi *. u2)


let simulate_with p ~rng ~n ~dt ~r0 =
  let out = Array.make n 0.0 in
  let decay = exp (-.p.theta *. dt) in
  let cond_var =
    if p.theta <= 0.0 then p.sigma *. p.sigma *. dt
    else p.sigma *. p.sigma *. (1.0 -. exp (-2.0 *. p.theta *. dt)) /. (2.0 *. p.theta) in
  let cond_sd = sqrt (max 0.0 cond_var) in
  let prev = ref r0 in
    for i = 0 to n - 1 do
      let z = standard_normal rng in
      let next = p.mu +. ((!prev -. p.mu) *. decay) +. (cond_sd *. z) in
        out.(i) <- next ;
        prev := next
    done ;
    out


let simulate p ~n ~dt ~seed ~r0 = simulate_with p ~rng:(Rng.create ~seed) ~n ~dt ~r0
