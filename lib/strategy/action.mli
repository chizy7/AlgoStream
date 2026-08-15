(** What a strategy emits.

    [on_event] {b returns} actions rather than calling a submit callback. Three things fall out of
    that choice:

    - a strategy is testable as a pure function — feed events, assert the action list, no engine
      required;
    - order-id assignment, risk gating and venue routing stay in the engine where they belong;
    - the same [Strategy.S] can be driven by a backtest or by a live runner, because neither is
      baked into the emit path.

    An intent describes {i what} the strategy wants. Turning it into an [Order.order] on a venue is
    the engine's job. *)

module Order = Algostream_domain_orders.Order

type urgency =
  | Passive
    (** prefer to rest at the touch and earn the maker fee; the fill engine simulates queue position
    *)
  | Normal
  | Aggressive  (** cross the spread now, accept the taker fee *)

type intent = {
  symbol : string;
  side : Side.t;
  quantity : float;  (** must be positive; direction lives in [side] *)
  order_type : Order.order_type;
  time_in_force : Order.time_in_force;
  client_order_id : string;
    (** strategy-assigned and strategy-unique; the engine assigns venue ids *)
  strategy_id : string;
  urgency : urgency;
    (** advisory to the fill model only — it never silently rewrites [order_type] *)
  tag : string;  (** free-form; lands in the blotter row so a fill can be traced to its reason *)
}

type t =
  | Submit of intent
  | Cancel of string  (** client_order_id *)
  | Replace of {
      client_order_id : string;
      new_quantity : float option;
      new_price : float option;
    }
  | Set_timer of {
      ts_ns : int64;
      tag : string;
    }
  | Log of string

(** Convenience constructor with sensible defaults: [Good_till_cancel], [Normal] urgency, empty tag.
    Raises [Invalid_argument] on a non-positive quantity — a zero-size order is always a bug in the
    caller's sizing, and failing loudly beats a silent no-op. *)
val submit :
  symbol:string ->
  side:Side.t ->
  quantity:float ->
  order_type:Order.order_type ->
  ?time_in_force:Order.time_in_force ->
  ?urgency:urgency ->
  ?tag:string ->
  client_order_id:string ->
  strategy_id:string ->
  unit ->
  t

val urgency_to_string : urgency -> string

val to_string : t -> string
