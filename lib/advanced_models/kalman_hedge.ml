type state = {
  alpha : float;
  beta : float;
  cov : float array array;
}

type t = {
  mutable alpha : float;
  mutable beta : float;
  cov : float array array;
  q_alpha : float;
  q_beta : float;
  r : float;
  mutable n : int;
}

let create ?(initial_alpha = 0.0) ?(initial_beta = 1.0) ?(initial_cov = 1.0)
  ?(process_var_alpha = 1e-5) ?(process_var_beta = 1e-3) ?(measurement_var = 1.0) () =
  let cov = Array.make_matrix 2 2 0.0 in
    cov.(0).(0) <- initial_cov ;
    cov.(1).(1) <- initial_cov ;
    {
      alpha = initial_alpha;
      beta = initial_beta;
      cov;
      q_alpha = process_var_alpha;
      q_beta = process_var_beta;
      r = measurement_var;
      n = 0;
    }


let copy_cov c =
  let out = Array.make_matrix 2 2 0.0 in
    out.(0).(0) <- c.(0).(0) ;
    out.(0).(1) <- c.(0).(1) ;
    out.(1).(0) <- c.(1).(0) ;
    out.(1).(1) <- c.(1).(1) ;
    out


let state t = { alpha = t.alpha; beta = t.beta; cov = copy_cov t.cov }

let n_updates t = t.n

let update t ~y ~x =
  (* Predict: random-walk transition, P -> P + Q *)
  let p00 = t.cov.(0).(0) +. t.q_alpha in
  let p01 = t.cov.(0).(1) in
  let p11 = t.cov.(1).(1) +. t.q_beta in
  (* Innovation S = H P H^T + R, H = [1, x] *)
  let s = p00 +. (2.0 *. x *. p01) +. (x *. x *. p11) +. t.r in
  (* Kalman gain *)
  let k0 = (p00 +. (x *. p01)) /. s in
  let k1 = (p01 +. (x *. p11)) /. s in
  let innov = y -. t.alpha -. (t.beta *. x) in
    t.alpha <- t.alpha +. (k0 *. innov) ;
    t.beta <- t.beta +. (k1 *. innov) ;
    (* Joseph form: P+ = (I - K H) P (I - K H)^T + K R K^T *)
    let m00 = 1.0 -. k0 in
    let m01 = -.k0 *. x in
    let m10 = -.k1 in
    let m11 = 1.0 -. (k1 *. x) in
    let t00 = (m00 *. p00) +. (m01 *. p01) in
    let t01 = (m00 *. p01) +. (m01 *. p11) in
    let t10 = (m10 *. p00) +. (m11 *. p01) in
    let t11 = (m10 *. p01) +. (m11 *. p11) in
    let q00 = (t00 *. m00) +. (t01 *. m01) +. (k0 *. t.r *. k0) in
    let q01 = (t00 *. m10) +. (t01 *. m11) +. (k0 *. t.r *. k1) in
    let q11 = (t10 *. m10) +. (t11 *. m11) +. (k1 *. t.r *. k1) in
      t.cov.(0).(0) <- q00 ;
      t.cov.(0).(1) <- q01 ;
      t.cov.(1).(0) <- q01 ;
      t.cov.(1).(1) <- q11 ;
      t.n <- t.n + 1 ;
      state t
