module Rolling = Algostream_analytics.Rolling

type t = {
  canonical : Symbol.t;
  feed_a : string;
  feed_b : string;
  mean : Rolling.Rolling_mean.t;
  var : Rolling.Rolling_var.t;
  mutable current_basis : float;
  mutable last_ts_ns : int64;
  mutable last_price_a : float;
  mutable last_price_b : float;
}

type stats = {
  mean_basis : float;
  std_basis : float;
  current_basis : float;
  current_z : float;
  n : int;
  last_ts_ns : int64;
}

let create ~canonical ~feed_a ~feed_b ?(window = 256) () =
  {
    canonical;
    feed_a;
    feed_b;
    mean = Rolling.Rolling_mean.create ~window;
    var = Rolling.Rolling_var.create ~window ~recompute_every:(max 8 (window / 16));
    current_basis = 0.0;
    last_ts_ns = 0L;
    last_price_a = nan;
    last_price_b = nan;
  }


let update (t : t) ~ts_ns ~price_a ~price_b =
  if price_a > 0.0 && price_b > 0.0 then (
    let mid = (price_a +. price_b) /. 2.0 in
    let basis = (price_a -. price_b) /. mid in
      t.current_basis <- basis ;
      t.last_ts_ns <- ts_ns ;
      t.last_price_a <- price_a ;
      t.last_price_b <- price_b ;
      let _ = Rolling.Rolling_mean.update t.mean basis in
      let _ = Rolling.Rolling_var.update t.var basis in
        ())


let stats (t : t) =
  let m = Rolling.Rolling_mean.value t.mean in
  let s = Rolling.Rolling_var.std_dev t.var in
  let z = if s > 1e-12 then (t.current_basis -. m) /. s else 0.0 in
    {
      mean_basis = m;
      std_basis = s;
      current_basis = t.current_basis;
      current_z = z;
      n = Rolling.Rolling_mean.n t.mean;
      last_ts_ns = t.last_ts_ns;
    }


let canonical t = t.canonical

let feeds t = (t.feed_a, t.feed_b)
