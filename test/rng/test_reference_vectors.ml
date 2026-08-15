(* Spec conformance, deliberately using golden values.

   The house convention elsewhere is to assert run-twice equality and statistical properties rather
   than pinned numbers, because pinned numbers make legitimate numerical improvements look like
   regressions. This file is the documented exception: xoshiro256++ and SplitMix64 are published
   specifications, so a divergence here means our generator no longer implements the algorithm it
   claims to — and a backtest published against it would stop reproducing.

   What is and is not asserted, stated honestly:

   - The SplitMix64 vectors below are the published first eight outputs from seed 0. - The
   xoshiro256++ check does NOT use a pinned output table. It runs a second, independently written
   implementation of the published state transition and compares it against {!Rng}, starting from
   the state that {!Rng.create} is specified to produce. Two implementations written from the same
   spec agreeing is weaker than checking against upstream's own vector file, but it catches
   transcription errors in either copy, which is the realistic failure mode. The one value derived
   fully by hand ([rotl(s0 + s3, 23) + s0] from state (1,2,3,4)) is checked explicitly as an
   anchor. *)

module Rng = Algostream_rng.Rng

let hex x = Printf.sprintf "%Lx" x

(* ───── SplitMix64: published vectors from seed 0 ──────────────────── *)

let splitmix64_seed0 =
  [|
    0xE220A8397B1DCDAFL;
    0x6E789E6AA1B965F4L;
    0x06C45D188009454FL;
    0xF88BB8A8724C81ECL;
    0x1B39896A51A8749BL;
    0x53CB9F0C747EA2EAL;
    0x2C829ABE1F4532E1L;
    0xC584133AC916AB3CL;
  |]


let splitmix64_stream seed =
  let state = ref seed in
    fun () ->
      let z = Int64.add !state 0x9E3779B97F4A7C15L in
        state := z ;
        let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 30)) 0xBF58476D1CE4E5B9L in
        let z = Int64.mul (Int64.logxor z (Int64.shift_right_logical z 27)) 0x94D049BB133111EBL in
          Int64.logxor z (Int64.shift_right_logical z 31)


let test_splitmix64_matches_published_vectors () =
  let next = splitmix64_stream 0L in
    Array.iteri
      (fun i expected ->
        Alcotest.(check string)
          (Printf.sprintf "splitmix64(seed=0) output %d" i)
          (hex expected)
          (hex (next ())))
      splitmix64_seed0


(* ───── xoshiro256++: independent implementation ───────────────────── *)

let rotl x k = Int64.logor (Int64.shift_left x k) (Int64.shift_right_logical x (64 - k))

let xoshiro_stream s0 s1 s2 s3 =
  let s = [| s0; s1; s2; s3 |] in
    fun () ->
      let result = Int64.add (rotl (Int64.add s.(0) s.(3)) 23) s.(0) in
      let t = Int64.shift_left s.(1) 17 in
        s.(2) <- Int64.logxor s.(2) s.(0) ;
        s.(3) <- Int64.logxor s.(3) s.(1) ;
        s.(1) <- Int64.logxor s.(1) s.(2) ;
        s.(0) <- Int64.logxor s.(0) s.(3) ;
        s.(2) <- Int64.logxor s.(2) t ;
        s.(3) <- rotl s.(3) 45 ;
        result


(* The one value derived entirely by hand, as an anchor against both implementations drifting
   together: from state (1, 2, 3, 4) the first output is rotl(1 + 4, 23) + 1 = (5 << 23) + 1. *)
let test_xoshiro_first_output_hand_derived () =
  let next = xoshiro_stream 1L 2L 3L 4L in
  let expected = Int64.add (Int64.shift_left 5L 23) 1L in
    Alcotest.(check string)
      "xoshiro256++(1,2,3,4) output 0 = (5 << 23) + 1" (hex expected)
      (hex (next ())) ;
    Alcotest.(check string) "which is 0x2800001" "2800001" (hex expected)


(* End-to-end: Rng.create ~seed:0 must expand the seed through SplitMix64 into the four state words
   above, then run xoshiro256++ over them. Both halves of that are verified independently, so
   agreement here is a genuine conformance check of the shipped generator. *)
let test_rng_create_conforms_to_spec () =
  let next_ref =
    xoshiro_stream splitmix64_seed0.(0) splitmix64_seed0.(1) splitmix64_seed0.(2)
      splitmix64_seed0.(3) in
  let r = Rng.create ~seed:0 in
    for i = 0 to 31 do
      Alcotest.(check string)
        (Printf.sprintf "Rng.create(0) output %d matches spec" i)
        (hex (next_ref ()))
        (hex (Rng.bits r))
    done


(* Same check one level up: substream must be seed-expansion of (root_seed + index * golden). *)
let test_substream_conforms_to_spec () =
  let root = 12345L and index = 7 in
  let expanded =
    splitmix64_stream (Int64.add root (Int64.mul (Int64.of_int index) 0x9E3779B97F4A7C15L)) in
  let s0 = expanded () in
  let s1 = expanded () in
  let s2 = expanded () in
  let s3 = expanded () in
  let next_ref = xoshiro_stream s0 s1 s2 s3 in
  let r = Rng.substream ~root_seed:root ~index in
    for i = 0 to 15 do
      Alcotest.(check string)
        (Printf.sprintf "substream(12345, 7) output %d matches spec" i)
        (hex (next_ref ()))
        (hex (Rng.bits r))
    done


let suite =
  [
    Alcotest.test_case "splitmix64_matches_published_vectors" `Quick
      test_splitmix64_matches_published_vectors;
    Alcotest.test_case "xoshiro_first_output_hand_derived" `Quick
      test_xoshiro_first_output_hand_derived;
    Alcotest.test_case "rng_create_conforms_to_spec" `Quick test_rng_create_conforms_to_spec;
    Alcotest.test_case "substream_conforms_to_spec" `Quick test_substream_conforms_to_spec;
  ]
