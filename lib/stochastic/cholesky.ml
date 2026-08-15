type error =
  [ `Not_square of int * int
  | `Not_positive_definite of int
  ]

let factor_ridged a ~jitter =
  let n = Array.length a in
    if n = 0 then Ok [||]
    else
      let cols = Array.length a.(0) in
        if cols <> n then Error (`Not_square (n, cols))
        else
          let bad_row = ref (-1) in
            Array.iteri (fun i row -> if Array.length row <> n && !bad_row < 0 then bad_row := i) a ;
            if !bad_row >= 0 then Error (`Not_square (n, Array.length a.(!bad_row)))
            else
              let l = Array.make_matrix n n 0.0 in
              let failed = ref (-1) in
              let i = ref 0 in
                while !failed < 0 && !i < n do
                  let ii = !i in
                  (* Diagonal: l_ii = sqrt(a_ii - Σ_{k<i} l_ik²) *)
                  let s = ref (a.(ii).(ii) +. jitter) in
                    for k = 0 to ii - 1 do
                      s := !s -. (l.(ii).(k) *. l.(ii).(k))
                    done ;
                    (if !s <= 0.0 || Float.is_nan !s then failed := ii
                     else
                       let d = sqrt !s in
                         l.(ii).(ii) <- d ;
                         (* Below the diagonal: l_ji = (a_ji - Σ_{k<i} l_jk·l_ik) / l_ii *)
                         for j = ii + 1 to n - 1 do
                           let s2 = ref a.(j).(ii) in
                             for k = 0 to ii - 1 do
                               s2 := !s2 -. (l.(j).(k) *. l.(ii).(k))
                             done ;
                             l.(j).(ii) <- !s2 /. d
                         done) ;
                    incr i
                done ;
                if !failed >= 0 then Error (`Not_positive_definite !failed) else Ok l


let factor a = factor_ridged a ~jitter:0.0

let factor_jittered ?(jitter = 1e-10) a = factor_ridged a ~jitter

let apply ~lower z =
  let n = Array.length lower in
    if Array.length z <> n then
      invalid_arg
        (Printf.sprintf "Cholesky.apply: lower is %dx%d but z has length %d" n n (Array.length z)) ;
    Array.init n (fun i ->
      let s = ref 0.0 in
        (* L is lower-triangular, so the row-i dot product stops at column i. *)
        for j = 0 to i do
          s := !s +. (lower.(i).(j) *. z.(j))
        done ;
        !s)


let correlation_to_covariance ~corr ~stddev =
  let n = Array.length corr in
    if Array.length stddev <> n then
      invalid_arg
        (Printf.sprintf "Cholesky.correlation_to_covariance: corr is %dx%d but stddev has length %d"
           n n (Array.length stddev)) ;
    Array.init n (fun i -> Array.init n (fun j -> corr.(i).(j) *. stddev.(i) *. stddev.(j)))
