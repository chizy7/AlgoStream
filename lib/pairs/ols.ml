type fit = {
  beta : float array;
  se : float array;
  rss : float;
  tss : float;
  n : int;
  p : int;
}

type error =
  [ `Singular
  | `Underdetermined of int * int
  ]

let solve ~x ~y ~p =
  let n = Array.length y in
    if n < p then Error (`Underdetermined (n, p))
    else if Array.length x <> n then invalid_arg "Ols.solve: x.length <> y.length"
    else
      let g = Array.make_matrix p p 0.0 in
      let h = Array.make p 0.0 in
        for i = 0 to n - 1 do
          let row = x.(i) in
            if Array.length row <> p then invalid_arg "Ols.solve: row length <> p" ;
            for j = 0 to p - 1 do
              h.(j) <- h.(j) +. (row.(j) *. y.(i)) ;
              for k = j to p - 1 do
                g.(j).(k) <- g.(j).(k) +. (row.(j) *. row.(k))
              done
            done
        done ;
        for j = 0 to p - 1 do
          for k = 0 to j - 1 do
            g.(j).(k) <- g.(k).(j)
          done
        done ;
        for j = 0 to p - 1 do
          g.(j).(j) <- g.(j).(j) +. 1e-12
        done ;
        (* Cholesky G = L L^T (lower triangular L) *)
        let l = Array.make_matrix p p 0.0 in
        let singular = ref false in
        let j = ref 0 in
          while (not !singular) && !j < p do
            let jj = !j in
            let s = ref g.(jj).(jj) in
              for k = 0 to jj - 1 do
                s := !s -. (l.(jj).(k) *. l.(jj).(k))
              done ;
              if !s <= 0.0 then singular := true
              else (
                l.(jj).(jj) <- sqrt !s ;
                for i = jj + 1 to p - 1 do
                  let s2 = ref g.(i).(jj) in
                    for k = 0 to jj - 1 do
                      s2 := !s2 -. (l.(i).(k) *. l.(jj).(k))
                    done ;
                    l.(i).(jj) <- !s2 /. l.(jj).(jj)
                done) ;
              incr j
          done ;
          if !singular then Error `Singular
          else
            (* solve L z = h, then L^T β = z *)
            let z = Array.make p 0.0 in
              for i = 0 to p - 1 do
                let s = ref h.(i) in
                  for k = 0 to i - 1 do
                    s := !s -. (l.(i).(k) *. z.(k))
                  done ;
                  z.(i) <- !s /. l.(i).(i)
              done ;
              let beta = Array.make p 0.0 in
                for i = p - 1 downto 0 do
                  let s = ref z.(i) in
                    for k = i + 1 to p - 1 do
                      s := !s -. (l.(k).(i) *. beta.(k))
                    done ;
                    beta.(i) <- !s /. l.(i).(i)
                done ;
                (* RSS and TSS *)
                let mean_y = ref 0.0 in
                  for i = 0 to n - 1 do
                    mean_y := !mean_y +. y.(i)
                  done ;
                  let my = !mean_y /. float_of_int n in
                  let rss = ref 0.0 in
                  let tss = ref 0.0 in
                    for i = 0 to n - 1 do
                      let pred = ref 0.0 in
                        for j = 0 to p - 1 do
                          pred := !pred +. (x.(i).(j) *. beta.(j))
                        done ;
                        let r = y.(i) -. !pred in
                          rss := !rss +. (r *. r) ;
                          let d = y.(i) -. my in
                            tss := !tss +. (d *. d)
                    done ;
                    (* Diagonal of (X^T X)^{-1} via per-column solves *)
                    let g_inv_diag = Array.make p 0.0 in
                    let z2 = Array.make p 0.0 in
                    let xv = Array.make p 0.0 in
                      for col = 0 to p - 1 do
                        for i = 0 to p - 1 do
                          z2.(i) <- 0.0 ;
                          xv.(i) <- 0.0
                        done ;
                        let e_col = col in
                          for i = 0 to p - 1 do
                            let s = ref (if i = e_col then 1.0 else 0.0) in
                              for k = 0 to i - 1 do
                                s := !s -. (l.(i).(k) *. z2.(k))
                              done ;
                              z2.(i) <- !s /. l.(i).(i)
                          done ;
                          for i = p - 1 downto 0 do
                            let s = ref z2.(i) in
                              for k = i + 1 to p - 1 do
                                s := !s -. (l.(k).(i) *. xv.(k))
                              done ;
                              xv.(i) <- !s /. l.(i).(i)
                          done ;
                          g_inv_diag.(col) <- xv.(col)
                      done ;
                      let sigma2 = if n > p then !rss /. float_of_int (n - p) else 0.0 in
                      let se = Array.map (fun v -> sqrt (max 0.0 (sigma2 *. v))) g_inv_diag in
                        Ok { beta; se; rss = !rss; tss = !tss; n; p }


let regress2 ~x ~y =
  let n = Array.length x in
    if Array.length y <> n then invalid_arg "Ols.regress2: length mismatch" ;
    let mat = Array.make_matrix n 2 0.0 in
      for i = 0 to n - 1 do
        mat.(i).(0) <- 1.0 ;
        mat.(i).(1) <- x.(i)
      done ;
      match solve ~x:mat ~y ~p:2 with
      | Error e -> Error e
      | Ok fit ->
        let r2 = if fit.tss > 0.0 then 1.0 -. (fit.rss /. fit.tss) else 0.0 in
          Ok (fit.beta.(0), fit.beta.(1), r2)
