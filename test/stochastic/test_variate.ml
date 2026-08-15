module Variate = Algostream_stochastic.Variate
module Cholesky = Algostream_stochastic.Cholesky
module Rng = Algostream_rng.Rng
module Distribution = Algostream_advanced_models.Distribution
module Hypothesis_test = Algostream_advanced_models.Hypothesis_test

let mean a = Array.fold_left ( +. ) 0.0 a /. float_of_int (Array.length a)

let variance a =
  let m = mean a in
  let n = Array.length a in
    Array.fold_left (fun s x -> s +. ((x -. m) *. (x -. m))) 0.0 a /. float_of_int (n - 1)


let sample n f = Array.init n (fun _ -> f ())

(* KS against the exact normal CDF — the strongest available statement that the sampler is right. *)
let test_normal_passes_ks () =
  let rng = Rng.create ~seed:1 in
  let s = sample 20_000 (fun () -> Variate.normal rng) in
  let ks = Hypothesis_test.ks_one_sample ~sample:s ~cdf:(fun x -> Distribution.Normal.cdf ~x) in
    Alcotest.(check bool)
      (Printf.sprintf "KS p=%.4f does not reject standard normal" ks.Hypothesis_test.p_value)
      true
      (ks.Hypothesis_test.p_value > 0.01)


let test_normal_passes_jarque_bera () =
  let rng = Rng.create ~seed:2 in
  let s = sample 20_000 (fun () -> Variate.normal rng) in
  let jb = Hypothesis_test.jarque_bera ~sample:s in
    Alcotest.(check bool)
      (Printf.sprintf "Jarque-Bera p=%.4f does not reject normality" jb.Hypothesis_test.p_value)
      true
      (jb.Hypothesis_test.p_value > 0.01)


let test_normal_moments () =
  let rng = Rng.create ~seed:3 in
  let s = sample 200_000 (fun () -> Variate.normal rng) in
    Alcotest.(check bool) (Printf.sprintf "mean %.5f ~ 0" (mean s)) true (Float.abs (mean s) < 0.01) ;
    Alcotest.(check bool)
      (Printf.sprintf "variance %.5f ~ 1" (variance s))
      true
      (Float.abs (variance s -. 1.0) < 0.02)


(* Never nan: the defect in Math_utils.FastRandom.normal_sample is an unclamped log of a uniform
   that can be exactly zero. *)
let test_normal_is_never_nan () =
  let rng = Rng.create ~seed:4 in
  let bad = ref 0 in
    for _ = 1 to 2_000_000 do
      let z = Variate.normal rng in
        if Float.is_nan z || not (Float.is_finite z) then incr bad
    done ;
    Alcotest.(check int) "two million draws, none nan or infinite" 0 !bad


let test_normal_pair_is_independent () =
  let rng = Rng.create ~seed:5 in
  let n = 50_000 in
  let xs = Array.make n 0.0 and ys = Array.make n 0.0 in
    for i = 0 to n - 1 do
      let a, b = Variate.normal_pair rng in
        xs.(i) <- a ;
        ys.(i) <- b
    done ;
    let mx = mean xs and my = mean ys in
    let sxy = ref 0.0 and sxx = ref 0.0 and syy = ref 0.0 in
      for i = 0 to n - 1 do
        let dx = xs.(i) -. mx and dy = ys.(i) -. my in
          sxy := !sxy +. (dx *. dy) ;
          sxx := !sxx +. (dx *. dx) ;
          syy := !syy +. (dy *. dy)
      done ;
      let corr = !sxy /. sqrt (!sxx *. !syy) in
        Alcotest.(check bool)
          (Printf.sprintf "the two Box-Muller branches are uncorrelated (%.5f)" corr)
          true
          (Float.abs corr < 0.02)


let test_gaussian_scales () =
  let rng = Rng.create ~seed:6 in
  let s = sample 100_000 (fun () -> Variate.gaussian rng ~mu:5.0 ~sigma:2.0) in
    Alcotest.(check bool)
      (Printf.sprintf "mean %.4f ~ 5" (mean s))
      true
      (Float.abs (mean s -. 5.0) < 0.05) ;
    Alcotest.(check bool)
      (Printf.sprintf "sd %.4f ~ 2" (sqrt (variance s)))
      true
      (Float.abs (sqrt (variance s) -. 2.0) < 0.05)


let test_exponential_moments () =
  let rng = Rng.create ~seed:7 in
  let lambda = 2.5 in
  let s = sample 200_000 (fun () -> Variate.exponential rng ~lambda) in
    (* mean = 1/lambda, variance = 1/lambda^2 *)
    Alcotest.(check bool)
      (Printf.sprintf "mean %.5f ~ %.5f" (mean s) (1.0 /. lambda))
      true
      (Float.abs (mean s -. (1.0 /. lambda)) < 0.01) ;
    Alcotest.(check bool) "all draws are positive" true (Array.for_all (fun x -> x > 0.0) s)


let test_gamma_moments () =
  let rng = Rng.create ~seed:8 in
  let shape = 3.0 and scale = 2.0 in
  let s = sample 200_000 (fun () -> Variate.gamma rng ~shape ~scale) in
    (* mean = shape*scale = 6, variance = shape*scale^2 = 12 *)
    Alcotest.(check bool)
      (Printf.sprintf "mean %.4f ~ 6" (mean s))
      true
      (Float.abs (mean s -. 6.0) < 0.1) ;
    Alcotest.(check bool)
      (Printf.sprintf "variance %.4f ~ 12" (variance s))
      true
      (Float.abs (variance s -. 12.0) < 0.5)


(* shape < 1 takes the Johnk boost path, which is easy to get wrong. *)
let test_gamma_small_shape () =
  let rng = Rng.create ~seed:9 in
  let shape = 0.4 and scale = 1.0 in
  let s = sample 200_000 (fun () -> Variate.gamma rng ~shape ~scale) in
    Alcotest.(check bool)
      (Printf.sprintf "mean %.4f ~ 0.4 on the shape<1 branch" (mean s))
      true
      (Float.abs (mean s -. 0.4) < 0.02) ;
    Alcotest.(check bool) "all draws positive" true (Array.for_all (fun x -> x > 0.0) s)


let test_chi_squared_moments () =
  let rng = Rng.create ~seed:10 in
  let df = 5.0 in
  let s = sample 200_000 (fun () -> Variate.chi_squared rng ~df) in
    Alcotest.(check bool)
      (Printf.sprintf "mean %.4f ~ df=5" (mean s))
      true
      (Float.abs (mean s -. 5.0) < 0.1) ;
    Alcotest.(check bool)
      (Printf.sprintf "variance %.4f ~ 2df=10" (variance s))
      true
      (Float.abs (variance s -. 10.0) < 0.5)


let test_student_t_has_fatter_tails_than_normal () =
  let rng = Rng.create ~seed:11 in
  let t = sample 100_000 (fun () -> Variate.student_t rng ~df:4.0) in
  let kurt a =
    let m = mean a and s = sqrt (variance a) in
      Array.fold_left (fun acc x -> acc +. (((x -. m) /. s) ** 4.0)) 0.0 a
      /. float_of_int (Array.length a)
      -. 3.0 in
    Alcotest.(check bool)
      (Printf.sprintf "t(4) excess kurtosis %.2f is well above the normal's 0" (kurt t))
      true
      (kurt t > 1.0)


let test_lognormal_is_positive () =
  let rng = Rng.create ~seed:12 in
  let s = sample 50_000 (fun () -> Variate.lognormal rng ~mu:0.0 ~sigma:0.5) in
    Alcotest.(check bool) "every draw is positive" true (Array.for_all (fun x -> x > 0.0) s) ;
    (* median of lognormal(0, sigma) is exp(0) = 1 *)
    let sorted = Array.copy s in
      Array.sort compare sorted ;
      let med = sorted.(Array.length sorted / 2) in
        Alcotest.(check bool)
          (Printf.sprintf "median %.4f ~ 1" med)
          true
          (Float.abs (med -. 1.0) < 0.03)


let test_bernoulli_rate () =
  let rng = Rng.create ~seed:13 in
  let n = 200_000 in
  let hits = ref 0 in
    for _ = 1 to n do
      if Variate.bernoulli rng ~p:0.3 then incr hits
    done ;
    let rate = float_of_int !hits /. float_of_int n in
      Alcotest.(check bool)
        (Printf.sprintf "rate %.4f ~ 0.3" rate)
        true
        (Float.abs (rate -. 0.3) < 0.01) ;
      Alcotest.(check bool) "p=0 never fires" false (Variate.bernoulli rng ~p:0.0) ;
      Alcotest.(check bool) "p=1 always fires" true (Variate.bernoulli rng ~p:1.0)


let test_poisson_moments () =
  let rng = Rng.create ~seed:14 in
  (* Below 30 takes Knuth's exact method. *)
  let small = Array.map float_of_int (sample 200_000 (fun () -> Variate.poisson rng ~lambda:4.0)) in
    Alcotest.(check bool)
      (Printf.sprintf "Knuth branch mean %.4f ~ 4" (mean small))
      true
      (Float.abs (mean small -. 4.0) < 0.05) ;
    Alcotest.(check bool)
      (Printf.sprintf "Knuth branch variance %.4f ~ 4" (variance small))
      true
      (Float.abs (variance small -. 4.0) < 0.1) ;
    (* Above 30 takes the documented normal approximation. *)
    let big =
      Array.map float_of_int (sample 200_000 (fun () -> Variate.poisson rng ~lambda:100.0)) in
      Alcotest.(check bool)
        (Printf.sprintf "normal-approximation branch mean %.3f ~ 100" (mean big))
        true
        (Float.abs (mean big -. 100.0) < 1.0)


let test_multivariate_normal_recovers_covariance () =
  let rng = Rng.create ~seed:15 in
  let cov = [| [| 4.0; 1.2 |]; [| 1.2; 1.0 |] |] in
    match Cholesky.factor cov with
    | Error _ -> Alcotest.fail "factorization failed on a valid covariance"
    | Ok lower ->
      let n = 200_000 in
      let xs = Array.make n 0.0 and ys = Array.make n 0.0 in
        for i = 0 to n - 1 do
          let v = Variate.multivariate_normal rng ~mean:[| 0.0; 0.0 |] ~chol_lower:lower in
            xs.(i) <- v.(0) ;
            ys.(i) <- v.(1)
        done ;
        Alcotest.(check bool)
          (Printf.sprintf "var(x) %.4f ~ 4" (variance xs))
          true
          (Float.abs (variance xs -. 4.0) < 0.1) ;
        Alcotest.(check bool)
          (Printf.sprintf "var(y) %.4f ~ 1" (variance ys))
          true
          (Float.abs (variance ys -. 1.0) < 0.05) ;
        let mx = mean xs and my = mean ys in
        let c = ref 0.0 in
          for i = 0 to n - 1 do
            c := !c +. ((xs.(i) -. mx) *. (ys.(i) -. my))
          done ;
          let cxy = !c /. float_of_int (n - 1) in
            Alcotest.(check bool)
              (Printf.sprintf "cov(x,y) %.4f ~ 1.2" cxy)
              true
              (Float.abs (cxy -. 1.2) < 0.05)


let test_choose_weighted_respects_weights () =
  let rng = Rng.create ~seed:16 in
  let weights = [| 1.0; 3.0; 0.0; 6.0 |] in
  let n = 200_000 in
  let counts = Array.make 4 0 in
    for _ = 1 to n do
      let i = Variate.choose_weighted rng ~weights in
        counts.(i) <- counts.(i) + 1
    done ;
    Alcotest.(check int) "a zero-weight option is never chosen" 0 counts.(2) ;
    let share i = float_of_int counts.(i) /. float_of_int n in
      Alcotest.(check bool)
        (Printf.sprintf "share[0] %.4f ~ 0.1" (share 0))
        true
        (Float.abs (share 0 -. 0.1) < 0.01) ;
      Alcotest.(check bool)
        (Printf.sprintf "share[1] %.4f ~ 0.3" (share 1))
        true
        (Float.abs (share 1 -. 0.3) < 0.01) ;
      Alcotest.(check bool)
        (Printf.sprintf "share[3] %.4f ~ 0.6" (share 3))
        true
        (Float.abs (share 3 -. 0.6) < 0.01)


let test_invalid_arguments_raise () =
  let rng = Rng.create ~seed:17 in
    Alcotest.check_raises "gamma with shape 0"
      (Invalid_argument "Variate.gamma: shape and scale must be positive") (fun () ->
      ignore (Variate.gamma rng ~shape:0.0 ~scale:1.0)) ;
    Alcotest.check_raises "exponential with lambda 0"
      (Invalid_argument "Variate.exponential: lambda must be positive") (fun () ->
      ignore (Variate.exponential rng ~lambda:0.0))


let suite =
  [
    Alcotest.test_case "normal_passes_ks" `Quick test_normal_passes_ks;
    Alcotest.test_case "normal_passes_jarque_bera" `Quick test_normal_passes_jarque_bera;
    Alcotest.test_case "normal_moments" `Quick test_normal_moments;
    Alcotest.test_case "normal_is_never_nan" `Quick test_normal_is_never_nan;
    Alcotest.test_case "normal_pair_is_independent" `Quick test_normal_pair_is_independent;
    Alcotest.test_case "gaussian_scales" `Quick test_gaussian_scales;
    Alcotest.test_case "exponential_moments" `Quick test_exponential_moments;
    Alcotest.test_case "gamma_moments" `Quick test_gamma_moments;
    Alcotest.test_case "gamma_small_shape" `Quick test_gamma_small_shape;
    Alcotest.test_case "chi_squared_moments" `Quick test_chi_squared_moments;
    Alcotest.test_case "student_t_has_fatter_tails_than_normal" `Quick
      test_student_t_has_fatter_tails_than_normal;
    Alcotest.test_case "lognormal_is_positive" `Quick test_lognormal_is_positive;
    Alcotest.test_case "bernoulli_rate" `Quick test_bernoulli_rate;
    Alcotest.test_case "poisson_moments" `Quick test_poisson_moments;
    Alcotest.test_case "multivariate_normal_recovers_covariance" `Quick
      test_multivariate_normal_recovers_covariance;
    Alcotest.test_case "choose_weighted_respects_weights" `Quick
      test_choose_weighted_respects_weights;
    Alcotest.test_case "invalid_arguments_raise" `Quick test_invalid_arguments_raise;
  ]
