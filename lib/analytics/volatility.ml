module Realized = struct
  type t = {
    var : Rolling.Rolling_var.t;
    mutable last_price : float option;
  }

  let create ~window ~recompute_every =
    { var = Rolling.Rolling_var.create ~window ~recompute_every; last_price = None }


  let update t ~price =
    (match t.last_price with
    | Some prev when prev > 0.0 && price > 0.0 ->
      let r = log (price /. prev) in
        ignore (Rolling.Rolling_var.update t.var r : float)
    | _ -> ()) ;
    t.last_price <- Some price ;
    Rolling.Rolling_var.std_dev t.var


  let value t = Rolling.Rolling_var.std_dev t.var

  let n t = Rolling.Rolling_var.n t.var
end

module Ewma = struct
  type t = {
    var : Filters.Ewma_var.t;
    mutable last_price : float option;
  }

  let create ~period = { var = Filters.Ewma_var.create ~period; last_price = None }

  let update t ~price =
    (match t.last_price with
    | Some prev when prev > 0.0 && price > 0.0 ->
      let r = log (price /. prev) in
        ignore (Filters.Ewma_var.update t.var r : float)
    | _ -> ()) ;
    t.last_price <- Some price ;
    Filters.Ewma_var.std_dev t.var


  let value t = Filters.Ewma_var.std_dev t.var

  let ready t = Filters.Ewma_var.ready t.var
end
