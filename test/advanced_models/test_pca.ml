open Algostream_advanced_models

let test_one_dim_line () =
  (* Data along y = 2x + small noise: first PC should be ~ (1, 2)/sqrt(5) *)
  let rng = Random.State.make [| 91 |] in
  let n = 500 in
  let data = Array.make_matrix n 2 0.0 in
    for i = 0 to n - 1 do
      let t = Random.State.float rng 10.0 -. 5.0 in
        data.(i).(0) <- t +. (0.01 *. Helpers.normal_sample rng) ;
        data.(i).(1) <- (2.0 *. t) +. (0.01 *. Helpers.normal_sample rng)
    done ;
    let pca = Pca.fit ~data () in
    let ratio = Pca.explained_variance_ratio pca in
      Alcotest.(check bool)
        (Printf.sprintf "first PC explains >0.95 (got %g)" ratio.(0))
        true
        (ratio.(0) > 0.95) ;
      (* First component direction should be parallel to (1, 2) *)
      let comp = Pca.components pca in
      let v0 = comp.(0).(0) in
      let v1 = comp.(0).(1) in
      let norm = sqrt ((v0 *. v0) +. (v1 *. v1)) in
      let expected_x = 1.0 /. sqrt 5.0 in
      let expected_y = 2.0 /. sqrt 5.0 in
      let dot = (v0 /. norm *. expected_x) +. (v1 /. norm *. expected_y) in
        Alcotest.(check bool)
          (Printf.sprintf "PC aligned with (1,2)/√5, |dot|=%g" (abs_float dot))
          true
          (abs_float dot > 0.99)


let test_isotropic_noise () =
  (* IID N(0,1) in 3D — explained variances should be roughly equal *)
  let rng = Random.State.make [| 92 |] in
  let n = 800 in
  let data = Array.init n (fun _ -> Array.init 3 (fun _ -> Helpers.normal_sample rng)) in
  let pca = Pca.fit ~data () in
  let ratio = Pca.explained_variance_ratio pca in
  let max_r = Array.fold_left max ratio.(0) ratio in
  let min_r = Array.fold_left min ratio.(0) ratio in
    Alcotest.(check bool)
      (Printf.sprintf "isotropic ratios roughly equal (max=%g min=%g)" max_r min_r)
      true
      (max_r -. min_r < 0.15)


let test_transform_inverse_roundtrip () =
  let rng = Random.State.make [| 93 |] in
  let n = 200 in
  let data = Array.init n (fun _ -> Array.init 4 (fun _ -> Helpers.normal_sample rng)) in
  let pca = Pca.fit ~data () in
  (* Project and reconstruct — full rank, so reconstruction should match *)
  let proj = Pca.transform pca ~data in
  let recon = Pca.inverse_transform pca ~projected:proj in
    for i = 0 to n - 1 do
      for j = 0 to 3 do
        Alcotest.(check (float 1e-8))
          (Printf.sprintf "recon[%d][%d]" i j)
          data.(i).(j)
          recon.(i).(j)
      done
    done


let test_n_components_truncation () =
  let rng = Random.State.make [| 94 |] in
  let n = 100 in
  let data = Array.init n (fun _ -> Array.init 5 (fun _ -> Helpers.normal_sample rng)) in
  let pca = Pca.fit ~data ~n_components:2 () in
    Alcotest.(check int) "k = 2" 2 (Pca.n_components pca) ;
    Alcotest.(check int) "p = 5" 5 (Pca.n_features pca)


let suite =
  [
    Alcotest.test_case "one_dim_line" `Quick test_one_dim_line;
    Alcotest.test_case "isotropic_noise" `Quick test_isotropic_noise;
    Alcotest.test_case "transform_inverse_roundtrip" `Quick test_transform_inverse_roundtrip;
    Alcotest.test_case "n_components_truncation" `Quick test_n_components_truncation;
  ]
