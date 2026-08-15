module EB = Algostream_infrastructure_event_bus
module Log = EB.Event_log
module Event = EB.Event_types.Event
module Priority = EB.Event_types.Priority

let make_event ~i =
  let payload =
    if i mod 3 = 0 then Event.Heartbeat
    else if i mod 3 = 1 then
      Event.Market_tick
        {
          symbol = Printf.sprintf "SYM%d" (i mod 10);
          timestamp_ns = Int64.of_int (i * 1000);
          price = 100.0 +. Float.of_int i;
          volume = Float.of_int i;
          bid = 99.0;
          ask = 101.0;
        }
    else
      Event.Trade_execution
        {
          trade_id = Printf.sprintf "T%d" i;
          symbol = "AAPL";
          quantity = Float.of_int (i + 1);
          price = 150.0;
        } in
  let p =
    match i mod 4 with
    | 0 -> Priority.Critical
    | 1 -> Priority.High
    | 2 -> Priority.Normal
    | _ -> Priority.Low in
    Event.create ~source:"test" ~priority:p payload


let with_temp_file f =
  let path = Filename.temp_file "algostream_log_" ".bin" in
  let result =
    try f path
    with e ->
      (try Unix.unlink path with _ -> ()) ;
      raise e in
    (try Unix.unlink path with _ -> ()) ;
    result


let test_round_trip () =
  with_temp_file (fun path ->
    let n = 1000 in
    let written = Array.init n (fun i -> make_event ~i) in
    let w = Log.Writer.create path in
      Array.iter (fun e -> Log.Writer.append w e) written ;
      Log.Writer.close w ;
      let r = Log.Reader.open_ path in
        Alcotest.(check int64) "record_count" (Int64.of_int n) (Log.Reader.record_count r) ;
        let read = ref [] in
        let count = Log.Reader.iter r (fun e -> read := e :: !read) in
          Log.Reader.close r ;
          Alcotest.(check int) "iter count" n count ;
          let read_arr = Array.of_list (List.rev !read) in
            Alcotest.(check int) "round-trip count" n (Array.length read_arr) ;
            for i = 0 to n - 1 do
              Alcotest.(check int64)
                (Printf.sprintf "seq[%d]" i) written.(i).sequence_id read_arr.(i).sequence_id
            done)


let test_header_validation () =
  with_temp_file (fun path ->
    let w = Log.Writer.create path in
      Log.Writer.append w (make_event ~i:0) ;
      Log.Writer.close w ;
      (* Corrupt the magic. *)
      let fd = Unix.openfile path [ Unix.O_WRONLY ] 0 in
      let bad = Bytes.make 4 '\x00' in
      let _ = Unix.write fd bad 0 4 in
        Unix.close fd ;
        Alcotest.check_raises "bad magic raises" (Log.Reader.Bad_magic 0l) (fun () ->
          ignore (Log.Reader.open_ path)))


let test_truncated_frame_recovery () =
  with_temp_file (fun path ->
    let w = Log.Writer.create path in
      for i = 0 to 9 do
        Log.Writer.append w (make_event ~i)
      done ;
      Log.Writer.close w ;
      (* Truncate the file: keep header + 5 frames + a partial frame header. *)
      let original_size = (Unix.stat path).st_size in
      let truncated_size = original_size - 12 in
      let fd = Unix.openfile path [ Unix.O_RDWR ] 0 in
        Unix.ftruncate fd truncated_size ;
        Unix.close fd ;
        let r = Log.Reader.open_ path in
        let count = Log.Reader.iter r (fun _ -> ()) in
          Log.Reader.close r ;
          (* Should read all complete frames without raising. The exact count depends on frame
             sizes; just assert we got at least a few and didn't blow up. *)
          Alcotest.(check bool) "recovered some events" true (count > 0 && count <= 10))


let test_corrupt_crc_truncates () =
  with_temp_file (fun path ->
    let w = Log.Writer.create path in
      for i = 0 to 4 do
        Log.Writer.append w (make_event ~i)
      done ;
      Log.Writer.close w ;
      (* Corrupt one byte well inside the first frame's payload. Offset 80 is eight bytes past the
         64-byte header plus the frame's 4-byte length and 4-byte CRC, so it lands in the encoded
         [timestamp_ns].

         Read-then-flip rather than store a constant. This used to write '\xFF' unconditionally,
         which is a no-op on the roughly 1-in-256 runs where the byte already was '\xFF' — and since
         [timestamp_ns] is stamped from the clock, that byte differs every run. The test then read
         all five records back and failed. Flipping every bit guarantees a different byte whatever
         was there, so the corruption is certain instead of probable. *)
      let fd = Unix.openfile path [ Unix.O_RDWR ] 0 in
      let _ = Unix.lseek fd 80 Unix.SEEK_SET in
      let buf = Bytes.create 1 in
      let _ = Unix.read fd buf 0 1 in
      let flipped = Char.chr (Char.code (Bytes.get buf 0) lxor 0xFF) in
      let _ = Unix.lseek fd 80 Unix.SEEK_SET in
      let _ = Unix.write fd (Bytes.make 1 flipped) 0 1 in
        Unix.close fd ;
        let r = Log.Reader.open_ path in
        let count = Log.Reader.iter r (fun _ -> ()) in
          Log.Reader.close r ;
          (* CRC failure halts iteration; should yield strictly fewer than 5. *)
          Alcotest.(check bool) "stopped early on CRC failure" true (count < 5))


let suite =
  [
    Alcotest.test_case "round_trip" `Quick test_round_trip;
    Alcotest.test_case "header_validation" `Quick test_header_validation;
    Alcotest.test_case "truncated_frame_recovery" `Quick test_truncated_frame_recovery;
    Alcotest.test_case "corrupt_crc_truncates" `Quick test_corrupt_crc_truncates;
  ]
