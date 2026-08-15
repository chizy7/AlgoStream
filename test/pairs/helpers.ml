open Algostream_pairs
module Symbol = Algostream_normalization.Symbol

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


let cointegrated_series ~n ~beta ~phi_noise ~seed_x ~seed_noise =
  let x = random_walk_series ~n ~seed:seed_x in
  let noise = ar1_series ~n ~phi:phi_noise ~seed:seed_noise in
  let y = Array.init n (fun i -> (beta *. x.(i)) +. noise.(i)) in
    (y, x)


let sym base quote = { Symbol.base; quote; asset_class = Symbol.Crypto }

let pair a b = Pair_id.of_symbols (sym a "USD") (sym b "USD")
