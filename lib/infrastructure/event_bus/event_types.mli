(** Event-bus types: priority bands, payloads, and the [Event.t] record.

    All types derive [bin_io] for fast wire/log serialization and [sexp] for debugging. Domain types
    ([Trade.t], [Order.t], [Tick.t]) are intentionally NOT used directly here so that the domain
    layer stays free of [ppx_jane]; convert at the boundary using the helpers exposed in
    [Event.payload]. *)

module Priority : sig
  type t =
    | Critical
    | High
    | Normal
    | Low
  [@@deriving sexp, bin_io, compare]

  (** Band index in [\[0, num_bands\)]. Smaller = higher priority. *)
  val to_int : t -> int

  val num_bands : int

  val of_int_exn : int -> t

  val to_string : t -> string
end

module Event : sig
  type payload =
    | Heartbeat
    | Shutdown
    | Market_tick of {
        symbol : string;
        timestamp_ns : int64;
        price : float;
        volume : float;
        bid : float;
        ask : float;
      }
    | Order_request of {
        order_id : string;
        symbol : string;
        side : string; (* "buy" | "sell" *)
        quantity : float;
        price : float option;
      }
    | Order_response of {
        order_id : string;
        status : string;
        filled_quantity : float;
      }
    | Trade_execution of {
        trade_id : string;
        symbol : string;
        quantity : float;
        price : float;
      }
    | Risk_alert of {
        code : string;
        message : string;
        severity : int;
      }
    | Strategy_signal of {
        strategy_id : string;
        symbol : string;
        action : string;
        strength : float;
      }
    | Raw of bytes
    | Trade_print of {
        trade_id : string;
        symbol : string;
        price : float;
        size : float;
        side : string; (* "buy" | "sell" — exchange tape print *)
        timestamp_ns : int64;
        sequence : int64;
      }
    | Data_gap of {
        symbol : string;
        exchange : string;
        expected_seq : int64;
        received_seq : int64;
        dropped_count : int;
      }
  [@@deriving sexp, bin_io]

  type t = {
    sequence_id : int64;
    timestamp_ns : int64;
    priority : Priority.t;
    source : string;
    payload : payload;
  }
  [@@deriving sexp, bin_io]

  (** Map a payload to the matching [Zero_copy.MessageType] code. Used by [Filter.by_message_type].
  *)
  val message_type_of_payload : payload -> int32

  val symbol_of_payload : payload -> string option

  (** Allocate a fresh, monotonically increasing sequence id. Thread-safe. *)
  val next_sequence_id : unit -> int64

  (** Convenience constructor: stamps [sequence_id] and [timestamp_ns] automatically. *)
  val create : ?source:string -> priority:Priority.t -> payload -> t
end
