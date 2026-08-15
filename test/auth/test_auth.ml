(** Unit coverage for the credential layer.

    The rotation and revocation cases are the ones worth having: they encode timing behaviour an
    operator depends on and that no compiler checks — that an overlap window really does admit both
    keys at once, and that a keystore refuses rather than warns when its permissions are wrong. *)

module Auth = Algostream_infrastructure_auth
open Auth

let tmp_file () =
  let d = Filename.get_temp_dir_name () in
    Filename.concat d
      (Printf.sprintf "algostream_keys_%d_%d.json" (Unix.getpid ()) (Random.int 1_000_000))


let with_keystore recs f =
  let path = tmp_file () in
    Fun.protect
      ~finally:(fun () -> try Unix.unlink path with _ -> ())
      (fun () ->
        (match Keystore.save path recs with Ok () -> () | Error e -> Alcotest.fail e) ;
        f path)


let now = 1_754_400_000_000_000_000L

let sec n = Int64.mul (Int64.of_int n) 1_000_000_000L

(* Returns the wire key plus a record for it. *)
let fresh ?(label = "k") ?(scopes = [ Scope.Read ]) ?expires_ns () =
  let wire, p = Api_key.generate () in
  let r =
    Keystore.make_record ~kid:p.Api_key.kid ~label ~scopes:(Scope.Set.of_list scopes)
      ~secret:p.Api_key.secret ~now_ns:now ~expires_ns in
    (wire, r)


(* ───────────────────────── keys ───────────────────────── *)

let generate_is_unique_and_verifies () =
  let _, a = Api_key.generate () and _, b = Api_key.generate () in
    Alcotest.(check bool) "kids differ" true (a.Api_key.kid <> b.Api_key.kid) ;
    Alcotest.(check bool) "secrets differ" true (a.Api_key.secret <> b.Api_key.secret) ;
    let h = Api_key.hash a.Api_key.secret in
      Alcotest.(check bool)
        "own secret verifies" true
        (Api_key.verify ~secret:a.Api_key.secret ~stored:h) ;
      Alcotest.(check bool)
        "other does not" false
        (Api_key.verify ~secret:b.Api_key.secret ~stored:h)


let single_character_mutations_fail () =
  let _, p = Api_key.generate () in
  let h = Api_key.hash p.Api_key.secret in
  let mutate i =
    let b = Bytes.of_string p.Api_key.secret in
      Bytes.set b i (if Bytes.get b i = 'a' then 'b' else 'a') ;
      Bytes.to_string b in
    List.iter
      (fun i ->
        Alcotest.(check bool)
          (Printf.sprintf "mutation at %d is rejected" i)
          false
          (Api_key.verify ~secret:(mutate i) ~stored:h))
      [ 0; Api_key.secret_chars / 2; Api_key.secret_chars - 1 ]


let parse_rejects_malformed () =
  let _, p = Api_key.generate () in
    List.iter
      (fun (name, s) ->
        match Api_key.parse s with Ok _ -> Alcotest.fail (name ^ " was accepted") | Error _ -> ())
      [
        ("empty", "");
        ("no prefix", "xyz_a1b2c3d4_" ^ p.Api_key.secret);
        ("no separator", "ask_a1b2c3d4" ^ p.Api_key.secret);
        ("short secret", "ask_a1b2c3d4_abc");
        ("uppercase kid", "ask_A1B2C3D4_" ^ p.Api_key.secret);
        ("non-base32 secret", "ask_a1b2c3d4_" ^ String.make Api_key.secret_chars '1');
      ]


let corrupt_stored_hash_fails_closed () =
  List.iter
    (fun stored ->
      Alcotest.(check bool)
        (Printf.sprintf "stored %S is rejected" stored)
        false
        (Api_key.verify ~secret:"anything" ~stored))
    [ ""; "sha256:"; "sha256:zzzz"; "md5:abcd"; "no-colon" ]


(* ───────────────────────── scopes ───────────────────────── *)

let control_implies_read () =
  let ctl = Scope.Set.of_list [ Scope.Control ] and rd = Scope.Set.of_list [ Scope.Read ] in
    Alcotest.(check bool)
      "control satisfies read" true
      (Scope.satisfies ~granted:ctl ~required:Scope.Read) ;
    Alcotest.(check bool)
      "read does not satisfy control" false
      (Scope.satisfies ~granted:rd ~required:Scope.Control) ;
    Alcotest.(check bool)
      "empty satisfies public" true
      (Scope.satisfies ~granted:Scope.Set.empty ~required:Scope.Public)


let public_is_not_grantable () =
  match Scope.of_string "public" with
  | Ok _ -> Alcotest.fail "a keystore could grant \"public\", which means no credential required"
  | Error _ -> ()


(* ───────────────────────── keystore ───────────────────────── *)

let authenticate_round_trip () =
  let wire, r = fresh ~scopes:[ Scope.Read; Scope.Control ] () in
    with_keystore [ r ] (fun path ->
      match Keystore.load path with
      | Error e -> Alcotest.fail e
      | Ok ks ->
        (match Keystore.authenticate ks ~now_ns:now ~credential:wire ~required:Scope.Control with
        | Error f -> Alcotest.fail (Keystore.failure_to_string f)
        | Ok p ->
          Alcotest.(check string) "kid matches" r.Keystore.kid (Principal.kid p) ;
          Alcotest.(check bool) "has control" true (Principal.has p Scope.Control)))


let insufficient_scope_is_distinct () =
  let wire, r = fresh ~scopes:[ Scope.Read ] () in
    with_keystore [ r ] (fun path ->
      match Keystore.load path with
      | Error e -> Alcotest.fail e
      | Ok ks ->
        (* Must be distinguishable from a bad credential: the dispatcher answers 403 here and 401
           everywhere else, because retrying with the same key will never help. *)
        (match Keystore.authenticate ks ~now_ns:now ~credential:wire ~required:Scope.Control with
        | Error (Keystore.Insufficient_scope Scope.Control) -> ()
        | Error f ->
          Alcotest.fail ("expected Insufficient_scope, got " ^ Keystore.failure_to_string f)
        | Ok _ -> Alcotest.fail "a read-only key was granted control"))


let expiry_and_the_rotation_overlap () =
  (* The property an operator actually depends on during a rotation: for the length of the window,
     both keys work, so there is no moment where neither does. *)
  let old_wire, old_r = fresh ~label:"old" ~expires_ns:(Int64.add now (sec 3600)) () in
  let new_wire, new_r = fresh ~label:"new" () in
    with_keystore [ old_r; new_r ] (fun path ->
      match Keystore.load path with
      | Error e -> Alcotest.fail e
      | Ok ks ->
        let ok ~at wire =
          match Keystore.authenticate ks ~now_ns:at ~credential:wire ~required:Scope.Read with
          | Ok _ -> true
          | Error _ -> false in
        let during = Int64.add now (sec 1800) and after = Int64.add now (sec 7200) in
          Alcotest.(check bool) "old key works inside the window" true (ok ~at:during old_wire) ;
          Alcotest.(check bool) "new key works inside the window" true (ok ~at:during new_wire) ;
          Alcotest.(check bool) "old key stops after it" false (ok ~at:after old_wire) ;
          Alcotest.(check bool) "new key continues" true (ok ~at:after new_wire))


let revocation_beats_a_future_expiry () =
  let wire, r = fresh ~expires_ns:(Int64.add now (sec 86400)) () in
  let revoked = { r with Keystore.revoked_ns = Some now } in
    with_keystore [ revoked ] (fun path ->
      match Keystore.load path with
      | Error e -> Alcotest.fail e
      | Ok ks ->
        (match Keystore.authenticate ks ~now_ns:now ~credential:wire ~required:Scope.Read with
        | Ok _ -> Alcotest.fail "a revoked key authenticated"
        | Error _ ->
          Alcotest.(check bool)
            "and is not live for an open stream" false
            (Keystore.is_live ks ~now_ns:now ~kid:r.Keystore.kid)))


let group_readable_keystore_is_refused () =
  (* Refused, not warned. A daemon that runs detached is a daemon whose warnings nobody reads. *)
  let _, r = fresh () in
    with_keystore [ r ] (fun path ->
      Unix.chmod path 0o644 ;
      match Keystore.load path with
      | Ok _ -> Alcotest.fail "a world-readable keystore was accepted"
      | Error e ->
        Alcotest.(check bool)
          "the error names the file" true
          (let re = Str.regexp_string (Filename.basename path) in
             try
               ignore (Str.search_forward re e 0) ;
               true
             with Not_found -> false))


(* The Kubernetes shape. A Secret volume arrives owned by root with group-read added by fsGroup, so
   the keystore is mode 0440 and not owned by the process. Rejecting that made the daemon impossible
   to run in a pod at all; accepting it is safe because the group is the pod's own.

   The process cannot chown to root without privileges, so this exercises the group half — mode 0440
   owned by our own gid — which is the part that used to be refused by the 0o077 mask. *)
let group_readable_by_our_own_group_is_accepted () =
  let _, r = fresh () in
    with_keystore [ r ] (fun path ->
      Unix.chmod path 0o440 ;
      match Keystore.load path with
      | Ok _ -> ()
      | Error e -> Alcotest.failf "mode 0440 owned by this process's own group was refused: %s" e)


let world_readable_is_still_refused () =
  (* The control for the case above: relaxing the group rule must not relax the world rule. *)
  let _, r = fresh () in
    with_keystore [ r ] (fun path ->
      Unix.chmod path 0o604 ;
      match Keystore.load path with
      | Ok _ -> Alcotest.fail "a world-readable keystore was accepted"
      | Error _ -> ())


let duplicate_kid_is_refused () =
  let _, r = fresh () in
    with_keystore
      [ r; { r with Keystore.label = "clone" } ]
      (fun path ->
        match Keystore.load path with
        | Ok _ -> Alcotest.fail "duplicate key ids were accepted"
        | Error _ -> ())


let saved_keystore_is_owner_only () =
  let _, r = fresh () in
    with_keystore [ r ] (fun path ->
      Alcotest.(check int) "mode 0600" 0o600 ((Unix.stat path).Unix.st_perm land 0o777))


(* ───────────────────────── tickets ───────────────────────── *)

let ticket_is_single_use_and_expires () =
  let t = Ticket.create () in
  let scopes = Scope.Set.of_list [ Scope.Read ] in
  let tk = Ticket.mint t ~now_ns:now ~kid:"a1b2c3d4" ~scopes in
    (match Ticket.redeem t ~now_ns:now ~ticket:tk with
    | Some p -> Alcotest.(check string) "attributed to the minting key" "a1b2c3d4" (Principal.kid p)
    | None -> Alcotest.fail "a fresh ticket was rejected") ;
    Alcotest.(check bool)
      "a second redemption fails" true
      (Ticket.redeem t ~now_ns:now ~ticket:tk = None) ;
    let tk2 = Ticket.mint t ~now_ns:now ~kid:"a1b2c3d4" ~scopes in
      Alcotest.(check bool)
        "an expired ticket fails" true
        (Ticket.redeem t ~now_ns:(Int64.add now (Int64.add Ticket.ttl_ns 1L)) ~ticket:tk2 = None) ;
      Alcotest.(check bool)
        "an unknown ticket fails" true
        (Ticket.redeem t ~now_ns:now ~ticket:(String.make 32 'f') = None)


let ticket_carries_no_more_than_its_key () =
  let t = Ticket.create () in
  let tk = Ticket.mint t ~now_ns:now ~kid:"deadbeef" ~scopes:(Scope.Set.of_list [ Scope.Read ]) in
    match Ticket.redeem t ~now_ns:now ~ticket:tk with
    | None -> Alcotest.fail "redeem failed"
    | Some p ->
      Alcotest.(check bool)
        "a read ticket does not confer control" false (Principal.has p Scope.Control)


let ticket_table_is_capped () =
  let t = Ticket.create () in
  let scopes = Scope.Set.of_list [ Scope.Read ] in
    for _ = 1 to Ticket.capacity * 3 do
      ignore (Ticket.mint t ~now_ns:now ~kid:"a1b2c3d4" ~scopes)
    done ;
    Alcotest.(check bool)
      "minting without connecting cannot grow memory" true
      (Ticket.outstanding t <= Ticket.capacity)


(* ───────────────────────── rate limit ───────────────────────── *)

let failures_trip_then_reset () =
  let l = Rate_limit.create () in
  let peer = "127.0.0.1:1" in
  let crossings = ref 0 in
    for _ = 1 to Rate_limit.max_failures do
      if Rate_limit.note_failure l ~now_ns:now ~peer then incr crossings
    done ;
    (* Exactly one crossing, which is what keeps a brute-force burst from writing one fsynced audit
       record per attempt. *)
    Alcotest.(check int) "threshold is crossed once" 1 !crossings ;
    (match Rate_limit.check l ~now_ns:now ~peer with
    | Some retry -> Alcotest.(check bool) "retry-after is positive" true (retry > 0)
    | None -> Alcotest.fail "peer should be limited") ;
    (* Further failures inside the window must not report again. *)
    Alcotest.(check bool)
      "no second report inside the window" false
      (Rate_limit.note_failure l ~now_ns:now ~peer) ;
    Alcotest.(check bool)
      "the window eventually elapses" true
      (Rate_limit.check l ~now_ns:(Int64.add now (Int64.add Rate_limit.window_ns (sec 1))) ~peer
      = None)


let success_clears_the_counter () =
  let l = Rate_limit.create () in
  let peer = "127.0.0.1:2" in
    for _ = 1 to Rate_limit.max_failures - 1 do
      ignore (Rate_limit.note_failure l ~now_ns:now ~peer)
    done ;
    Rate_limit.note_success l ~peer ;
    Alcotest.(check bool)
      "a mistyped-then-correct key leaves no penalty" true
      (Rate_limit.check l ~now_ns:now ~peer = None)


let suite =
  [
    Alcotest.test_case "generate_is_unique_and_verifies" `Quick generate_is_unique_and_verifies;
    Alcotest.test_case "single_character_mutations_fail" `Quick single_character_mutations_fail;
    Alcotest.test_case "parse_rejects_malformed" `Quick parse_rejects_malformed;
    Alcotest.test_case "corrupt_stored_hash_fails_closed" `Quick corrupt_stored_hash_fails_closed;
    Alcotest.test_case "control_implies_read" `Quick control_implies_read;
    Alcotest.test_case "public_is_not_grantable" `Quick public_is_not_grantable;
    Alcotest.test_case "authenticate_round_trip" `Quick authenticate_round_trip;
    Alcotest.test_case "insufficient_scope_is_distinct" `Quick insufficient_scope_is_distinct;
    Alcotest.test_case "expiry_and_the_rotation_overlap" `Quick expiry_and_the_rotation_overlap;
    Alcotest.test_case "revocation_beats_a_future_expiry" `Quick revocation_beats_a_future_expiry;
    Alcotest.test_case "group_readable_keystore_is_refused" `Quick
      group_readable_keystore_is_refused;
    Alcotest.test_case "group_readable_by_our_own_group_is_accepted" `Quick
      group_readable_by_our_own_group_is_accepted;
    Alcotest.test_case "world_readable_is_still_refused" `Quick world_readable_is_still_refused;
    Alcotest.test_case "duplicate_kid_is_refused" `Quick duplicate_kid_is_refused;
    Alcotest.test_case "saved_keystore_is_owner_only" `Quick saved_keystore_is_owner_only;
    Alcotest.test_case "ticket_is_single_use_and_expires" `Quick ticket_is_single_use_and_expires;
    Alcotest.test_case "ticket_carries_no_more_than_its_key" `Quick
      ticket_carries_no_more_than_its_key;
    Alcotest.test_case "ticket_table_is_capped" `Quick ticket_table_is_capped;
    Alcotest.test_case "failures_trip_then_reset" `Quick failures_trip_then_reset;
    Alcotest.test_case "success_clears_the_counter" `Quick success_clears_the_counter;
  ]
