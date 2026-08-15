module Order = Algostream_domain_orders.Order

type venue_snapshot = {
  venue : Venue.t;
  best_bid : float;
  best_ask : float;
  bid_depth : float;
  ask_depth : float;
  monthly_volume : float;
}

type routing_strategy =
  | Cheapest_venue
  | Best_price
  | Smart_split

type allocation = {
  venue_name : string;
  quantity : float;
  expected_price : float;
  expected_fee_bps : float;
}

type routing_decision = {
  strategy : routing_strategy;
  allocations : allocation list;
  expected_avg_price : float;
  expected_cost_bps : float;
  unallocated : float;
  rationale : string;
}

let venue_price ~side ~(snap : venue_snapshot) =
  match side with Order.Buy -> snap.best_ask | Order.Sell -> snap.best_bid


let venue_depth ~side ~(snap : venue_snapshot) =
  match side with Order.Buy -> snap.ask_depth | Order.Sell -> snap.bid_depth


let venue_fee_bps ~(snap : venue_snapshot) =
  Venue.effective_fee_bps snap.venue ~taker:true ~monthly_volume:snap.monthly_volume


let effective_cost ~side ~(snap : venue_snapshot) =
  let p = venue_price ~side ~snap in
  let f = venue_fee_bps ~snap in
    match side with
    | Order.Buy -> p *. (1.0 +. (f *. 1e-4))
    | Order.Sell -> p *. (1.0 -. (f *. 1e-4))


let eligible_for (order : Order.order) (snaps : venue_snapshot list) =
  List.filter (fun s -> Venue.supports s.venue ~kind:order.order_type) snaps


let empty_decision strategy ~unallocated rationale =
  {
    strategy;
    allocations = [];
    expected_avg_price = 0.0;
    expected_cost_bps = 0.0;
    unallocated;
    rationale;
  }


let route_cheapest ~(order : Order.order) ~venues =
  let side = order.side in
  let eligible = eligible_for order venues in
    match eligible with
    | [] -> empty_decision Cheapest_venue ~unallocated:order.quantity "no venue supports order kind"
    | _ ->
      let sorted =
        List.sort (fun a b -> compare (venue_fee_bps ~snap:a) (venue_fee_bps ~snap:b)) eligible
      in
      let pick = List.hd sorted in
      let fill_qty = Float.min order.quantity (venue_depth ~side ~snap:pick) in
      let alloc =
        {
          venue_name = pick.venue.name;
          quantity = fill_qty;
          expected_price = venue_price ~side ~snap:pick;
          expected_fee_bps = venue_fee_bps ~snap:pick;
        } in
        {
          strategy = Cheapest_venue;
          allocations = [ alloc ];
          expected_avg_price = alloc.expected_price;
          expected_cost_bps = alloc.expected_fee_bps;
          unallocated = order.quantity -. fill_qty;
          rationale = Printf.sprintf "cheapest-fee venue: %s" pick.venue.name;
        }


let route_best_price ~(order : Order.order) ~venues =
  let side = order.side in
  let eligible = eligible_for order venues in
    match eligible with
    | [] -> empty_decision Best_price ~unallocated:order.quantity "no venue supports order kind"
    | _ ->
      let cmp a b =
        match side with
        | Order.Buy -> compare (venue_price ~side ~snap:a) (venue_price ~side ~snap:b)
        | Order.Sell -> compare (venue_price ~side ~snap:b) (venue_price ~side ~snap:a) in
      let sorted = List.sort cmp eligible in
      let pick = List.hd sorted in
      let fill_qty = Float.min order.quantity (venue_depth ~side ~snap:pick) in
      let alloc =
        {
          venue_name = pick.venue.name;
          quantity = fill_qty;
          expected_price = venue_price ~side ~snap:pick;
          expected_fee_bps = venue_fee_bps ~snap:pick;
        } in
        {
          strategy = Best_price;
          allocations = [ alloc ];
          expected_avg_price = alloc.expected_price;
          expected_cost_bps = alloc.expected_fee_bps;
          unallocated = order.quantity -. fill_qty;
          rationale =
            Printf.sprintf "best-price venue: %s @ %g" pick.venue.name alloc.expected_price;
        }


let route_smart_split ~(order : Order.order) ~venues =
  let side = order.side in
  let eligible = eligible_for order venues in
    match eligible with
    | [] -> empty_decision Smart_split ~unallocated:order.quantity "no venue supports order kind"
    | _ ->
      let cmp a b =
        let ca = effective_cost ~side ~snap:a in
        let cb = effective_cost ~side ~snap:b in
          match side with Order.Buy -> compare ca cb | Order.Sell -> compare cb ca in
      let sorted = List.sort cmp eligible in
      let remaining = ref order.quantity in
      let allocs = ref [] in
        List.iter
          (fun (snap : venue_snapshot) ->
            if !remaining > 0.0 then
              let depth = venue_depth ~side ~snap in
              let take = Float.min !remaining depth in
                if take > 0.0 then (
                  allocs :=
                    {
                      venue_name = snap.venue.name;
                      quantity = take;
                      expected_price = venue_price ~side ~snap;
                      expected_fee_bps = venue_fee_bps ~snap;
                    }
                    :: !allocs ;
                  remaining := !remaining -. take))
          sorted ;
        let allocations = List.rev !allocs in
        let total_qty =
          List.fold_left (fun acc (a : allocation) -> acc +. a.quantity) 0.0 allocations in
        let total_value =
          List.fold_left
            (fun acc (a : allocation) -> acc +. (a.quantity *. a.expected_price))
            0.0 allocations in
        let avg_price = if total_qty > 0.0 then total_value /. total_qty else 0.0 in
        let avg_fee =
          if total_qty > 0.0 then
            List.fold_left
              (fun acc (a : allocation) -> acc +. (a.quantity *. a.expected_fee_bps))
              0.0 allocations
            /. total_qty
          else 0.0 in
          {
            strategy = Smart_split;
            allocations;
            expected_avg_price = avg_price;
            expected_cost_bps = avg_fee;
            unallocated = !remaining;
            rationale = Printf.sprintf "smart-split across %d venues" (List.length allocations);
          }


let route ~order ~venues ?(strategy = Smart_split) () =
  match strategy with
  | Cheapest_venue -> route_cheapest ~order ~venues
  | Best_price -> route_best_price ~order ~venues
  | Smart_split -> route_smart_split ~order ~venues
