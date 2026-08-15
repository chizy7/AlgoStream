(** Zero-copy message passing for ultra-low latency trading *)

exception Invalid_message_size of int

exception Buffer_overflow

exception Channel_closed

exception Invalid_channel_id of int

(** Message header for zero-copy transport *)
type message_header = {
  magic : int32;
  message_type : int32;
  sequence_id : int64;
  timestamp_ns : int64;
  payload_size : int32;
  checksum : int32;
}
[@@deriving sexp]

val message_header_size : int

val magic_number : int32

(** Zero-copy channel for bidirectional communication *)
type zero_copy_channel

(** Message type definitions *)
module MessageType : sig
  val market_data : int32

  val order_request : int32

  val order_response : int32

  val trade_execution : int32

  val risk_alert : int32

  val strategy_signal : int32

  val heartbeat : int32

  val shutdown : int32

  val to_string : int32 -> string
end

(** Create a zero-copy channel *)
val create_channel : channel_id:int -> capacity:int -> message_size:int -> zero_copy_channel

(** Connect to an existing zero-copy channel *)
val connect_channel : channel_id:int -> capacity:int -> message_size:int -> zero_copy_channel

(** Close a zero-copy channel *)
val close_channel : zero_copy_channel -> unit

(** Send a message through the channel *)
val send_message : zero_copy_channel -> int32 -> bytes -> unit

(** Receive a message from the channel *)
val receive_message : zero_copy_channel -> (message_header * bytes) option

(** Try to receive a message without blocking *)
val try_receive_message : zero_copy_channel -> (message_header * bytes) option

(** Specialized zero-copy structures for market data *)
module MarketDataZeroCopy : sig
  type tick_message = {
    symbol_len : int;
    symbol : string;
    timestamp : int64;
    price : float;
    volume : float;
    bid : float;
    ask : float;
  }

  val pack_tick_message : tick_message -> bytes

  val unpack_tick_message : bytes -> tick_message

  val send_tick_message : zero_copy_channel -> tick_message -> unit

  val receive_tick_message : zero_copy_channel -> (message_header * tick_message) option
end

(** Channel statistics *)
type channel_stats = {
  messages_sent : int64;
  messages_received : int64;
  bytes_sent : int64;
  bytes_received : int64;
  avg_send_latency_ns : int64;
  avg_receive_latency_ns : int64;
  checksum_failures : int64;
  buffer_overflows : int64;
}

(** Performance monitoring for zero-copy channels *)
module ZeroCopyMetrics : sig
  type channel_metrics

  val create_metrics : unit -> channel_metrics

  val record_send : channel_metrics -> int -> int64 -> unit

  val record_receive : channel_metrics -> int -> int64 -> unit

  val record_checksum_failure : channel_metrics -> unit

  val record_buffer_overflow : channel_metrics -> unit

  val get_stats : channel_metrics -> channel_stats
end

(** Channel manager for handling multiple zero-copy channels *)
module ChannelManager : sig
  type t

  val create : unit -> t

  val create_channel : t -> capacity:int -> message_size:int -> int

  val connect_to_channel : t -> channel_id:int -> capacity:int -> message_size:int -> unit

  val get_channel : t -> int -> zero_copy_channel option

  val send_message_with_metrics : t -> int -> int32 -> bytes -> (unit, exn) result

  val receive_message_with_metrics : t -> int -> ((message_header * bytes) option, exn) result

  val get_channel_stats : t -> int -> channel_stats option

  val close_channel : t -> int -> unit

  val close_all_channels : t -> unit
end
