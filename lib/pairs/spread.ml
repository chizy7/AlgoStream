module Rolling = Algostream_analytics.Rolling

type t = {
  mean : Rolling.Rolling_mean.t;
  var : Rolling.Rolling_var.t;
  mutable current : float;
  mutable last_ts_ns : int64;
}

let create ~window ~recompute_every =
  {
    mean = Rolling.Rolling_mean.create ~window;
    var = Rolling.Rolling_var.create ~window ~recompute_every;
    current = 0.0;
    last_ts_ns = 0L;
  }


let update t ~y ~x ~beta ~intercept ~ts_ns =
  let s = y -. (beta *. x) -. intercept in
    t.current <- s ;
    t.last_ts_ns <- ts_ns ;
    ignore (Rolling.Rolling_mean.update t.mean s : float) ;
    ignore (Rolling.Rolling_var.update t.var s : float)


let current t = t.current

let mean t = Rolling.Rolling_mean.value t.mean

let std t = Rolling.Rolling_var.std_dev t.var

let z t =
  let s = std t in
    if s > 1e-12 then (t.current -. mean t) /. s else 0.0


let n t = Rolling.Rolling_mean.n t.mean

let last_ts_ns t = t.last_ts_ns
