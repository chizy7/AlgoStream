module Sleep = Algostream_common_utils.Time_utils.Sleep

let magic = 0x41534454l

(* v3: added [Trade_print] and [Data_gap] payload constructors at the END of the [Event.payload]
   variant. bin_prot tag-by-source-order means appending preserves wire compatibility for new code
   reading old logs (smaller variant), but old code cannot read new logs. Reader accepts magic +
   version in {2, 3} so v2 fixtures continue to work; writer emits v3. *)
let version = 3l

let supported_versions = [ 2l; 3l ]

let header_size = 64

(* ---- CRC32 (IEEE 802.3, polynomial 0xEDB88320) ---- *)

let crc32_table =
  let t = Array.make 256 0l in
    for n = 0 to 255 do
      let c = ref (Int32.of_int n) in
        for _ = 0 to 7 do
          let bit = Int32.logand !c 1l in
          let shifted = Int32.shift_right_logical !c 1 in
            c := if Int32.equal bit 0l then shifted else Int32.logxor shifted 0xEDB88320l
        done ;
        t.(n) <- !c
    done ;
    t


let crc32 (b : bytes) : int32 =
  let c = ref 0xFFFFFFFFl in
    for i = 0 to Bytes.length b - 1 do
      let byte = Char.code (Bytes.get b i) in
      let idx = Int32.to_int (Int32.logand (Int32.logxor !c (Int32.of_int byte)) 0xFFl) in
        c := Int32.logxor (Int32.shift_right_logical !c 8) crc32_table.(idx)
    done ;
    Int32.logxor !c 0xFFFFFFFFl


(* ---- bin_prot helpers ---- *)

let bin_to_bytes (writer : Event_types.Event.t Bin_prot.Type_class.writer)
  (value : Event_types.Event.t) : bytes =
  let size = writer.size value in
  let buf = Bin_prot.Common.create_buf size in
  let _n = writer.write buf ~pos:0 value in
  let b = Bytes.create size in
    Bin_prot.Common.blit_buf_bytes ~src_pos:0 buf ~dst_pos:0 b ~len:size ;
    b


let bin_of_bytes (reader : Event_types.Event.t Bin_prot.Type_class.reader) (b : bytes) :
  Event_types.Event.t =
  let size = Bytes.length b in
  let buf = Bin_prot.Common.create_buf size in
    Bin_prot.Common.blit_bytes_buf ~src_pos:0 b ~dst_pos:0 buf ~len:size ;
    let pos_ref = ref 0 in
      reader.read buf ~pos_ref


(* ---- Header serialization ---- *)

let write_header_bytes ~record_count ~start_time ~end_time : bytes =
  let b = Bytes.make header_size '\x00' in
    Bytes.set_int32_le b 0 magic ;
    Bytes.set_int32_le b 4 version ;
    Bytes.set_int32_le b 8 0l ;
    (* record_size = 0 (variable) *)
    Bytes.set_int64_le b 12 record_count ;
    Bytes.set_int64_le b 20 start_time ;
    Bytes.set_int64_le b 28 end_time ;
    b


type header = {
  magic : int32;
  version : int32;
  record_size : int32;
  record_count : int64;
  start_time : int64;
  end_time : int64;
}

let parse_header (b : bytes) : header =
  {
    magic = Bytes.get_int32_le b 0;
    version = Bytes.get_int32_le b 4;
    record_size = Bytes.get_int32_le b 8;
    record_count = Bytes.get_int64_le b 12;
    start_time = Bytes.get_int64_le b 20;
    end_time = Bytes.get_int64_le b 28;
  }


(* ---- Writer ---- *)

module Writer = struct
  type t = {
    path : string;
    fd : Unix.file_descr;
    mutable record_count : int64;
    mutable start_time : int64;
    mutable end_time : int64;
  }

  let create path =
    let fd = Unix.openfile path [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o644 in
    (* Write placeholder header; real values written on close. *)
    let header = write_header_bytes ~record_count:0L ~start_time:0L ~end_time:0L in
    let written = Unix.write fd header 0 header_size in
      assert (written = header_size) ;
      { path; fd; record_count = 0L; start_time = 0L; end_time = 0L }


  let append t event =
    let payload = bin_to_bytes Event_types.Event.bin_writer_t event in
    let len = Bytes.length payload in
    let crc = crc32 payload in
    let frame_header = Bytes.create 8 in
      Bytes.set_int32_le frame_header 0 (Int32.of_int len) ;
      Bytes.set_int32_le frame_header 4 crc ;
      let _ = Unix.write t.fd frame_header 0 8 in
      let _ = Unix.write t.fd payload 0 len in
        if Int64.compare t.record_count 0L = 0 then t.start_time <- event.timestamp_ns ;
        t.end_time <- event.timestamp_ns ;
        t.record_count <- Int64.add t.record_count 1L


  let close t =
    (* Rewrite header with final stats. *)
    let header =
      write_header_bytes ~record_count:t.record_count ~start_time:t.start_time ~end_time:t.end_time
    in
    let _ = Unix.lseek t.fd 0 Unix.SEEK_SET in
    let _ = Unix.write t.fd header 0 header_size in
      Unix.close t.fd


  let record_count t = t.record_count
end

(* ---- Reader ---- *)

module Reader = struct
  exception Bad_magic of int32

  exception Bad_version of int32

  type t = {
    path : string;
    fd : Unix.file_descr;
    header : header;
  }

  let read_exact fd buf len =
    let rec loop offset remaining =
      if remaining = 0 then true
      else
        let n = Unix.read fd buf offset remaining in
          if n = 0 then false (* EOF *) else loop (offset + n) (remaining - n) in
      loop 0 len


  let open_ path =
    let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    let header_buf = Bytes.create header_size in
      if not (read_exact fd header_buf header_size) then (
        Unix.close fd ;
        failwith ("event_log: header truncated in " ^ path)) ;
      let header = parse_header header_buf in
        if not (Int32.equal header.magic magic) then (
          Unix.close fd ;
          raise (Bad_magic header.magic)) ;
        if not (List.exists (Int32.equal header.version) supported_versions) then (
          Unix.close fd ;
          raise (Bad_version header.version)) ;
        { path; fd; header }


  let close t = Unix.close t.fd

  let record_count t = t.header.record_count

  let iter t f =
    let frame_header = Bytes.create 8 in
    let count = ref 0 in
    let stop = ref false in
      while not !stop do
        if not (read_exact t.fd frame_header 8) then stop := true
        else
          let len = Int32.to_int (Bytes.get_int32_le frame_header 0) in
          let expected_crc = Bytes.get_int32_le frame_header 4 in
          let payload = Bytes.create len in
            if not (read_exact t.fd payload len) then stop := true
            else if not (Int32.equal (crc32 payload) expected_crc) then
              (* Bad CRC — truncate iteration cleanly. *)
              stop := true
            else
              let event = bin_of_bytes Event_types.Event.bin_reader_t payload in
                f event ;
                incr count
      done ;
      !count
end

(* ---- Replayer ---- *)

let replay bus ~path ?(speed = Float.infinity) ?(filter = Subscription.Filter.any) () =
  let reader = Reader.open_ path in
  let count = ref 0 in
  let last_timestamp = ref None in
  let _ =
    Reader.iter reader (fun event ->
      if Subscription.Filter.matches filter event then (
        (match !last_timestamp with
        | Some prev when Float.is_finite speed && speed > 0.0 ->
          let real_gap_ns = Int64.sub event.timestamp_ns prev in
          let scaled = Int64.of_float (Int64.to_float real_gap_ns /. speed) in
            if Int64.compare scaled 0L > 0 then Sleep.sleep_ns scaled
        | _ -> ()) ;
        Event_bus.publish bus event ;
        last_timestamp := Some event.timestamp_ns ;
        incr count)) in
    Reader.close reader ;
    !count
