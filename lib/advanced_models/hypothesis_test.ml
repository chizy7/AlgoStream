type result = {
  name : string;
  statistic : float;
  p_value : float;
  dof : float option;
}

let reject r ~alpha = r.p_value < alpha

let mean a =
  let n = Array.length a in
  let s = Array.fold_left ( +. ) 0.0 a in
    s /. float_of_int n


let var_unbiased a =
  let n = Array.length a in
  let m = mean a in
  let s2 = ref 0.0 in
    Array.iter (fun x -> s2 := !s2 +. ((x -. m) ** 2.0)) a ;
    !s2 /. float_of_int (n - 1)


let one_sample_t ~sample ~mu0 =
  let n = Array.length sample in
  let nf = float_of_int n in
  let m = mean sample in
  let s2 = var_unbiased sample in
  let stderr = sqrt (s2 /. nf) in
  let t = if stderr > 0.0 then (m -. mu0) /. stderr else 0.0 in
  let df = nf -. 1.0 in
  let cdf = Distribution.Student_t.cdf ~x:t ~df in
  let p = 2.0 *. min cdf (1.0 -. cdf) in
    { name = "one_sample_t"; statistic = t; p_value = p; dof = Some df }


let two_sample_t ~sample_a ~sample_b ?(equal_var = false) () =
  let na = Array.length sample_a in
  let nb = Array.length sample_b in
  let nfa = float_of_int na in
  let nfb = float_of_int nb in
  let ma = mean sample_a in
  let mb = mean sample_b in
  let va = var_unbiased sample_a in
  let vb = var_unbiased sample_b in
  let t, df =
    if equal_var then
      let pooled = (((nfa -. 1.0) *. va) +. ((nfb -. 1.0) *. vb)) /. (nfa +. nfb -. 2.0) in
      let stderr = sqrt (pooled *. ((1.0 /. nfa) +. (1.0 /. nfb))) in
        ((ma -. mb) /. stderr, nfa +. nfb -. 2.0)
    else
      let se = sqrt ((va /. nfa) +. (vb /. nfb)) in
      let t_stat = (ma -. mb) /. se in
      let num = ((va /. nfa) +. (vb /. nfb)) ** 2.0 in
      let denom = (((va /. nfa) ** 2.0) /. (nfa -. 1.0)) +. (((vb /. nfb) ** 2.0) /. (nfb -. 1.0)) in
        (t_stat, num /. denom) in
  let cdf = Distribution.Student_t.cdf ~x:t ~df in
  let p = 2.0 *. min cdf (1.0 -. cdf) in
    { name = "two_sample_t"; statistic = t; p_value = p; dof = Some df }


let chi_squared_gof ~observed ~expected =
  let n = Array.length observed in
    if Array.length expected <> n then
      invalid_arg "chi_squared_gof: observed and expected length mismatch" ;
    let stat = ref 0.0 in
      for i = 0 to n - 1 do
        let e = expected.(i) in
          if e > 0.0 then stat := !stat +. (((observed.(i) -. e) ** 2.0) /. e)
      done ;
      let df = float_of_int (n - 1) in
      let cdf = Distribution.Chi_squared.cdf ~x:!stat ~df in
        { name = "chi_squared_gof"; statistic = !stat; p_value = 1.0 -. cdf; dof = Some df }


let ks_q_prob lambda =
  if lambda < 0.001 then 1.0
  else
    let s = ref 0.0 in
    let sign = ref 1.0 in
    let converged = ref false in
    let j = ref 1 in
      while (not !converged) && !j < 100 do
        let jf = float_of_int !j in
        let term = !sign *. exp (-2.0 *. jf *. jf *. lambda *. lambda) in
          s := !s +. term ;
          if abs_float term < 1e-10 *. abs_float !s then converged := true ;
          sign := -. !sign ;
          incr j
      done ;
      max 0.0 (min 1.0 (2.0 *. !s))


let ks_one_sample ~sample ~cdf =
  let n = Array.length sample in
  let arr = Array.copy sample in
    Array.sort compare arr ;
    let nf = float_of_int n in
    let d = ref 0.0 in
      for i = 0 to n - 1 do
        let fn = float_of_int (i + 1) /. nf in
        let fn_prev = float_of_int i /. nf in
        let fx = cdf arr.(i) in
        let d_above = abs_float (fn -. fx) in
        let d_below = abs_float (fx -. fn_prev) in
          if d_above > !d then d := d_above ;
          if d_below > !d then d := d_below
      done ;
      let lambda = (sqrt nf +. 0.12 +. (0.11 /. sqrt nf)) *. !d in
      let p = ks_q_prob lambda in
        { name = "ks_one_sample"; statistic = !d; p_value = p; dof = None }


let ks_two_sample ~sample_a ~sample_b =
  let na = Array.length sample_a in
  let nb = Array.length sample_b in
  let a = Array.copy sample_a in
  let b = Array.copy sample_b in
    Array.sort compare a ;
    Array.sort compare b ;
    let nfa = float_of_int na in
    let nfb = float_of_int nb in
    let i = ref 0 in
    let j = ref 0 in
    let d = ref 0.0 in
      while !i < na && !j < nb do
        let xi = a.(!i) in
        let xj = b.(!j) in
          if xi <= xj then incr i ;
          if xj <= xi then incr j ;
          let fa = float_of_int !i /. nfa in
          let fb = float_of_int !j /. nfb in
          let diff = abs_float (fa -. fb) in
            if diff > !d then d := diff
      done ;
      let n_eff = nfa *. nfb /. (nfa +. nfb) in
      let lambda = (sqrt n_eff +. 0.12 +. (0.11 /. sqrt n_eff)) *. !d in
      let p = ks_q_prob lambda in
        { name = "ks_two_sample"; statistic = !d; p_value = p; dof = None }


let jarque_bera ~sample =
  let n = Array.length sample in
  let nf = float_of_int n in
  let m = mean sample in
  let m2 = ref 0.0 in
  let m3 = ref 0.0 in
  let m4 = ref 0.0 in
    for i = 0 to n - 1 do
      let d = sample.(i) -. m in
      let d2 = d *. d in
        m2 := !m2 +. d2 ;
        m3 := !m3 +. (d2 *. d) ;
        m4 := !m4 +. (d2 *. d2)
    done ;
    m2 := !m2 /. nf ;
    m3 := !m3 /. nf ;
    m4 := !m4 /. nf ;
    let s = if !m2 > 0.0 then !m3 /. (!m2 ** 1.5) else 0.0 in
    let k = if !m2 > 0.0 then !m4 /. (!m2 *. !m2) else 3.0 in
    let jb = nf /. 6.0 *. ((s *. s) +. (((k -. 3.0) ** 2.0) /. 4.0)) in
    let cdf = Distribution.Chi_squared.cdf ~x:jb ~df:2.0 in
      { name = "jarque_bera"; statistic = jb; p_value = 1.0 -. cdf; dof = Some 2.0 }


let autocorr a lag =
  let n = Array.length a in
  let m = mean a in
  let var = var_unbiased a in
    if var <= 0.0 || lag >= n then 0.0
    else
      let sum = ref 0.0 in
        for t = lag to n - 1 do
          sum := !sum +. ((a.(t) -. m) *. (a.(t - lag) -. m))
        done ;
        !sum /. float_of_int (n - 1) /. var


let ljung_box ~residuals ~lags =
  let n = Array.length residuals in
  let nf = float_of_int n in
  let stat = ref 0.0 in
    for k = 1 to lags do
      let rho = autocorr residuals k in
        stat := !stat +. (rho *. rho /. (nf -. float_of_int k))
    done ;
    let q = nf *. (nf +. 2.0) *. !stat in
    let df = float_of_int lags in
    let cdf = Distribution.Chi_squared.cdf ~x:q ~df in
      { name = "ljung_box"; statistic = q; p_value = 1.0 -. cdf; dof = Some df }


let runs_test ~sample =
  let m = mean sample in
  let signs = Array.map (fun x -> if x > m then 1 else if x < m then -1 else 0) sample in
  let positive = ref 0 in
  let negative = ref 0 in
    Array.iter (fun s -> if s > 0 then incr positive else if s < 0 then incr negative) signs ;
    let n_plus = float_of_int !positive in
    let n_minus = float_of_int !negative in
    let total = n_plus +. n_minus in
    let runs = ref 0 in
    let prev = ref 0 in
      Array.iter
        (fun s ->
          if s <> 0 then (
            if s <> !prev then incr runs ;
            prev := s))
        signs ;
      let r = float_of_int !runs in
      let mu = (2.0 *. n_plus *. n_minus /. total) +. 1.0 in
      let var =
        2.0 *. n_plus *. n_minus
        *. ((2.0 *. n_plus *. n_minus) -. total)
        /. (total *. total *. (total -. 1.0)) in
      let z = if var > 0.0 then (r -. mu) /. sqrt var else 0.0 in
      let cdf = Distribution.Normal.cdf ~x:z in
      let p = 2.0 *. min cdf (1.0 -. cdf) in
        { name = "runs_test"; statistic = z; p_value = p; dof = None }
