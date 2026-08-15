type config = {
  max_iter : int;
  tol_x : float;
  tol_f : float;
  alpha : float;
  gamma : float;
  rho : float;
  sigma : float;
}

let default_config =
  { max_iter = 500; tol_x = 1e-8; tol_f = 1e-8; alpha = 1.0; gamma = 2.0; rho = 0.5; sigma = 0.5 }


type result = {
  x : float array;
  f : float;
  iter : int;
  converged : bool;
}

let build_simplex x0 =
  let n = Array.length x0 in
  let simplex = Array.make_matrix (n + 1) n 0.0 in
    Array.blit x0 0 simplex.(0) 0 n ;
    for i = 1 to n do
      Array.blit x0 0 simplex.(i) 0 n ;
      let s = if abs_float x0.(i - 1) > 1e-10 then 0.05 *. x0.(i - 1) else 2.5e-4 in
        simplex.(i).(i - 1) <- x0.(i - 1) +. s
    done ;
    simplex


let sort_simplex simplex fvals =
  let n = Array.length fvals in
  let indices = Array.init n (fun i -> i) in
    Array.sort (fun i j -> compare fvals.(i) fvals.(j)) indices ;
    let sorted_s = Array.map (fun i -> Array.copy simplex.(i)) indices in
    let sorted_f = Array.map (fun i -> fvals.(i)) indices in
      Array.blit sorted_s 0 simplex 0 n ;
      Array.blit sorted_f 0 fvals 0 n


let centroid_except_last simplex n =
  let c = Array.make n 0.0 in
    for i = 0 to n - 1 do
      for j = 0 to n - 1 do
        c.(j) <- c.(j) +. simplex.(i).(j)
      done
    done ;
    for j = 0 to n - 1 do
      c.(j) <- c.(j) /. float_of_int n
    done ;
    c


let minimize ~f ~x0 ?(config = default_config) () =
  let n = Array.length x0 in
  let simplex = build_simplex x0 in
  let fvals = Array.map f simplex in
  let iter = ref 0 in
  let converged = ref false in
    while (not !converged) && !iter < config.max_iter do
      incr iter ;
      sort_simplex simplex fvals ;
      let fbest = fvals.(0) in
      let fworst = fvals.(n) in
        if abs_float (fworst -. fbest) < config.tol_f then converged := true
        else
          let centroid = centroid_except_last simplex n in
          let xr =
            Array.init n (fun j ->
              centroid.(j) +. (config.alpha *. (centroid.(j) -. simplex.(n).(j)))) in
          let fr = f xr in
            if fr < fvals.(0) then
              let xe =
                Array.init n (fun j -> centroid.(j) +. (config.gamma *. (xr.(j) -. centroid.(j))))
              in
              let fe = f xe in
                if fe < fr then (
                  Array.blit xe 0 simplex.(n) 0 n ;
                  fvals.(n) <- fe)
                else (
                  Array.blit xr 0 simplex.(n) 0 n ;
                  fvals.(n) <- fr)
            else if fr < fvals.(n - 1) then (
              Array.blit xr 0 simplex.(n) 0 n ;
              fvals.(n) <- fr)
            else
              let xc =
                Array.init n (fun j ->
                  centroid.(j) +. (config.rho *. (simplex.(n).(j) -. centroid.(j)))) in
              let fc = f xc in
                if fc < fvals.(n) then (
                  Array.blit xc 0 simplex.(n) 0 n ;
                  fvals.(n) <- fc)
                else
                  for i = 1 to n do
                    for j = 0 to n - 1 do
                      simplex.(i).(j) <-
                        simplex.(0).(j) +. (config.sigma *. (simplex.(i).(j) -. simplex.(0).(j)))
                    done ;
                    fvals.(i) <- f simplex.(i)
                  done
    done ;
    sort_simplex simplex fvals ;
    { x = Array.copy simplex.(0); f = fvals.(0); iter = !iter; converged = !converged }
