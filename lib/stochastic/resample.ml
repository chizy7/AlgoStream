module Rng = Algostream_rng.Rng

let iid rng ~data ~n =
  let m = Array.length data in
    if m = 0 then invalid_arg "Resample.iid: empty data" ;
    Array.init n (fun _ -> data.(Rng.int_below rng m))


let moving_block rng ~data ~block_len ~n =
  let m = Array.length data in
    if m = 0 then invalid_arg "Resample.moving_block: empty data" ;
    let b = if block_len < 1 then 1 else if block_len > m then m else block_len in
    (* Start indices run over [0, m - b], so observations within b of either end appear in fewer
       blocks than interior ones. That end-effect bias is exactly what circular_block fixes. *)
    let n_starts = m - b + 1 in
    let out = Array.make n 0.0 in
    let filled = ref 0 in
      while !filled < n do
        let start = Rng.int_below rng n_starts in
        let take = min b (n - !filled) in
          Array.blit data start out !filled take ;
          filled := !filled + take
      done ;
      out


let circular_block rng ~data ~block_len ~n =
  let m = Array.length data in
    if m = 0 then invalid_arg "Resample.circular_block: empty data" ;
    let b = if block_len < 1 then 1 else block_len in
    let out = Array.make n 0.0 in
    let filled = ref 0 in
      while !filled < n do
        let start = Rng.int_below rng m in
        let take = min b (n - !filled) in
          for j = 0 to take - 1 do
            out.(!filled + j) <- data.((start + j) mod m)
          done ;
          filled := !filled + take
      done ;
      out


let stationary rng ~data ~mean_block_len ~n =
  let m = Array.length data in
    if m = 0 then invalid_arg "Resample.stationary: empty data" ;
    let mean_b = if mean_block_len < 1.0 then 1.0 else mean_block_len in
    (* Politis-Romano: at each step, continue the current block with probability 1 - p, or jump to a
       fresh uniform start with probability p = 1 / mean_block_len. Block lengths are therefore
       Geometric(p) with mean mean_block_len, and the resampled series is stationary — unlike the
       fixed-length variants, whose distribution depends on position within the block. *)
    let p = 1.0 /. mean_b in
    let out = Array.make n 0.0 in
    let idx = ref (Rng.int_below rng m) in
      for i = 0 to n - 1 do
        if i > 0 then
          if Rng.uniform rng < p then idx := Rng.int_below rng m else idx := (!idx + 1) mod m ;
        out.(i) <- data.(!idx)
      done ;
      out


let rule_of_thumb ~n =
  if n <= 1 then 1
  else
    let b = int_of_float (Float.round (float_of_int n ** (1.0 /. 3.0))) in
      if b < 1 then 1 else b


let joint_index rng ~n_source ~n ~block_len =
  if n_source <= 0 then invalid_arg "Resample.joint_index: n_source must be positive" ;
  let b = if block_len < 1 then 1 else block_len in
  let out = Array.make n 0 in
  let filled = ref 0 in
    while !filled < n do
      let start = Rng.int_below rng n_source in
      let take = min b (n - !filled) in
        for j = 0 to take - 1 do
          out.(!filled + j) <- (start + j) mod n_source
        done ;
        filled := !filled + take
    done ;
    out


let take ~data ~idx =
  let m = Array.length data in
    Array.map
      (fun i ->
        if i < 0 || i >= m then
          invalid_arg (Printf.sprintf "Resample.take: index %d out of range [0, %d)" i m) ;
        data.(i))
      idx


let permute rng a =
  let c = Array.copy a in
    Rng.shuffle rng c ;
    c


let sign_flip rng a = Array.map (fun x -> if Rng.uniform rng < 0.5 then -.x else x) a
