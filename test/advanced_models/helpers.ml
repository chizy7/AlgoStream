let normal_sample rng =
  let u1 = max 1e-12 (Random.State.float rng 1.0) in
  let u2 = Random.State.float rng 1.0 in
    sqrt (-2.0 *. log u1) *. cos (2.0 *. Float.pi *. u2)


let random_walk_series ~n ~seed =
  let rng = Random.State.make [| seed |] in
  let s = Array.make n 0.0 in
    for i = 1 to n - 1 do
      s.(i) <- s.(i - 1) +. normal_sample rng
    done ;
    s


let ar1_series ~n ~phi ~seed =
  let rng = Random.State.make [| seed |] in
  let s = Array.make n 0.0 in
    for i = 1 to n - 1 do
      s.(i) <- (phi *. s.(i - 1)) +. normal_sample rng
    done ;
    s


(* Simulate GARCH(1,1) returns with known parameters. *)
let garch_series ~n ~omega ~alpha ~beta ~seed =
  let rng = Random.State.make [| seed |] in
  let long_run = omega /. (1.0 -. alpha -. beta) in
  let var = ref long_run in
  let r_prev = ref 0.0 in
  let out = Array.make n 0.0 in
    for i = 0 to n - 1 do
      var := omega +. (alpha *. (!r_prev *. !r_prev)) +. (beta *. !var) ;
      let z = normal_sample rng in
      let r = sqrt !var *. z in
        out.(i) <- r ;
        r_prev := r
    done ;
    out
