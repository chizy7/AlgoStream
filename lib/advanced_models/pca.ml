type t = {
  means : float array;
  components : float array array; (* k × p; row k is the k-th principal axis *)
  explained_variance : float array;
  explained_variance_ratio : float array;
  n_samples : int;
}

let column_means data =
  let n = Array.length data in
    if n = 0 then [||]
    else
      let p = Array.length data.(0) in
      let means = Array.make p 0.0 in
        for i = 0 to n - 1 do
          for j = 0 to p - 1 do
            means.(j) <- means.(j) +. data.(i).(j)
          done
        done ;
        let nf = float_of_int n in
          for j = 0 to p - 1 do
            means.(j) <- means.(j) /. nf
          done ;
          means


let centre data means =
  let n = Array.length data in
  let p = Array.length means in
  let centred = Array.make_matrix n p 0.0 in
    for i = 0 to n - 1 do
      for j = 0 to p - 1 do
        centred.(i).(j) <- data.(i).(j) -. means.(j)
      done
    done ;
    centred


let covariance_matrix centred =
  let n = Array.length centred in
  let p = if n = 0 then 0 else Array.length centred.(0) in
  let cov = Array.make_matrix p p 0.0 in
    for i = 0 to n - 1 do
      for j = 0 to p - 1 do
        for k = j to p - 1 do
          cov.(j).(k) <- cov.(j).(k) +. (centred.(i).(j) *. centred.(i).(k))
        done
      done
    done ;
    let denom = if n > 1 then float_of_int (n - 1) else 1.0 in
      for j = 0 to p - 1 do
        for k = j to p - 1 do
          cov.(j).(k) <- cov.(j).(k) /. denom ;
          cov.(k).(j) <- cov.(j).(k)
        done
      done ;
      cov


let fit ~data ?n_components () =
  let n = Array.length data in
    if n = 0 then invalid_arg "Pca.fit: empty data" ;
    let p = Array.length data.(0) in
    let means = column_means data in
    let centred = centre data means in
    let cov = covariance_matrix centred in
    let eig = Eig.jacobi_sym ~matrix:cov () in
    let k = match n_components with None -> p | Some k -> max 1 (min p k) in
    let total = Array.fold_left (fun acc v -> acc +. max 0.0 v) 0.0 eig.eigenvalues in
    let total = if total > 0.0 then total else 1.0 in
    let comps = Array.make_matrix k p 0.0 in
      for kk = 0 to k - 1 do
        for j = 0 to p - 1 do
          comps.(kk).(j) <- eig.eigenvectors.(j).(kk)
        done
      done ;
      let ev = Array.sub eig.eigenvalues 0 k in
      let ratio = Array.map (fun v -> max 0.0 v /. total) ev in
        {
          means;
          components = comps;
          explained_variance = ev;
          explained_variance_ratio = ratio;
          n_samples = n;
        }


let n_components t = Array.length t.explained_variance

let n_features t = Array.length t.means

let n_samples t = t.n_samples

let explained_variance t = Array.copy t.explained_variance

let explained_variance_ratio t = Array.copy t.explained_variance_ratio

let components t =
  let k = n_components t in
  let p = n_features t in
  let out = Array.make_matrix k p 0.0 in
    for i = 0 to k - 1 do
      Array.blit t.components.(i) 0 out.(i) 0 p
    done ;
    out


let transform t ~data =
  let n = Array.length data in
  let p = n_features t in
  let k = n_components t in
  let proj = Array.make_matrix n k 0.0 in
    for i = 0 to n - 1 do
      for kk = 0 to k - 1 do
        let s = ref 0.0 in
          for j = 0 to p - 1 do
            s := !s +. (t.components.(kk).(j) *. (data.(i).(j) -. t.means.(j)))
          done ;
          proj.(i).(kk) <- !s
      done
    done ;
    proj


let inverse_transform t ~projected =
  let n = Array.length projected in
  let p = n_features t in
  let k = n_components t in
  let out = Array.make_matrix n p 0.0 in
    for i = 0 to n - 1 do
      for j = 0 to p - 1 do
        let s = ref t.means.(j) in
          for kk = 0 to k - 1 do
            s := !s +. (projected.(i).(kk) *. t.components.(kk).(j))
          done ;
          out.(i).(j) <- !s
      done
    done ;
    out
