type result = {
  eigenvalues : float array;
  eigenvectors : float array array;
  iter : int;
  converged : bool;
}

let copy_matrix m =
  let n = Array.length m in
  let out = Array.make_matrix n n 0.0 in
    for i = 0 to n - 1 do
      for j = 0 to n - 1 do
        out.(i).(j) <- m.(i).(j)
      done
    done ;
    out


let off_norm_sq a =
  let n = Array.length a in
  let s = ref 0.0 in
    for i = 0 to n - 1 do
      for j = i + 1 to n - 1 do
        s := !s +. (a.(i).(j) *. a.(i).(j))
      done
    done ;
    2.0 *. !s


let frob_norm_sq a =
  let n = Array.length a in
  let s = ref 0.0 in
    for i = 0 to n - 1 do
      for j = 0 to n - 1 do
        s := !s +. (a.(i).(j) *. a.(i).(j))
      done
    done ;
    !s


let jacobi_sym ?(max_iter = 100) ?(tol = 1e-12) ~matrix () =
  let a = copy_matrix matrix in
  let n = Array.length a in
  let v = Array.make_matrix n n 0.0 in
    for i = 0 to n - 1 do
      v.(i).(i) <- 1.0
    done ;
    let frob_target = frob_norm_sq a *. tol *. tol in
    let sweep = ref 0 in
    let converged = ref false in
      while (not !converged) && !sweep < max_iter do
        incr sweep ;
        for p = 0 to n - 2 do
          for q = p + 1 to n - 1 do
            let apq = a.(p).(q) in
              if abs_float apq > 1e-30 then (
                let theta = (a.(q).(q) -. a.(p).(p)) /. (2.0 *. apq) in
                let t =
                  if abs_float theta > 1e150 then 1.0 /. (2.0 *. theta)
                  else
                    let sgn = if theta >= 0.0 then 1.0 else -1.0 in
                      sgn /. (abs_float theta +. sqrt ((theta *. theta) +. 1.0)) in
                let c = 1.0 /. sqrt ((t *. t) +. 1.0) in
                let s = t *. c in
                let tau = s /. (1.0 +. c) in
                  a.(p).(p) <- a.(p).(p) -. (t *. apq) ;
                  a.(q).(q) <- a.(q).(q) +. (t *. apq) ;
                  a.(p).(q) <- 0.0 ;
                  a.(q).(p) <- 0.0 ;
                  for r = 0 to n - 1 do
                    if r <> p && r <> q then (
                      let arp = a.(r).(p) in
                      let arq = a.(r).(q) in
                        a.(r).(p) <- arp -. (s *. (arq +. (tau *. arp))) ;
                        a.(p).(r) <- a.(r).(p) ;
                        a.(r).(q) <- arq +. (s *. (arp -. (tau *. arq))) ;
                        a.(q).(r) <- a.(r).(q))
                  done ;
                  for r = 0 to n - 1 do
                    let vrp = v.(r).(p) in
                    let vrq = v.(r).(q) in
                      v.(r).(p) <- vrp -. (s *. (vrq +. (tau *. vrp))) ;
                      v.(r).(q) <- vrq +. (s *. (vrp -. (tau *. vrq)))
                  done)
          done
        done ;
        if off_norm_sq a < frob_target then converged := true
      done ;
      let eigenvalues = Array.init n (fun i -> a.(i).(i)) in
      let indices = Array.init n (fun i -> i) in
        Array.sort (fun i j -> compare eigenvalues.(j) eigenvalues.(i)) indices ;
        let sorted_evals = Array.map (fun i -> eigenvalues.(i)) indices in
        let sorted_evecs = Array.make_matrix n n 0.0 in
          for i = 0 to n - 1 do
            for k = 0 to n - 1 do
              sorted_evecs.(i).(k) <- v.(i).(indices.(k))
            done
          done ;
          {
            eigenvalues = sorted_evals;
            eigenvectors = sorted_evecs;
            iter = !sweep;
            converged = !converged;
          }
