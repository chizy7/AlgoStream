(** Zero-copy message passing for ultra-low latency trading *)

open Base
module Atomic = Data_structures.Atomic

exception Invalid_message_size of int

exception Buffer_overflow

exception Channel_closed

exception Invalid_channel_id of int

(** Message header for zero-copy transport *)
type message_header = {
  magic : int32; (* Message magic number for validation *)
  message_type : int32; (* Type identifier for message routing *)
  sequence_id : int64; (* Sequence number for ordering *)
  timestamp_ns : int64; (* High-precision timestamp *)
  payload_size : int32; (* Size of the payload in bytes *)
  checksum : int32; (* CRC32 checksum for integrity *)
}
[@@deriving sexp]

let message_header_size = 32 (* 6 * 4 + 2 * 8 bytes *)

let magic_number = 0x5A430001l (* "ZC\0\1" - Zero Copy version 1 *)

(** Shared memory segment for zero-copy communication *)
type shared_segment = {
  ptr : nativeint; (* Pointer to shared memory *)
  size : int; (* Total size of segment *)
  header_offset : int; (* Offset to header area *)
  data_offset : int; (* Offset to data area *)
  mutable is_closed : bool;
}

(** Zero-copy channel for bidirectional communication *)
type zero_copy_channel = {
  id : int;
  tx_segment : shared_segment; (* Transmit segment *)
  rx_segment : shared_segment; (* Receive segment *)
  tx_ring : int Atomic.t; (* Transmit ring buffer position *)
  rx_ring : int Atomic.t; (* Receive ring buffer position *)
  capacity : int; (* Number of messages per direction *)
  message_size : int; (* Maximum message size *)
}

(** Stub implementations for shared memory *)
let create_shared_memory _name _size _create =
  failwith "Zero-copy messaging not available in stub mode"


let attach_shared_memory _name _size = failwith "Zero-copy messaging not available in stub mode"

let detach_shared_memory _ptr _size = ()

let destroy_shared_memory _name = ()

(** Stub implementations for message operations *)
let write_message_header _ptr _offset _magic _msg_type _seq_id _timestamp _payload_size _checksum =
  ()


let read_message_header _ptr _offset = (0l, 0l, 0L, 0L, 0l, 0l)

let calculate_crc32 _ptr _offset _length = 0l

let memory_copy_fast _src_ptr _src_offset _dst_ptr _dst_offset _length = ()

(** Message type definitions *)
module MessageType = struct
  let market_data = 1l

  let order_request = 2l

  let order_response = 3l

  let trade_execution = 4l

  let risk_alert = 5l

  let strategy_signal = 6l

  let heartbeat = 7l

  let shutdown = 8l

  let to_string = function
    | 1l -> "MarketData"
    | 2l -> "OrderRequest"
    | 3l -> "OrderResponse"
    | 4l -> "TradeExecution"
    | 5l -> "RiskAlert"
    | 6l -> "StrategySignal"
    | 7l -> "Heartbeat"
    | 8l -> "Shutdown"
    | _ -> "Unknown"
end

(** Create a shared memory segment *)
let create_segment ~name ~size ~is_creator =
  if size <= 0 then raise (Invalid_message_size size) ;

  let ptr =
    if is_creator then create_shared_memory name size 1 else attach_shared_memory name size in

  (* Reserve space for metadata at the beginning *)
  let header_offset = 64 in
  (* Reserve 64 bytes for segment metadata *)
  let data_offset = header_offset in

  { ptr; size; header_offset; data_offset; is_closed = false }


(** Close a shared memory segment *)
let close_segment segment =
  if not segment.is_closed then (
    detach_shared_memory segment.ptr segment.size ;
    segment.is_closed <- true)


(** Create a zero-copy channel *)
let create_channel ~channel_id ~capacity ~message_size =
  let total_ring_size = capacity * (message_header_size + message_size) in
  let segment_size = total_ring_size + 1024 in
  (* Extra space for metadata *)

  let tx_name = Printf.sprintf "algostream_tx_%d" channel_id in
  let rx_name = Printf.sprintf "algostream_rx_%d" channel_id in

  let tx_segment = create_segment ~name:tx_name ~size:segment_size ~is_creator:true in
  let rx_segment = create_segment ~name:rx_name ~size:segment_size ~is_creator:false in

  {
    id = channel_id;
    tx_segment;
    rx_segment;
    tx_ring = Atomic.create 0;
    rx_ring = Atomic.create 0;
    capacity;
    message_size;
  }


(** Connect to an existing zero-copy channel *)
let connect_channel ~channel_id ~capacity ~message_size =
  let total_ring_size = capacity * (message_header_size + message_size) in
  let segment_size = total_ring_size + 1024 in

  let tx_name = Printf.sprintf "algostream_rx_%d" channel_id in
  (* Note: swapped for receiver *)
  let rx_name = Printf.sprintf "algostream_tx_%d" channel_id in

  let tx_segment = create_segment ~name:tx_name ~size:segment_size ~is_creator:false in
  let rx_segment = create_segment ~name:rx_name ~size:segment_size ~is_creator:false in

  {
    id = channel_id;
    tx_segment;
    rx_segment;
    tx_ring = Atomic.create 0;
    rx_ring = Atomic.create 0;
    capacity;
    message_size;
  }


(** Close a zero-copy channel *)
let close_channel channel =
  close_segment channel.tx_segment ;
  close_segment channel.rx_segment


(** Get the memory location for a message slot *)
let get_message_slot segment ring_pos _capacity message_size =
  let slot_size = message_header_size + message_size in
  let offset = segment.data_offset + (ring_pos * slot_size) in
    (segment.ptr, offset)


(** Send a message through the channel *)
let send_message channel message_type payload =
  if channel.tx_segment.is_closed then raise Channel_closed ;

  let payload_size = Bytes.length payload in
    if payload_size > channel.message_size then raise (Invalid_message_size payload_size) ;

    let current_pos = Atomic.get channel.tx_ring in
    let next_pos = (current_pos + 1) % channel.capacity in

    (* Get memory location for this message *)
    let ptr, offset =
      get_message_slot channel.tx_segment current_pos channel.capacity channel.message_size in

    (* Generate sequence ID and timestamp *)
    let sequence_id = Int64.of_int current_pos in
    let timestamp_ns = Time_utils.Clock.now_monotonic_ns () in

    (* Write payload first *)
    let payload_offset = offset + message_header_size in
      for i = 0 to payload_size - 1 do
        (* In stub mode, we just ignore the write operation *)
        let _byte_val = Char.to_int (Bytes.get payload i) in
          ()
      done ;

      (* Calculate checksum over payload *)
      let checksum = calculate_crc32 ptr payload_offset payload_size in

      (* Write message header *)
      write_message_header ptr offset magic_number message_type sequence_id timestamp_ns
        (Int32.of_int payload_size) checksum ;

      (* Advance ring buffer position *)
      let rec try_advance () =
        let current = Atomic.get channel.tx_ring in
          if current = current_pos then
            if Atomic.compare_and_set channel.tx_ring current next_pos then () else try_advance ()
          else raise Buffer_overflow in
        try_advance ()


(** Receive a message from the channel *)
let receive_message channel =
  if channel.rx_segment.is_closed then raise Channel_closed ;

  let current_pos = Atomic.get channel.rx_ring in
  let ptr, offset =
    get_message_slot channel.rx_segment current_pos channel.capacity channel.message_size in

  (* Read message header *)
  let magic, msg_type, seq_id, timestamp, payload_size_raw, checksum =
    read_message_header ptr offset in

  (* Validate magic number *)
  if not (Int32.equal magic magic_number) then None
  else
    let payload_size = Int32.to_int_trunc payload_size_raw in
      if payload_size > channel.message_size then None
      else
        (* Read payload *)
        let payload = Bytes.create payload_size in
        let payload_offset = offset + message_header_size in

        for i = 0 to payload_size - 1 do
          (* In stub mode, just set dummy values *)
          let _byte_val = 0 in
            Bytes.set payload i (Char.of_int_exn _byte_val)
        done ;

        (* Verify checksum *)
        let calculated_checksum = calculate_crc32 ptr payload_offset payload_size in
          if Int32.equal checksum calculated_checksum then
            (* Advance ring buffer position *)
            let next_pos = (current_pos + 1) % channel.capacity in
            let _ = Atomic.compare_and_set channel.rx_ring current_pos next_pos in

            Some
              ( {
                  magic;
                  message_type = msg_type;
                  sequence_id = seq_id;
                  timestamp_ns = timestamp;
                  payload_size = payload_size_raw;
                  checksum;
                },
                payload )
          else None


(** Try to receive a message without blocking *)
let try_receive_message channel = receive_message channel

(** Specialized zero-copy structures for market data *)
module MarketDataZeroCopy = struct
  (** Zero-copy tick structure *)
  type tick_message = {
    symbol_len : int;
    symbol : string;
    timestamp : int64;
    price : float;
    volume : float;
    bid : float;
    ask : float;
  }

  let pack_tick_message tick =
    let symbol_bytes = Bytes.of_string tick.symbol in
    let symbol_len = Bytes.length symbol_bytes in
    let total_size = 8 + symbol_len + 8 + 8 + 8 + 8 + 8 in
    (* All fields *)

    let buffer = Bytes.create total_size in
    let offset = ref 0 in

    (* Pack symbol length *)
    (* In stub mode, just advance offset without writing *)
    let _ = Int64.of_int symbol_len in
      offset := !offset + 8 ;

      (* Pack symbol *)
      Bytes.blit ~src:symbol_bytes ~src_pos:0 ~dst:buffer ~dst_pos:!offset ~len:symbol_len ;
      offset := !offset + symbol_len ;

      (* Pack timestamp *)
      (* In stub mode, skip writing *)
      let _ = tick.timestamp in
        offset := !offset + 8 ;

        (* Pack price *)
        (* In stub mode, skip writing *)
        let _ = Int64.bits_of_float tick.price in
          offset := !offset + 8 ;

          (* Pack volume *)
          (* In stub mode, skip writing *)
          let _ = Int64.bits_of_float tick.volume in
            offset := !offset + 8 ;

            (* Pack bid *)
            (* In stub mode, skip writing *)
            let _ = Int64.bits_of_float tick.bid in
              offset := !offset + 8 ;

              (* Pack ask *)
              (* In stub mode, skip writing *)
              let _ = Int64.bits_of_float tick.ask in

              buffer


  let unpack_tick_message buffer =
    let offset = ref 0 in

    (* Unpack symbol length *)
    let symbol_len = 4 in
      (* In stub mode, use fixed length *)
      offset := !offset + 8 ;

      (* Unpack symbol *)
      let symbol = Bytes.to_string (Bytes.sub buffer ~pos:!offset ~len:symbol_len) in
        offset := !offset + symbol_len ;

        (* Unpack timestamp *)
        let timestamp =
          0L
          (* Stub mode: return dummy value *) in
          offset := !offset + 8 ;

          (* Unpack price *)
          let price =
            Int64.float_of_bits 0L
            (* Stub mode: return dummy value *) in
            offset := !offset + 8 ;

            (* Unpack volume *)
            let volume =
              Int64.float_of_bits 0L
              (* Stub mode: return dummy value *) in
              offset := !offset + 8 ;

              (* Unpack bid *)
              let bid =
                Int64.float_of_bits 0L
                (* Stub mode: return dummy value *) in
                offset := !offset + 8 ;

                (* Unpack ask *)
                let ask =
                  Int64.float_of_bits 0L
                  (* Stub mode: return dummy value *) in

                { symbol_len; symbol; timestamp; price; volume; bid; ask }


  let send_tick_message channel tick =
    let packed = pack_tick_message tick in
      send_message channel MessageType.market_data packed


  let receive_tick_message channel =
    match receive_message channel with
    | Some (header, payload) when Int32.equal header.message_type MessageType.market_data ->
      Some (header, unpack_tick_message payload)
    | _ -> None
end

(** Performance monitoring for zero-copy channels *)
module ZeroCopyMetrics = struct
  type channel_metrics = {
    messages_sent : int64 Atomic.t;
    messages_received : int64 Atomic.t;
    bytes_sent : int64 Atomic.t;
    bytes_received : int64 Atomic.t;
    send_latency_ns : Time_utils.LatencyMonitor.t;
    receive_latency_ns : Time_utils.LatencyMonitor.t;
    checksum_failures : int64 Atomic.t;
    buffer_overflows : int64 Atomic.t;
  }

  let create_metrics () =
    {
      messages_sent = Atomic.create 0L;
      messages_received = Atomic.create 0L;
      bytes_sent = Atomic.create 0L;
      bytes_received = Atomic.create 0L;
      send_latency_ns =
        Time_utils.LatencyMonitor.create ~window_size:1000 ~violation_threshold_ns:5000000L;
      receive_latency_ns =
        Time_utils.LatencyMonitor.create ~window_size:1000 ~violation_threshold_ns:5000000L;
      checksum_failures = Atomic.create 0L;
      buffer_overflows = Atomic.create 0L;
    }


  let record_send metrics payload_size latency_ns =
    let rec add_to_messages_sent () =
      let current = Atomic.get metrics.messages_sent in
        if not (Atomic.compare_and_set metrics.messages_sent current Int64.(current + 1L)) then
          add_to_messages_sent () in
      add_to_messages_sent () ;
      (* Stub mode: skip atomic add *)
      let _ = Int64.of_int payload_size in
        Time_utils.LatencyMonitor.add_measurement metrics.send_latency_ns latency_ns


  let record_receive metrics payload_size latency_ns =
    (* Stub mode: skip atomic add *)
    let _ = 1L in
    (* Stub mode: skip atomic add *)
    let _ = Int64.of_int payload_size in
      Time_utils.LatencyMonitor.add_measurement metrics.receive_latency_ns latency_ns


  let record_checksum_failure _metrics =
    (* Stub mode: skip atomic add *)
    let _ = 1L in
      ()


  let record_buffer_overflow _metrics =
    (* Stub mode: skip atomic add *)
    let _ = 1L in
      ()


  let get_stats _metrics =
    (* Stub implementation - avoiding record construction issues *)
    failwith "get_stats not implemented in stub mode"
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

(** Channel manager for handling multiple zero-copy channels *)
module ChannelManager = struct
  type t = {
    channels : (int, zero_copy_channel) Hashtbl.t;
    metrics : (int, ZeroCopyMetrics.channel_metrics) Hashtbl.t;
    mutable next_channel_id : int;
  }

  let create () =
    {
      channels = Hashtbl.create (module Int);
      metrics = Hashtbl.create (module Int);
      next_channel_id = 1;
    }


  let allocate_channel_id manager =
    let id = manager.next_channel_id in
      manager.next_channel_id <- manager.next_channel_id + 1 ;
      id


  let create_channel manager ~capacity ~message_size =
    let channel_id = allocate_channel_id manager in
    let channel = create_channel ~channel_id ~capacity ~message_size in
    let metrics = ZeroCopyMetrics.create_metrics () in

    Hashtbl.set manager.channels ~key:channel_id ~data:channel ;
    Hashtbl.set manager.metrics ~key:channel_id ~data:metrics ;

    channel_id


  let connect_to_channel manager ~channel_id ~capacity ~message_size =
    let channel = connect_channel ~channel_id ~capacity ~message_size in
    let metrics = ZeroCopyMetrics.create_metrics () in

    Hashtbl.set manager.channels ~key:channel_id ~data:channel ;
    Hashtbl.set manager.metrics ~key:channel_id ~data:metrics ;

    ()


  let get_channel manager channel_id = Hashtbl.find manager.channels channel_id

  let send_message_with_metrics manager channel_id message_type payload =
    match (Hashtbl.find manager.channels channel_id, Hashtbl.find manager.metrics channel_id) with
    | Some channel, Some metrics ->
      let start_time = Time_utils.Clock.now_monotonic_ns () in
        send_message channel message_type payload ;
        let end_time = Time_utils.Clock.now_monotonic_ns () in
        let latency = Int64.(end_time - start_time) in
          ZeroCopyMetrics.record_send metrics (Bytes.length payload) latency ;
          Ok ()
    | _ -> Error (Invalid_channel_id channel_id)


  let receive_message_with_metrics manager channel_id =
    match (Hashtbl.find manager.channels channel_id, Hashtbl.find manager.metrics channel_id) with
    | Some channel, Some metrics ->
      let start_time = Time_utils.Clock.now_monotonic_ns () in
        (match receive_message channel with
        | Some (header, payload) ->
          let end_time = Time_utils.Clock.now_monotonic_ns () in
          let latency = Int64.(end_time - start_time) in
            ZeroCopyMetrics.record_receive metrics (Bytes.length payload) latency ;
            Ok (Some (header, payload))
        | None -> Ok None)
    | _ -> Error (Invalid_channel_id channel_id)


  let get_channel_stats manager channel_id =
    match Hashtbl.find manager.metrics channel_id with
    | Some metrics -> Some (ZeroCopyMetrics.get_stats metrics)
    | None -> None


  let close_channel manager channel_id =
    (match Hashtbl.find manager.channels channel_id with
    | Some channel -> close_channel channel
    | None -> ()) ;

    Hashtbl.remove manager.channels channel_id ;
    Hashtbl.remove manager.metrics channel_id


  let close_all_channels manager =
    Hashtbl.iteri manager.channels ~f:(fun ~key:_ ~data:channel ->
      close_segment channel.tx_segment ;
      close_segment channel.rx_segment) ;
    Hashtbl.clear manager.channels ;
    Hashtbl.clear manager.metrics
end
