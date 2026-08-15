open Base
open Bin_prot.Std
module ZC = Algostream_common_utils.Zero_copy
module Clock = Algostream_common_utils.Time_utils.Clock

module Priority = struct
  type t =
    | Critical
    | High
    | Normal
    | Low
  [@@deriving sexp, bin_io, compare]

  let num_bands = 4

  let to_int = function Critical -> 0 | High -> 1 | Normal -> 2 | Low -> 3

  let of_int_exn = function
    | 0 -> Critical
    | 1 -> High
    | 2 -> Normal
    | 3 -> Low
    | n -> invalid_arg (Printf.sprintf "Priority.of_int_exn: %d" n)


  let to_string = function
    | Critical -> "critical"
    | High -> "high"
    | Normal -> "normal"
    | Low -> "low"
end

module Event = struct
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
        side : string;
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
        side : string;
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

  let message_type_of_payload = function
    | Heartbeat -> ZC.MessageType.heartbeat
    | Shutdown -> ZC.MessageType.shutdown
    | Market_tick _ -> ZC.MessageType.market_data
    | Order_request _ -> ZC.MessageType.order_request
    | Order_response _ -> ZC.MessageType.order_response
    | Trade_execution _ -> ZC.MessageType.trade_execution
    | Risk_alert _ -> ZC.MessageType.risk_alert
    | Strategy_signal _ -> ZC.MessageType.strategy_signal
    | Raw _ -> 0l
    | Trade_print _ -> ZC.MessageType.trade_execution
    | Data_gap _ -> ZC.MessageType.risk_alert


  let symbol_of_payload = function
    | Market_tick { symbol; _ }
    | Order_request { symbol; _ }
    | Trade_execution { symbol; _ }
    | Strategy_signal { symbol; _ }
    | Trade_print { symbol; _ }
    | Data_gap { symbol; _ } ->
      Some symbol
    | _ -> None


  let seq_counter = Atomic.make 0L

  let rec next_sequence_id () =
    let cur = Atomic.get seq_counter in
    let next = Int64.( + ) cur 1L in
      if Atomic.compare_and_set seq_counter cur next then next else next_sequence_id ()


  let create ?(source = "") ~priority payload =
    {
      sequence_id = next_sequence_id ();
      timestamp_ns = Clock.now_monotonic_ns ();
      priority;
      source;
      payload;
    }
end
