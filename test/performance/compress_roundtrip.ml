(** Compression bench + property test.

    Generates 100k random Float64 values (including extremes) plus a monotonic int64 timestamp
    column, encodes both, decodes, and asserts bit-equal round-trip. Reports compression ratio and
    encode/decode throughput. JSON output for github-action-benchmark. *)

module C = Algostream_time_series.Compress
module Clock = Algostream_common_utils.Time_utils.Clock

let n = 100_000

let parse_args () =
  let json = ref None in
  let i = ref 1 in
    while !i < Array.length Sys.argv do
      (match Sys.argv.(!i) with
      | "--json" when !i + 1 < Array.length Sys.argv ->
        json := Some Sys.argv.(!i + 1) ;
        incr i
      | "--help" ->
        print_endline "Usage: compress_roundtrip [--json PATH]" ;
        exit 0
      | other ->
        Printf.eprintf "unknown arg: %s\n" other ;
        exit 2) ;
      incr i
    done ;
    !json


let main () =
  let json_path = parse_args () in
  let rng = Random.State.make [| 7 |] in
  let prices = Bigarray.Array1.create Bigarray.float64 Bigarray.c_layout n in
  let times = Bigarray.Array1.create Bigarray.int64 Bigarray.c_layout n in
  let prev_p = ref 100.0 in
  let prev_t = ref 1_700_000_000_000_000_000L in
    for i = 0 to n - 1 do
      prev_p := !prev_p +. (Random.State.float rng 0.02 -. 0.01) ;
      Bigarray.Array1.set prices i !prev_p ;
      prev_t := Int64.add !prev_t (Int64.of_int (Random.State.int rng 5_000_000)) ;
      Bigarray.Array1.set times i !prev_t
    done ;
    (* Inject extreme values *)
    Bigarray.Array1.set prices 100 Float.nan ;
    Bigarray.Array1.set prices 200 Float.infinity ;
    Bigarray.Array1.set prices 300 Float.neg_infinity ;
    Bigarray.Array1.set prices 400 0.0 ;
    Bigarray.Array1.set prices 500 (Float.neg 0.0) ;
    let t0 = Clock.now_monotonic_ns () in
    let p_bytes = C.encode_float prices in
    let t1 = Clock.now_monotonic_ns () in
    let p2 = C.decode_float p_bytes in
    let t2 = Clock.now_monotonic_ns () in
    let ts_bytes = C.encode_int64 times in
    let t3 = Clock.now_monotonic_ns () in
    let ts2 = C.decode_int64 ts_bytes in
    let t4 = Clock.now_monotonic_ns () in
      for i = 0 to n - 1 do
        let g = Int64.bits_of_float (Bigarray.Array1.get p2 i) in
        let e = Int64.bits_of_float (Bigarray.Array1.get prices i) in
          if not (Int64.equal g e) then (
            Printf.eprintf "FLOAT FIDELITY FAIL at %d\n" i ;
            exit 1) ;
          if not (Int64.equal (Bigarray.Array1.get ts2 i) (Bigarray.Array1.get times i)) then (
            Printf.eprintf "INT64 FIDELITY FAIL at %d\n" i ;
            exit 1)
      done ;
      let raw_p_bytes = n * 8 in
      let raw_t_bytes = n * 8 in
      let p_ratio = float_of_int (Bytes.length p_bytes) /. float_of_int raw_p_bytes in
      let t_ratio = float_of_int (Bytes.length ts_bytes) /. float_of_int raw_t_bytes in
      let p_encode_ns_per = Int64.div (Int64.sub t1 t0) (Int64.of_int n) in
      let p_decode_ns_per = Int64.div (Int64.sub t2 t1) (Int64.of_int n) in
      let t_encode_ns_per = Int64.div (Int64.sub t3 t2) (Int64.of_int n) in
      let t_decode_ns_per = Int64.div (Int64.sub t4 t3) (Int64.of_int n) in
        Printf.printf
          "compress_roundtrip: n=%d float=%.2f bytes/value (ratio %.2f) int64=%.2f bytes/value \
           (ratio %.2f)\n"
          n
          (float_of_int (Bytes.length p_bytes) /. float_of_int n)
          p_ratio
          (float_of_int (Bytes.length ts_bytes) /. float_of_int n)
          t_ratio ;
        Printf.printf
          "                    float encode %Ldns/v decode %Ldns/v ; int64 encode %Ldns/v decode \
           %Ldns/v\n"
          p_encode_ns_per p_decode_ns_per t_encode_ns_per t_decode_ns_per ;
        match json_path with
        | None -> ()
        | Some path ->
          let oc = open_out path in
            Printf.fprintf oc "[\n" ;
            Printf.fprintf oc
              "  \
               {\"name\":\"time_series.compress.float_bytes_per_value\",\"unit\":\"B\",\"value\":%.2f,\"extra\":\"ratio=%.2f\"},\n"
              (float_of_int (Bytes.length p_bytes) /. float_of_int n)
              p_ratio ;
            Printf.fprintf oc
              "  \
               {\"name\":\"time_series.compress.int64_bytes_per_value\",\"unit\":\"B\",\"value\":%.2f,\"extra\":\"ratio=%.2f\"}\n"
              (float_of_int (Bytes.length ts_bytes) /. float_of_int n)
              t_ratio ;
            Printf.fprintf oc "]\n" ;
            close_out oc ;
            Printf.printf "wrote %s\n" path


let () = main ()
