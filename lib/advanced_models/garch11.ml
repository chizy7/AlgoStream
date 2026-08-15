type params = {
  omega : float;
  alpha : float;
  beta : float;
}

type fit_result = {
  params : params;
  log_likelihood : float;
  iter : int;
  converged : bool;
  long_run_variance : float;
}

type fit_error =
  [ `Insufficient_data of int * int
  | `Not_converged
  ]

let sigmoid x = 1.0 /. (1.0 +. exp (-.x))

(* Map unconstrained (p1, p2) → (alpha, beta) on the open simplex. *)
let to_simplex p =
  let alpha = sigmoid p.(0) *. 0.999 in
  let beta = sigmoid p.(1) *. (0.999 -. alpha) in
    (alpha, beta)


let sample_variance returns =
  let n = Array.length returns in
  let m = ref 0.0 in
    Array.iter (fun x -> m := !m +. x) returns ;
    let mu = !m /. float_of_int n in
    let s2 = ref 0.0 in
      Array.iter (fun x -> s2 := !s2 +. ((x -. mu) ** 2.0)) returns ;
      !s2 /. float_of_int n


let neg_log_likelihood returns sigma_bar2 p =
  let alpha, beta = to_simplex p in
  let omega = sigma_bar2 *. max 0.0 (1.0 -. alpha -. beta) in
  let n = Array.length returns in
  let var = ref sigma_bar2 in
  let nll = ref 0.0 in
    for t = 0 to n - 1 do
      let r = returns.(t) in
        if t > 0 then var := omega +. (alpha *. (returns.(t - 1) ** 2.0)) +. (beta *. !var) ;
        let v = max 1e-300 !var in
          nll := !nll +. (0.5 *. (log v +. (r *. r /. v)))
    done ;
    !nll


let fit ~returns ?(max_iter = 500) ?(tol = 1e-8) () =
  let n = Array.length returns in
    if n < 32 then Error (`Insufficient_data (n, 32))
    else
      let sigma_bar2 = sample_variance returns in
        if sigma_bar2 <= 0.0 then Error `Not_converged
        else
          let f = neg_log_likelihood returns sigma_bar2 in
          let starts = [| [| 0.0; 1.5 |]; [| -0.5; 1.0 |]; [| 0.5; 2.0 |]; [| -1.0; 0.5 |] |] in
          let config = { Nelder_mead.default_config with max_iter; tol_f = tol; tol_x = tol } in
          let best_res = ref None in
          let best_nll = ref infinity in
            Array.iter
              (fun x0 ->
                let res = Nelder_mead.minimize ~f ~x0 ~config () in
                  if res.f < !best_nll then (
                    best_nll := res.f ;
                    best_res := Some res))
              starts ;
            match !best_res with
            | None -> Error `Not_converged
            | Some res ->
              let alpha, beta = to_simplex res.x in
              let omega = sigma_bar2 *. max 0.0 (1.0 -. alpha -. beta) in
              let long_run =
                if alpha +. beta < 1.0 then omega /. (1.0 -. alpha -. beta) else sigma_bar2 in
                Ok
                  {
                    params = { omega; alpha; beta };
                    log_likelihood = -.res.f;
                    iter = res.iter;
                    converged = res.converged;
                    long_run_variance = long_run;
                  }


type t = {
  params : params;
  mutable last_return : float;
  mutable current_var : float;
  long_run : float;
}

let of_fit (fit_res : fit_result) ~last_return ~last_variance =
  {
    params = fit_res.params;
    last_return;
    current_var = last_variance;
    long_run = fit_res.long_run_variance;
  }


let update t ~r =
  let p = t.params in
  let next = p.omega +. (p.alpha *. (t.last_return ** 2.0)) +. (p.beta *. t.current_var) in
    t.last_return <- r ;
    t.current_var <- next ;
    next


let current_variance t = t.current_var

let forecast t ~horizon =
  let p = t.params in
  let rho = p.alpha +. p.beta in
  let out = Array.make horizon 0.0 in
  let v = ref t.current_var in
    for h = 0 to horizon - 1 do
      v := p.omega +. (rho *. !v) ;
      out.(h) <- !v
    done ;
    out
