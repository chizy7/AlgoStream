module Asset = Algostream_domain_market.Asset
module Order = Algostream_domain_orders.Order

type fee_tier = {
  maker_bps : float;
  taker_bps : float;
  volume_threshold : float;
}

type t = {
  name : string;
  asset_class : Asset.asset_class;
  fee_tiers : fee_tier list;
  base_latency_us : float;
  supports_iceberg : bool;
  supports_stop : bool;
  min_order_size : float;
}

let create ~name ~asset_class ~fee_tiers ~base_latency_us ~supports_iceberg ~supports_stop
  ~min_order_size =
  let sorted = List.sort (fun a b -> compare a.volume_threshold b.volume_threshold) fee_tiers in
    {
      name;
      asset_class;
      fee_tiers = sorted;
      base_latency_us;
      supports_iceberg;
      supports_stop;
      min_order_size;
    }


let effective_fee_bps t ~taker ~monthly_volume =
  let applicable = List.filter (fun tier -> monthly_volume >= tier.volume_threshold) t.fee_tiers in
  let best =
    match List.rev applicable with
    | [] ->
      (match t.fee_tiers with
      | [] -> { maker_bps = 0.0; taker_bps = 0.0; volume_threshold = 0.0 }
      | x :: _ -> x)
    | last :: _ -> last in
    if taker then best.taker_bps else best.maker_bps


let supports t ~kind =
  match kind with
  | Order.Market -> true
  | Order.Limit _ -> true
  | Order.Stop _ -> t.supports_stop
  | Order.Stop_limit _ -> t.supports_stop
  | Order.Iceberg _ -> t.supports_iceberg


let binance_spot =
  create ~name:"binance_spot" ~asset_class:Asset.Crypto
    ~fee_tiers:[ { maker_bps = 10.0; taker_bps = 10.0; volume_threshold = 0.0 } ]
    ~base_latency_us:50_000.0 ~supports_iceberg:true ~supports_stop:true ~min_order_size:10.0


let coinbase_advanced =
  create ~name:"coinbase_advanced" ~asset_class:Asset.Crypto
    ~fee_tiers:[ { maker_bps = 60.0; taker_bps = 80.0; volume_threshold = 0.0 } ]
    ~base_latency_us:75_000.0 ~supports_iceberg:false ~supports_stop:true ~min_order_size:1.0
