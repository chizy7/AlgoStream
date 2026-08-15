module Ewma = Algostream_analytics.Filters.Ewma

type status =
  | Stable
  | Weakening of float
  | Broken_down of float
  | Sign_flipped of float

module Detector = struct
  type t = {
    baseline : Ewma.t;
    current : Ewma.t;
    threshold : float;
    mutable last_status : status;
  }

  let create ?(baseline_period = 60) ?(current_period = 10) ?(breakdown_threshold = 0.3) () =
    {
      baseline = Ewma.create ~period:baseline_period;
      current = Ewma.create ~period:current_period;
      threshold = breakdown_threshold;
      last_status = Stable;
    }


  let baseline t = Ewma.value t.baseline

  let current t = Ewma.value t.current

  let classify ~baseline ~current ~threshold =
    let opposite_signs = (baseline > 0.0 && current < 0.0) || (baseline < 0.0 && current > 0.0) in
      if opposite_signs && abs_float current > threshold then Sign_flipped current
      else
        let diff = abs_float (baseline -. current) in
          if diff >= threshold then Broken_down current
          else if diff >= threshold /. 2.0 then Weakening current
          else Stable


  let update t ~correlation =
    let _ = Ewma.update t.baseline correlation in
    let _ = Ewma.update t.current correlation in
    let s = classify ~baseline:(baseline t) ~current:(current t) ~threshold:t.threshold in
      t.last_status <- s ;
      s


  let status t = t.last_status
end

let status_to_string = function
  | Stable -> "stable"
  | Weakening c -> Printf.sprintf "weakening(%.3f)" c
  | Broken_down c -> Printf.sprintf "broken_down(%.3f)" c
  | Sign_flipped c -> Printf.sprintf "sign_flipped(%.3f)" c
