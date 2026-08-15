(* File layout, deliberately shaped like Event_log's so the two read as siblings:

   magic "ASAU" (u32 BE) | version (u32 BE) | created_ns (i64 BE) | prev_file_hash (32 bytes) |
   prev_file_name (64 bytes, NUL-padded) | reserved to 160 | frame: u32 length | canonical bytes |
   32-byte chain hash | ... repeated ... *)

let magic = 0x41534155l (* "ASAU" *)

let version = 1l

let name_field = 64

let header_size = 4 + 4 + 8 + 32 + name_field + 52 (* = 164 *)

let genesis_prefix = "algostream-audit-v1\x00"

let digest_raw s = Digestif.SHA256.(to_raw_string (digest_string s))

let to_hex s = Digestif.SHA256.(to_hex (of_raw_string s))

let genesis ~prev_file_hash = digest_raw (genesis_prefix ^ prev_file_hash)

let chain prev canonical = digest_raw (prev ^ canonical)

let zero32 = String.make 32 '\000'

(* ───────────────────────── byte helpers ───────────────────────── *)

let put_be32 b n =
  Buffer.add_char b (Char.chr ((n lsr 24) land 0xff)) ;
  Buffer.add_char b (Char.chr ((n lsr 16) land 0xff)) ;
  Buffer.add_char b (Char.chr ((n lsr 8) land 0xff)) ;
  Buffer.add_char b (Char.chr (n land 0xff))


let put_be64 b (n : int64) =
  for i = 7 downto 0 do
    Buffer.add_char b
      (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical n (i * 8)) 0xFFL)))
  done


let get_be32 s off =
  (Char.code s.[off] lsl 24)
  lor (Char.code s.[off + 1] lsl 16)
  lor (Char.code s.[off + 2] lsl 8)
  lor Char.code s.[off + 3]


(* ───────────────────────── canonical decode ───────────────────────── *)

exception Bad of string

let bad fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt

type cursor = {
  buf : string;
  mutable pos : int;
}

let need c n = if c.pos + n > String.length c.buf then bad "record truncated"

let rd_be32 c =
  need c 4 ;
  let v = get_be32 c.buf c.pos in
    c.pos <- c.pos + 4 ;
    v


let rd_be64 c =
  need c 8 ;
  let v = ref 0L in
    for i = 0 to 7 do
      v := Int64.logor (Int64.shift_left !v 8) (Int64.of_int (Char.code c.buf.[c.pos + i]))
    done ;
    c.pos <- c.pos + 8 ;
    !v


let rd_lp c =
  let n = rd_be32 c in
    if n < 0 then bad "negative length" ;
    need c n ;
    let s = String.sub c.buf c.pos n in
      c.pos <- c.pos + n ;
      s


let rd_u8 c =
  need c 1 ;
  let v = Char.code c.buf.[c.pos] in
    c.pos <- c.pos + 1 ;
    v


let decode_canonical (s : string) : Audit_record.t =
  let c = { buf = s; pos = 0 } in
  let seq = rd_be64 c in
  let ts_ns = rd_be64 c in
  let kid = rd_lp c in
  let label = rd_lp c in
  let scopes = rd_lp c in
  let peer = rd_lp c in
  let meth = rd_lp c in
  let path = rd_lp c in
  let route = rd_lp c in
  let n = rd_be32 c in
  let params =
    List.init n (fun _ ->
      let k = rd_lp c in
      let v = rd_lp c in
        (k, v)) in
  let body_sha256 = rd_lp c in
  let body_excerpt = rd_lp c in
  let tag = rd_u8 c in
  let detail = rd_lp c in
  let status = rd_be32 c in
  let outcome =
    match tag with
    | 0 -> Audit_record.Allowed
    | 1 -> Audit_record.Denied detail
    | 2 -> Audit_record.Failed detail
    | t -> bad "unknown outcome tag %d" t in
    {
      Audit_record.seq;
      ts_ns;
      kid;
      label;
      scopes;
      peer;
      meth;
      path;
      route;
      params;
      body_sha256;
      body_excerpt;
      outcome;
      status;
    }


(* ───────────────────────── header ───────────────────────── *)

type header = {
  created_ns : int64;
  prev_file_hash : string;
  prev_file_name : string;
}

let encode_header h =
  let b = Buffer.create header_size in
    put_be32 b (Int32.to_int magic land 0xFFFFFFFF) ;
    put_be32 b (Int32.to_int version) ;
    put_be64 b h.created_ns ;
    Buffer.add_string b h.prev_file_hash ;
    let nm =
      if String.length h.prev_file_name >= name_field then String.sub h.prev_file_name 0 name_field
      else h.prev_file_name ^ String.make (name_field - String.length h.prev_file_name) '\000' in
      Buffer.add_string b nm ;
      Buffer.add_string b (String.make (header_size - Buffer.length b) '\000') ;
      Buffer.contents b


let decode_header s =
  if String.length s < header_size then bad "file shorter than a header" ;
  let m = get_be32 s 0 in
    if Int32.of_int m <> magic then bad "bad magic (not an algostream audit log)" ;
    let v = get_be32 s 4 in
      if Int32.of_int v <> version then bad "unsupported audit log version %d" v ;
      let created = ref 0L in
        for i = 0 to 7 do
          created := Int64.logor (Int64.shift_left !created 8) (Int64.of_int (Char.code s.[8 + i]))
        done ;
        let prev_hash = String.sub s 16 32 in
        let raw_name = String.sub s 48 name_field in
        let stop = try String.index raw_name '\000' with Not_found -> name_field in
          {
            created_ns = !created;
            prev_file_hash = prev_hash;
            prev_file_name = String.sub raw_name 0 stop;
          }


(* ───────────────────────── walking a file ───────────────────────── *)

let read_whole path =
  let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))


(* Walk frames, verifying the chain as it goes. [on_record] sees each verified record. Returns
   (count, last_seq, head_hash, break) where [break] is [Some (seq, why)] at the first failure. *)
let walk ~content ~on_record =
  let h = decode_header content in
  let total = String.length content in
  let rec go pos prev count last_seq =
    if pos = total then (count, last_seq, prev, None)
    else if pos + 4 > total then
      ( count,
        last_seq,
        prev,
        Some (Int64.add last_seq 1L, "trailing bytes: incomplete frame length") )
    else
      let len = get_be32 content pos in
        if len < 0 || pos + 4 + len + 32 > total then
          (count, last_seq, prev, Some (Int64.add last_seq 1L, "frame extends past end of file"))
        else
          let canonical = String.sub content (pos + 4) len in
          let stored = String.sub content (pos + 4 + len) 32 in
          let expected = chain prev canonical in
            if not (String.equal stored expected) then
              let seq =
                try (decode_canonical canonical).Audit_record.seq with _ -> Int64.add last_seq 1L
              in
                (count, last_seq, prev, Some (seq, "chain hash mismatch"))
            else
              match decode_canonical canonical with
              | exception Bad m -> (count, last_seq, prev, Some (Int64.add last_seq 1L, m))
              | r ->
                if count > 0 && Int64.compare r.Audit_record.seq (Int64.add last_seq 1L) <> 0 then
                  ( count,
                    last_seq,
                    prev,
                    Some
                      ( r.Audit_record.seq,
                        Printf.sprintf "sequence gap: expected %Ld, found %Ld"
                          (Int64.add last_seq 1L) r.Audit_record.seq ) )
                else (
                  on_record r ;
                  go (pos + 4 + len + 32) stored (count + 1) r.Audit_record.seq) in
  let start = genesis ~prev_file_hash:h.prev_file_hash in
    (h, go header_size start 0 0L)


(* ───────────────────────── writer ───────────────────────── *)

module Writer = struct
  type t = {
    dir : string;
    mutable path : string;
    mutable fd : Unix.file_descr;
    mutable seq : int64;
    mutable head : string;  (** raw 32 bytes *)
    mutable day : string;
  }

  let day_of ~now_ns =
    let tm = Unix.gmtime (Int64.to_float now_ns /. 1e9) in
      Printf.sprintf "%04d%02d%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday


  let file_for dir day = Filename.concat dir (Printf.sprintf "audit-%s.log" day)

  let mkdir_p dir =
    if not (Sys.file_exists dir) then
      let rec go d =
        if not (Sys.file_exists d) then (
          go (Filename.dirname d) ;
          try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()) in
        go dir


  (* Most recent existing audit file before [day], for chaining across rotation. *)
  let previous_file dir day =
    match Sys.readdir dir with
    | exception _ -> None
    | entries ->
      let candidates =
        Array.to_list entries
        |> List.filter (fun e ->
             String.length e = 20
             && String.equal (String.sub e 0 6) "audit-"
             && Filename.check_suffix e ".log"
             && String.compare (String.sub e 6 8) day < 0)
        |> List.sort String.compare in
        (match List.rev candidates with [] -> None | last :: _ -> Some last)


  let head_of_file path =
    try
      let content = read_whole path in
      let _, (count, last_seq, head, _) = walk ~content ~on_record:(fun _ -> ()) in
        Some (count, last_seq, head)
    with _ -> None


  let open_at dir ~now_ns =
    mkdir_p dir ;
    let day = day_of ~now_ns in
    let path = file_for dir day in
      if Sys.file_exists path then
        (* Continue an existing file: recover seq and chain head by reading it. This is the direct
           inverse of Event_log's O_TRUNC — a restart extends the chain. *)
        match head_of_file path with
        | None -> Error (Printf.sprintf "%s exists but could not be read as an audit log" path)
        | Some (_, last_seq, head) ->
          let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_APPEND ] 0o600 in
            Ok { dir; path; fd; seq = last_seq; head; day }
      else
        let prev_name, prev_hash =
          match previous_file dir day with
          | None -> ("", zero32)
          | Some name ->
            (match head_of_file (Filename.concat dir name) with
            | Some (_, _, h) -> (name, h)
            | None -> (name, zero32)) in
        let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o600 in
        let hdr =
          encode_header
            { created_ns = now_ns; prev_file_hash = prev_hash; prev_file_name = prev_name } in
        let b = Bytes.of_string hdr in
          ignore (Unix.write fd b 0 (Bytes.length b)) ;
          Ok { dir; path; fd; seq = 0L; head = genesis ~prev_file_hash:prev_hash; day }


  let open_ dir =
    let now_ns = Int64.of_float (Unix.gettimeofday () *. 1e9) in
      try open_at dir ~now_ns with
      | Bad m -> Error m
      | Unix.Unix_error (e, fn, _) ->
        Error (Printf.sprintf "%s: %s: %s" dir fn (Unix.error_message e))
      | Sys_error m -> Error m


  let rotate_if_needed t ~now_ns =
    let day = day_of ~now_ns in
      if String.equal day t.day then Ok ()
      else (
        (try Unix.close t.fd with _ -> ()) ;
        match open_at t.dir ~now_ns with
        | Ok fresh ->
          t.path <- fresh.path ;
          t.fd <- fresh.fd ;
          t.seq <- fresh.seq ;
          t.head <- fresh.head ;
          t.day <- fresh.day ;
          Ok ()
        | Error e -> Error e)


  let append t ?(sync = true) (r : Audit_record.t) =
    try
      (* Rotation follows the wall clock at write time, deliberately not [r.ts_ns]. A file is "the
         log written on day X"; keying it off caller-supplied data would let a record with an odd
         timestamp open a second file, or reopen yesterday's after midnight. The record keeps its
         own [ts_ns] either way, so nothing is lost. *)
      let now_ns = Int64.of_float (Unix.gettimeofday () *. 1e9) in
        match rotate_if_needed t ~now_ns with
        | Error e -> Error e
        | Ok () ->
          let seq = Int64.add t.seq 1L in
          let r = { r with Audit_record.seq } in
          let canonical = Audit_record.canonical r in
          let hash = chain t.head canonical in
          let b = Buffer.create (String.length canonical + 36) in
            put_be32 b (String.length canonical) ;
            Buffer.add_string b canonical ;
            Buffer.add_string b hash ;
            let bytes = Buffer.to_bytes b in
            let n = Unix.write t.fd bytes 0 (Bytes.length bytes) in
              if n <> Bytes.length bytes then Error "short write to audit log"
              else (
                (* O_APPEND makes each write atomic at the OS level, so a crash mid-write cannot
                   clobber an earlier record. *)
                if sync then Unix.fsync t.fd ;
                t.seq <- seq ;
                t.head <- hash ;
                Ok ())
    with
    | Unix.Unix_error (e, fn, _) -> Error (Printf.sprintf "%s: %s" fn (Unix.error_message e))
    | Bad m -> Error m


  let close t = try Unix.close t.fd with _ -> ()

  let last_seq t = t.seq

  let head_hash t = to_hex t.head

  let path t = t.path
end

(* ───────────────────────── reader ───────────────────────── *)

module Reader = struct
  let fold path ~init ~f =
    try
      let content = read_whole path in
      let acc = ref init in
      let _, (_, _, _, break) = walk ~content ~on_record:(fun r -> acc := f !acc r) in
        match break with
        | None -> Ok !acc
        | Some (seq, why) ->
          Error (Printf.sprintf "%s: chain broken at record %Ld: %s" path seq why)
    with
    | Bad m -> Error (Printf.sprintf "%s: %s" path m)
    | Sys_error m -> Error m
end

module Verify = struct
  type report = {
    file : string;
    records : int;
    first_seq : int64;
    last_seq : int64;
    head_hash : string;
    broken_at : int64 option;
    reason : string option;
  }

  let report_to_string r =
    match r.broken_at with
    | None ->
      Printf.sprintf "%s: %d records, seq %Ld..%Ld, head %s — chain intact" r.file r.records
        r.first_seq r.last_seq r.head_hash
    | Some seq ->
      Printf.sprintf "%s: BROKEN at record %Ld (%s) — %d records verified before the break" r.file
        seq
        (match r.reason with Some x -> x | None -> "unknown")
        r.records


  let file path =
    try
      let content = read_whole path in
      let first = ref 0L in
      let _, (count, last_seq, head, break) =
        walk ~content ~on_record:(fun r -> if !first = 0L then first := r.Audit_record.seq) in
        Ok
          {
            file = path;
            records = count;
            first_seq = !first;
            last_seq;
            head_hash = to_hex head;
            broken_at = (match break with Some (s, _) -> Some s | None -> None);
            reason = (match break with Some (_, w) -> Some w | None -> None);
          }
    with
    | Bad m -> Error (Printf.sprintf "%s: %s" path m)
    | Sys_error m -> Error m


  let directory dir =
    match Sys.readdir dir with
    | exception Sys_error m -> Error m
    | entries ->
      let files =
        Array.to_list entries
        |> List.filter (fun e ->
             String.length e > 6
             && String.equal (String.sub e 0 6) "audit-"
             && Filename.check_suffix e ".log")
        |> List.sort String.compare in
      let rec go acc prev_head = function
        | [] -> Ok (List.rev acc)
        | name :: rest ->
          let path = Filename.concat dir name in
            (match file path with
            | Error e -> Error e
            | Ok rep ->
              (* Rotation must not be a seam the chain can be cut at. *)
              let linked =
                match prev_head with
                | None -> true
                | Some expected ->
                  (try
                     let h = decode_header (read_whole path) in
                       String.equal (to_hex h.prev_file_hash) expected
                   with _ -> false) in
              let rep =
                if linked then rep
                else
                  {
                    rep with
                    broken_at = Some rep.first_seq;
                    reason = Some "file header does not chain to the previous file's head hash";
                  } in
                go (rep :: acc) (Some rep.head_hash) rest) in
        go [] None files
end
