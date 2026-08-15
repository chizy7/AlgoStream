(** Typed trading venue with fee tiers and supported order kinds.

    Today the [exchange] field on [Algostream_domain_orders.Order.order] is just an untyped string.
    This module introduces a structured [Venue.t] consumed by the [Routing] layer — callers continue
    to set the [exchange] string on submitted orders for compatibility, but routing decisions are
    made against the typed value. *)

module Asset = Algostream_domain_market.Asset
module Order = Algostream_domain_orders.Order

type fee_tier = {
  maker_bps : float;
  taker_bps : float;
  volume_threshold : float;
    (** monthly notional above which this tier applies (USD, asset-class native units) *)
}

type t = {
  name : string;
  asset_class : Asset.asset_class;
  fee_tiers : fee_tier list;  (** sorted ascending by [volume_threshold] *)
  base_latency_us : float;
  supports_iceberg : bool;
  supports_stop : bool;
  min_order_size : float;
}

val create :
  name:string ->
  asset_class:Asset.asset_class ->
  fee_tiers:fee_tier list ->
  base_latency_us:float ->
  supports_iceberg:bool ->
  supports_stop:bool ->
  min_order_size:float ->
  t

(** Effective fee in basis points at the caller's monthly trading volume. *)
val effective_fee_bps : t -> taker:bool -> monthly_volume:float -> float

(** Whether the venue supports the given order kind. *)
val supports : t -> kind:Order.order_type -> bool

(** Sensible defaults baked in, mirroring the per-exchange table in [lib/normalization/symbol.ml].
    These are coarse approximations — verify against the venue's published schedule before routing
    real flow. *)
val binance_spot : t

val coinbase_advanced : t
