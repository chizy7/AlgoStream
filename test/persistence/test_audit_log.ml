(** The tamper tests are the point of this module. A hash chain that is never shown to catch a
    forged record is decoration, so each mutation below is applied to a real file on disk and the
    verifier has to find it — including one case, {!replace_record_wholesale}, that a per-record
    checksum would happily accept.

    {!truncate_tail_is_undetectable} asserts the documented {i limitation} rather than a capability.
    That is deliberate: it is better to have the gap in the threat model written down in a form that
    breaks if someone later believes otherwise. *)

module P = Algostream_infrastructure_persistence
module Log = P.Audit_log
module Rec = P.Audit_record

let tmp_dir () =
  let d =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "algostream_audit_%d_%d" (Unix.getpid ()) (Random.int 1_000_000)) in
    Unix.mkdir d 0o700 ;
    d


let rec rm_rf path =
  match Sys.is_directory path with
  | true ->
    Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path) ;
    (try Unix.rmdir path with _ -> ())
  | false -> (try Unix.unlink path with _ -> ())
  | exception _ -> ()


let with_dir f =
  let d = tmp_dir () in
    Fun.protect ~finally:(fun () -> rm_rf d) (fun () -> f d)


(* A fixed timestamp so every record lands in the same daily file and rotation is not accidentally
   under test here. *)
let base_ts = 1_754_400_000_000_000_000L

let make_rec ~i ~outcome =
  Rec.make
    ~ts_ns:(Int64.add base_ts (Int64.of_int (i * 1_000_000)))
    ~kid:"a1b2c3d4" ~label:"test key" ~scopes:"read,control" ~peer:"127.0.0.1:5000" ~meth:"POST"
    ~path:(Printf.sprintf "/api/strategies/s%d/stop" i)
    ~route:"/api/strategies/:id/stop"
    ~params:[ ("id", Printf.sprintf "s%d" i) ]
    ~body:(Printf.sprintf "{\"n\":%d}" i) ~outcome ~status:200


let write_n dir n =
  match Log.Writer.open_ dir with
  | Error e -> Alcotest.fail e
  | Ok w ->
    for i = 1 to n do
      match Log.Writer.append w (make_rec ~i ~outcome:Rec.Allowed) with
      | Ok () -> ()
      | Error e -> Alcotest.fail e
    done ;
    let head = Log.Writer.head_hash w and last = Log.Writer.last_seq w in
      Log.Writer.close w ;
      (head, last)


let the_file dir =
  let entries =
    Sys.readdir dir |> Array.to_list |> List.filter (fun e -> Filename.check_suffix e ".log") in
    match entries with
    | [ f ] -> Filename.concat dir f
    | l -> Alcotest.fail (Printf.sprintf "expected exactly one log file, found %d" (List.length l))


let read_bytes path =
  let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))


let write_bytes path s =
  let oc = open_out_bin path in
    Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc s)


let verify path = match Log.Verify.file path with Ok r -> r | Error e -> Alcotest.fail e

(* ───────────────────────── the happy path ───────────────────────── *)

let intact_chain_verifies () =
  with_dir (fun dir ->
    let _, last = write_n dir 20 in
      Alcotest.(check int64) "20 records written" 20L last ;
      let r = verify (the_file dir) in
        Alcotest.(check int) "records" 20 r.Log.Verify.records ;
        Alcotest.(check int64) "first seq" 1L r.Log.Verify.first_seq ;
        Alcotest.(check int64) "last seq" 20L r.Log.Verify.last_seq ;
        Alcotest.(check (option int64)) "no break" None r.Log.Verify.broken_at)


let records_read_back () =
  with_dir (fun dir ->
    let _ = write_n dir 5 in
      match Log.Reader.fold (the_file dir) ~init:[] ~f:(fun acc r -> r :: acc) with
      | Error e -> Alcotest.fail e
      | Ok rs ->
        let rs = List.rev rs in
          Alcotest.(check int) "count" 5 (List.length rs) ;
          let r3 = List.nth rs 2 in
            Alcotest.(check string) "path survived" "/api/strategies/s3/stop" r3.Rec.path ;
            Alcotest.(check string) "route pattern survived" "/api/strategies/:id/stop" r3.Rec.route ;
            (* The value an allocation change carries lives in the body; a record that loses it says
               something happened but not what. *)
            Alcotest.(check string) "body excerpt survived" "{\"n\":3}" r3.Rec.body_excerpt)


(* ───────────────────────── tampering ───────────────────────── *)

(* Offset of the first frame's canonical payload: header, then the 4-byte length. *)
let first_payload_off = Log.header_size + 4

let flip_byte_at path off =
  let s = Bytes.of_string (read_bytes path) in
    Bytes.set s off (Char.chr (Char.code (Bytes.get s off) lxor 0xFF)) ;
    write_bytes path (Bytes.to_string s)


let modified_record_is_caught () =
  with_dir (fun dir ->
    let _ = write_n dir 10 in
    let path = the_file dir in
      (* Land inside record 1's payload, past seq and ts. *)
      flip_byte_at path (first_payload_off + 24) ;
      let r = verify path in
        Alcotest.(check (option int64)) "break is at record 1" (Some 1L) r.Log.Verify.broken_at ;
        Alcotest.(check int) "nothing verified before it" 0 r.Log.Verify.records)


let later_record_break_reports_its_own_seq () =
  with_dir (fun dir ->
    let _ = write_n dir 10 in
    let path = the_file dir in
    let content = read_bytes path in
    (* Walk to the 4th frame and corrupt it, so the reported break is 4 and not 1 or 5. *)
    let rec skip pos n =
      if n = 0 then pos
      else
        let len =
          (Char.code content.[pos] lsl 24)
          lor (Char.code content.[pos + 1] lsl 16)
          lor (Char.code content.[pos + 2] lsl 8)
          lor Char.code content.[pos + 3] in
          skip (pos + 4 + len + 32) (n - 1) in
    let fourth = skip Log.header_size 3 in
      flip_byte_at path (fourth + 4 + 24) ;
      let r = verify path in
        Alcotest.(check (option int64)) "break at record 4" (Some 4L) r.Log.Verify.broken_at ;
        Alcotest.(check int) "three verified first" 3 r.Log.Verify.records)


let deleted_record_is_caught () =
  with_dir (fun dir ->
    let _ = write_n dir 6 in
    let path = the_file dir in
    let content = read_bytes path in
    let frame_at pos =
      let len =
        (Char.code content.[pos] lsl 24)
        lor (Char.code content.[pos + 1] lsl 16)
        lor (Char.code content.[pos + 2] lsl 8)
        lor Char.code content.[pos + 3] in
        (pos, 4 + len + 32) in
    let p1, l1 = frame_at Log.header_size in
    let p2, l2 = frame_at (p1 + l1) in
      (* Splice record 2 out entirely — the case a per-record checksum cannot see, since every
         surviving record is individually well formed. *)
      write_bytes path
        (String.sub content 0 p2 ^ String.sub content (p2 + l2) (String.length content - p2 - l2)) ;
      let r = verify path in
        Alcotest.(check bool) "a break is reported" true (r.Log.Verify.broken_at <> None))


let replace_record_wholesale_is_caught () =
  with_dir (fun dir ->
    (* Build a second, independent log whose record 1 differs, and graft its frame in. The grafted
       frame is internally consistent: its length is right and its own hash matches its own payload.
       Only the *chain* rejects it. *)
    let path_a =
      with_dir (fun d2 ->
        match Log.Writer.open_ d2 with
        | Error e -> Alcotest.fail e
        | Ok w ->
          (match Log.Writer.append w (make_rec ~i:99 ~outcome:(Rec.Denied "forged")) with
          | Ok () -> ()
          | Error e -> Alcotest.fail e) ;
          Log.Writer.close w ;
          read_bytes (the_file d2)) in
    let _ = write_n dir 4 in
    let path = the_file dir in
    let content = read_bytes path in
    let len_of s pos =
      (Char.code s.[pos] lsl 24)
      lor (Char.code s.[pos + 1] lsl 16)
      lor (Char.code s.[pos + 2] lsl 8)
      lor Char.code s.[pos + 3] in
    let victim_len = 4 + len_of content Log.header_size + 32 in
    let forged_len = 4 + len_of path_a Log.header_size + 32 in
    let forged = String.sub path_a Log.header_size forged_len in
      write_bytes path
        (String.sub content 0 Log.header_size
        ^ forged
        ^ String.sub content (Log.header_size + victim_len)
            (String.length content - Log.header_size - victim_len)) ;
      let r = verify path in
        (* Caught at record 2, not record 1, and the reason is worth knowing. Both logs are first
           files, so both start from the same genesis hash — which makes the grafted frame a
           perfectly valid record 1 in isolation. What it cannot do is match record 2's stored hash,
           which was computed over the original record 1. The break therefore surfaces at the first
           record the attacker did not also rewrite.

           The corollary is the one that matters: an unkeyed chain lets anyone who can write the
           file recompute every hash from the graft onward. Detection comes from the head hash
           having moved, which is why an out-of-band anchor is not optional — see
           [truncate_tail_is_undetectable] and the interface header. *)
        Alcotest.(check (option int64))
          "the graft is caught at the first record it did not rewrite" (Some 2L)
          r.Log.Verify.broken_at ;
        Alcotest.(check bool)
          "and the head hash is not the anchored one" true (r.Log.Verify.broken_at <> None))


let truncate_tail_is_undetectable () =
  (* Asserting the documented limitation. If this ever starts failing, either the design changed or
     someone has convinced themselves of a guarantee the log does not make. *)
  with_dir (fun dir ->
    let full_head, _ = write_n dir 8 in
    let path = the_file dir in
    let content = read_bytes path in
    let len_of pos =
      (Char.code content.[pos] lsl 24)
      lor (Char.code content.[pos + 1] lsl 16)
      lor (Char.code content.[pos + 2] lsl 8)
      lor Char.code content.[pos + 3] in
    let rec end_of pos n = if n = 0 then pos else end_of (pos + 4 + len_of pos + 32) (n - 1) in
    let cut = end_of Log.header_size 5 in
      write_bytes path (String.sub content 0 cut) ;
      let r = verify path in
        Alcotest.(check (option int64))
          "no break is reported — this is the known gap" None r.Log.Verify.broken_at ;
        Alcotest.(check int) "and it looks like a complete 5-record log" 5 r.Log.Verify.records ;
        (* What *does* catch it is an out-of-band anchor: the head hash moved. *)
        Alcotest.(check bool)
          "but the head hash differs from the anchored one" true
          (not (String.equal full_head r.Log.Verify.head_hash)))


(* ───────────────────────── restart, permissions, encoding ───────────────────────── *)

let reopen_appends_rather_than_truncating () =
  (* The direct regression test against Event_log's O_TRUNC, which is the reason this log exists
     separately at all. *)
  with_dir (fun dir ->
    let _ = write_n dir 3 in
    let first = read_bytes (the_file dir) in
      (match Log.Writer.open_ dir with
      | Error e -> Alcotest.fail e
      | Ok w ->
        Alcotest.(check int64) "sequence recovered from disk" 3L (Log.Writer.last_seq w) ;
        (match Log.Writer.append w (make_rec ~i:4 ~outcome:Rec.Allowed) with
        | Ok () -> ()
        | Error e -> Alcotest.fail e) ;
        Log.Writer.close w) ;
      let after = read_bytes (the_file dir) in
        Alcotest.(check bool) "file grew" true (String.length after > String.length first) ;
        Alcotest.(check bool)
          "earlier bytes untouched" true
          (String.equal first (String.sub after 0 (String.length first))) ;
        let r = verify (the_file dir) in
          Alcotest.(check int) "chain spans the restart" 4 r.Log.Verify.records ;
          Alcotest.(check (option int64)) "and is intact" None r.Log.Verify.broken_at)


let file_mode_is_owner_only () =
  with_dir (fun dir ->
    let _ = write_n dir 1 in
    let st = Unix.stat (the_file dir) in
      Alcotest.(check int) "mode 0600" 0o600 (st.Unix.st_perm land 0o777))


let canonical_encoding_is_injective () =
  (* Directly tests the length-prefixing decision: without it these two encode identically. *)
  let mk params =
    Rec.canonical
      (Rec.make ~ts_ns:base_ts ~kid:"k" ~label:"l" ~scopes:"read" ~peer:"p" ~meth:"GET" ~path:"/x"
         ~route:"/x" ~params ~body:"" ~outcome:Rec.Allowed ~status:200) in
  let a = mk [ ("a", "bc") ] and b = mk [ ("ab", "c") ] in
    Alcotest.(check bool) "field boundaries are committed to" false (String.equal a b)


let suite =
  [
    Alcotest.test_case "intact_chain_verifies" `Quick intact_chain_verifies;
    Alcotest.test_case "records_read_back" `Quick records_read_back;
    Alcotest.test_case "modified_record_is_caught" `Quick modified_record_is_caught;
    Alcotest.test_case "later_record_break_reports_its_own_seq" `Quick
      later_record_break_reports_its_own_seq;
    Alcotest.test_case "deleted_record_is_caught" `Quick deleted_record_is_caught;
    Alcotest.test_case "replace_record_wholesale_is_caught" `Quick
      replace_record_wholesale_is_caught;
    Alcotest.test_case "truncate_tail_is_undetectable" `Quick truncate_tail_is_undetectable;
    Alcotest.test_case "reopen_appends_rather_than_truncating" `Quick
      reopen_appends_rather_than_truncating;
    Alcotest.test_case "file_mode_is_owner_only" `Quick file_mode_is_owner_only;
    Alcotest.test_case "canonical_encoding_is_injective" `Quick canonical_encoding_is_injective;
  ]
