type signal =
  | Long_spread
  | Short_spread
  | Exit
  | Hold

type position =
  [ `Flat
  | `Long
  | `Short
  ]

type t = {
  entry_z : float;
  exit_z : float;
  stop_z : float;
  mutable pos : position;
}

let create ~entry_z ~exit_z ~stop_z = { entry_z; exit_z; stop_z; pos = `Flat }

let update t ~z =
  let az = abs_float z in
    match t.pos with
    | `Flat ->
      if z >= t.entry_z then (
        t.pos <- `Short ;
        Short_spread)
      else if z <= -.t.entry_z then (
        t.pos <- `Long ;
        Long_spread)
      else Hold
    | `Long ->
      if az >= t.stop_z then (
        t.pos <- `Flat ;
        Exit)
      else if z >= -.t.exit_z then (
        t.pos <- `Flat ;
        Exit)
      else Hold
    | `Short ->
      if az >= t.stop_z then (
        t.pos <- `Flat ;
        Exit)
      else if z <= t.exit_z then (
        t.pos <- `Flat ;
        Exit)
      else Hold


let position t = t.pos

type half_life_error =
  [ `Insufficient_data of int * int
  | `Non_reverting
  | `Ols of Ols.error
  ]

let half_life ~residuals =
  let n = Array.length residuals in
  let need = 8 in
    if n < need then Error (`Insufficient_data (n, need))
    else
      let m = n - 1 in
      let x = Array.make m 0.0 in
      let y = Array.make m 0.0 in
        for i = 0 to m - 1 do
          x.(i) <- residuals.(i) ;
          y.(i) <- residuals.(i + 1) -. residuals.(i)
        done ;
        match Ols.regress2 ~x ~y with
        | Error e -> Error (`Ols e)
        | Ok (_intercept, slope, _r2) ->
          let phi = 1.0 +. slope in
          let abs_phi = abs_float phi in
            if abs_phi >= 1.0 || abs_phi < 1e-12 then Error `Non_reverting
            else Ok (-.log 2.0 /. log abs_phi)


type significance =
  | Significant of float
  | Marginal
  | Non_reverting

let significance (r : Adf.result) =
  if r.p_value < 0.01 then Significant r.p_value
  else if r.p_value < 0.10 then Marginal
  else Non_reverting


let signal_to_string = function
  | Long_spread -> "long_spread"
  | Short_spread -> "short_spread"
  | Exit -> "exit"
  | Hold -> "hold"
