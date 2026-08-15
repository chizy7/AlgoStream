module Metrics = Algostream_performance.Metrics

type t = {
  name : string;
  f : Metrics.t -> float;
}

let sharpe = { name = "sharpe"; f = (fun m -> m.Metrics.sharpe) }

let sortino = { name = "sortino"; f = (fun m -> m.Metrics.sortino) }

let calmar = { name = "calmar"; f = (fun m -> m.Metrics.calmar) }

let ann_return = { name = "ann_return"; f = (fun m -> m.Metrics.ann_return) }

let total_return = { name = "total_return"; f = (fun m -> m.Metrics.total_return) }

let min_drawdown = { name = "min_drawdown"; f = (fun m -> -.m.Metrics.max_drawdown) }

let return_over_max_dd =
  {
    name = "return_over_max_dd";
    f =
      (fun m ->
        if m.Metrics.max_drawdown <= 1e-12 then 0.0
        else m.Metrics.ann_return /. m.Metrics.max_drawdown);
  }


let penalized ~base ~lambda =
  {
    name = Printf.sprintf "%s-%gdd" base.name lambda;
    f = (fun m -> base.f m -. (lambda *. m.Metrics.max_drawdown));
  }


let require_activity ~base ~min_trades ~min_periods ~n_trades =
  {
    name = Printf.sprintf "%s|active" base.name;
    f =
      (fun m ->
        if m.Metrics.n_periods < min_periods || n_trades () < min_trades then neg_infinity
        else base.f m);
  }


let custom ~name ~f = { name; f }

let score t m =
  let v = t.f m in
    (* A configuration that produced nan or infinity must never outrank one that produced a real
       number, so map it to the bottom rather than letting comparison semantics decide. *)
    if Float.is_nan v || v = infinity then neg_infinity else v
