module Rng = Algostream_rng.Rng

let two_pi = 8.0 *. atan 1.0

(* Box-Muller, trigonometric form. [uniform_pos] is what keeps [log u1] finite — the defect in
   [Math_utils.FastRandom.normal_sample] is that it uses a uniform which can return exactly 0.0. *)
let normal_pair rng =
  let u1 = Rng.uniform_pos rng in
  let u2 = Rng.uniform_pos rng in
  let mag = sqrt (-2.0 *. log u1) in
  let angle = two_pi *. u2 in
    (mag *. cos angle, mag *. sin angle)


let normal rng =
  let z, _ = normal_pair rng in
    z


let gaussian rng ~mu ~sigma = mu +. (sigma *. normal rng)

let normal_array rng ~n =
  if n <= 0 then [||]
  else
    let a = Array.make n 0.0 in
    let i = ref 0 in
      while !i + 1 < n do
        let z0, z1 = normal_pair rng in
          a.(!i) <- z0 ;
          a.(!i + 1) <- z1 ;
          i := !i + 2
      done ;
      if !i < n then a.(!i) <- normal rng ;
      a


let exponential rng ~lambda =
  if lambda <= 0.0 then invalid_arg "Variate.exponential: lambda must be positive"
  else -.log (Rng.uniform_pos rng) /. lambda


(* Marsaglia & Tsang (2000). For shape >= 1 the squeeze accepts on the first try ~98% of the time.
   For shape < 1 the standard boost is Gamma(a) = Gamma(a+1) * U^(1/a). *)
let rec gamma rng ~shape ~scale =
  if shape <= 0.0 || scale <= 0.0 then invalid_arg "Variate.gamma: shape and scale must be positive"
  else if shape < 1.0 then
    let g = gamma rng ~shape:(shape +. 1.0) ~scale in
    let u = Rng.uniform_pos rng in
      g *. (u ** (1.0 /. shape))
  else
    let d = shape -. (1.0 /. 3.0) in
    let c = 1.0 /. sqrt (9.0 *. d) in
    let rec draw () =
      let x = normal rng in
      let v = 1.0 +. (c *. x) in
        if v <= 0.0 then draw ()
        else
          let v3 = v *. v *. v in
          let u = Rng.uniform_pos rng in
          let x2 = x *. x in
            (* Cheap squeeze first, exact log test only if it fails. *)
            if u < 1.0 -. (0.0331 *. x2 *. x2) then d *. v3 *. scale
            else if log u < (0.5 *. x2) +. (d *. (1.0 -. v3 +. log v3)) then d *. v3 *. scale
            else draw () in
      draw ()


let chi_squared rng ~df =
  if df <= 0.0 then invalid_arg "Variate.chi_squared: df must be positive"
  else gamma rng ~shape:(df /. 2.0) ~scale:2.0


let student_t rng ~df =
  if df <= 0.0 then invalid_arg "Variate.student_t: df must be positive"
  else
    let z = normal rng in
    let x = chi_squared rng ~df in
      z /. sqrt (x /. df)


let lognormal rng ~mu ~sigma = exp (mu +. (sigma *. normal rng))

let bernoulli rng ~p =
  let p = if p < 0.0 then 0.0 else if p > 1.0 then 1.0 else p in
    Rng.uniform rng < p


let poisson rng ~lambda =
  if lambda <= 0.0 then 0
  else if lambda < 30.0 then (
    (* Knuth: multiply uniforms until the product drops below e^-lambda. Expected iterations is
       lambda, which is why we switch above 30. *)
    let l = exp (-.lambda) in
    let k = ref 0 in
    let p = ref 1.0 in
      p := !p *. Rng.uniform_pos rng ;
      while !p > l do
        incr k ;
        p := !p *. Rng.uniform_pos rng
      done ;
      !k)
  else
    (* Normal approximation with continuity correction. Documented in the .mli — at lambda >= 30 the
       relative error on the mean and variance is well under a percent, and this library's stated
       precision contract is two significant figures. *)
    let z = normal rng in
    let x = lambda +. (sqrt lambda *. z) +. 0.5 in
      if x < 0.0 then 0 else int_of_float x


let multivariate_normal rng ~mean ~chol_lower =
  let n = Array.length mean in
    if Array.length chol_lower <> n then
      invalid_arg
        (Printf.sprintf "Variate.multivariate_normal: mean has length %d but chol_lower is %dx%d" n
           (Array.length chol_lower)
           (if Array.length chol_lower = 0 then 0 else Array.length chol_lower.(0))) ;
    let z = normal_array rng ~n in
    let lz = Cholesky.apply ~lower:chol_lower z in
      Array.init n (fun i -> mean.(i) +. lz.(i))


let choose_weighted rng ~weights =
  let n = Array.length weights in
    if n = 0 then invalid_arg "Variate.choose_weighted: empty weights" ;
    let total = ref 0.0 in
      Array.iter (fun w -> if w > 0.0 then total := !total +. w) weights ;
      if !total <= 0.0 then 0
      else
        let target = Rng.uniform rng *. !total in
        let acc = ref 0.0 in
        let chosen = ref (n - 1) in
        let i = ref 0 in
        let stop = ref false in
          while (not !stop) && !i < n do
            let w = if weights.(!i) > 0.0 then weights.(!i) else 0.0 in
              acc := !acc +. w ;
              if !acc > target then (
                chosen := !i ;
                stop := true) ;
              incr i
          done ;
          !chosen
