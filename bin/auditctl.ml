(* algostream-auditctl — read and verify the audit log.

   Deliberately links only algostream.infrastructure.persistence, which itself depends on nothing
   but digestif and unix. Independent readback is the property that makes a verification result
   worth anything: a verifier that shares code with the writer can share a bug with it. *)

module Log = Algostream_infrastructure_persistence.Audit_log
module Rec = Algostream_infrastructure_persistence.Audit_record

let usage () =
  print_string
    {|algostream-auditctl — read and verify the audit log

  algostream-auditctl verify DIR_OR_FILE
  algostream-auditctl head   DIR_OR_FILE
  algostream-auditctl tail   DIR_OR_FILE [--lines N]

`head` prints the sequence number and chain hash. Record that somewhere the daemon cannot write:
the chain is unkeyed, so anyone who can write the log can recompute it and hand you a file that
verifies. Comparing against an out-of-band anchor is what turns this from a corruption check into
tamper-evidence. See the interface docs for the full threat model.

Exit status is 1 when a chain break is found, so this drops straight into a cron job.
|} ;
  exit 0


let die fmt =
  Printf.ksprintf
    (fun s ->
      prerr_endline ("algostream-auditctl: " ^ s) ;
      exit 2)
    fmt


let reports target =
  if Sys.file_exists target && Sys.is_directory target then
    match Log.Verify.directory target with Ok rs -> rs | Error e -> die "%s" e
  else match Log.Verify.file target with Ok r -> [ r ] | Error e -> die "%s" e


let cmd_verify target =
  let rs = reports target in
    if rs = [] then (
      print_endline "no audit files found" ;
      exit 0) ;
    List.iter (fun r -> print_endline (Log.Verify.report_to_string r)) rs ;
    if List.exists (fun (r : Log.Verify.report) -> r.Log.Verify.broken_at <> None) rs then exit 1


let cmd_head target =
  match List.rev (reports target) with
  | [] -> die "no audit files found in %s" target
  | last :: _ ->
    Printf.printf "seq  %Ld\nhead %s\nfile %s\n" last.Log.Verify.last_seq last.Log.Verify.head_hash
      last.Log.Verify.file ;
    if last.Log.Verify.broken_at <> None then (
      prerr_endline "warning: the chain is broken — this head hash is not trustworthy" ;
      exit 1)


let files_of target =
  if Sys.file_exists target && Sys.is_directory target then
    Sys.readdir target |> Array.to_list
    |> List.filter (fun e ->
         String.length e > 6
         && String.equal (String.sub e 0 6) "audit-"
         && Filename.check_suffix e ".log")
    |> List.sort String.compare
    |> List.map (Filename.concat target)
  else [ target ]


let cmd_tail target lines =
  let all =
    List.concat_map
      (fun f ->
        match Log.Reader.fold f ~init:[] ~f:(fun acc r -> r :: acc) with
        | Ok rs -> List.rev rs
        | Error e ->
          (* Report the break and still show what was readable before it — an operator running
             `tail` after an alert wants to see the records, not just the complaint. *)
          prerr_endline ("algostream-auditctl: " ^ e) ;
          [])
      (files_of target) in
  let n = List.length all in
  let shown = if n <= lines then all else List.filteri (fun i _ -> i >= n - lines) all in
    List.iter (fun r -> print_endline (Rec.to_line r)) shown


let () =
  let n = Array.length Sys.argv in
    if n < 3 then usage () ;
    let lines = ref 20 in
    let i = ref 3 in
      while !i < n do
        (match Sys.argv.(!i) with
        | "--lines" when !i + 1 < n ->
          lines := int_of_string Sys.argv.(!i + 1) ;
          incr i
        | "-h" | "--help" -> usage ()
        | other -> die "unknown argument %s" other) ;
        incr i
      done ;
      let target = Sys.argv.(2) in
        match Sys.argv.(1) with
        | "verify" -> cmd_verify target
        | "head" -> cmd_head target
        | "tail" -> cmd_tail target !lines
        | other -> die "unknown command %s (try --help)" other
