open Algostream_advanced_models

let rosenbrock x =
  let a = 1.0 -. x.(0) in
  let b = x.(1) -. (x.(0) *. x.(0)) in
    (a *. a) +. (100.0 *. b *. b)


let sphere x = Array.fold_left (fun acc xi -> acc +. (xi *. xi)) 0.0 x

let test_rosenbrock () =
  let res =
    Nelder_mead.minimize ~f:rosenbrock ~x0:[| -1.2; 1.0 |]
      ~config:{ Nelder_mead.default_config with max_iter = 2000; tol_f = 1e-10 }
      () in
    Alcotest.(check bool)
      (Printf.sprintf "Rosenbrock x≈(1,1) got (%g, %g) f=%g iters=%d" res.x.(0) res.x.(1) res.f
         res.iter)
      true
      (abs_float (res.x.(0) -. 1.0) < 1e-2 && abs_float (res.x.(1) -. 1.0) < 1e-2)


let test_sphere () =
  let res = Nelder_mead.minimize ~f:sphere ~x0:[| 1.0; 1.0; 1.0 |] () in
    Alcotest.(check bool) (Printf.sprintf "Sphere ||x|| ≈ 0 got %g" res.f) true (res.f < 1e-6)


let test_quadratic_with_known_min () =
  (* f(x) = (x - 3)^2; min at x=3, f=0 *)
  let f x = (x.(0) -. 3.0) ** 2.0 in
  let res = Nelder_mead.minimize ~f ~x0:[| 0.0 |] () in
    Alcotest.(check (float 1e-3)) "min at x=3" 3.0 res.x.(0)


let suite =
  [
    Alcotest.test_case "rosenbrock" `Quick test_rosenbrock;
    Alcotest.test_case "sphere" `Quick test_sphere;
    Alcotest.test_case "quadratic_with_known_min" `Quick test_quadratic_with_known_min;
  ]
