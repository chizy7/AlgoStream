type parsed = {
  kid : string;
  secret : string;
}

let prefix = "ask_"

let kid_bytes = 4

let kid_chars = kid_bytes * 2

let secret_bytes = 32

(* Base32 packs 5 bits per character, so 32 bytes = 256 bits needs ceil(256/5) = 52 characters. *)
let secret_chars = 52

(* RFC 4648 base32, lowercased. Lowercase because the whole credential is lowercase and a mixed-case
   token invites transcription errors that the missing checksum would not catch. *)
let alphabet = "abcdefghijklmnopqrstuvwxyz234567"

let base32_encode (s : string) : string =
  let out = Buffer.create secret_chars in
  let acc = ref 0 in
  let bits = ref 0 in
    String.iter
      (fun c ->
        acc := (!acc lsl 8) lor Char.code c ;
        bits := !bits + 8 ;
        while !bits >= 5 do
          bits := !bits - 5 ;
          Buffer.add_char out alphabet.[(!acc lsr !bits) land 0x1f]
        done)
      s ;
    (* Trailing bits are left-aligned into a final character rather than padded with '='. *)
    if !bits > 0 then Buffer.add_char out alphabet.[(!acc lsl (5 - !bits)) land 0x1f] ;
    Buffer.contents out


let hex_encode (s : string) : string =
  String.concat ""
    (List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) (List.of_seq (String.to_seq s)))


let is_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

let in_alphabet c = String.contains alphabet c

let hash secret = "sha256:" ^ Digestif.SHA256.to_hex (Digestif.SHA256.digest_string secret)

let dummy_hash = hash "algostream-no-such-key"

let generate () =
  let kid = hex_encode (Mirage_crypto_rng_unix.getrandom kid_bytes) in
  let secret = base32_encode (Mirage_crypto_rng_unix.getrandom secret_bytes) in
    (prefix ^ kid ^ "_" ^ secret, { kid; secret })


let parse s =
  let plen = String.length prefix in
    if String.length s < plen || not (String.equal (String.sub s 0 plen) prefix) then
      Error (Printf.sprintf "an api key starts with %S" prefix)
    else
      let rest = String.sub s plen (String.length s - plen) in
        match String.index_opt rest '_' with
        | None -> Error "malformed api key: expected <prefix><kid>_<secret>"
        | Some i ->
          let kid = String.sub rest 0 i in
          let secret = String.sub rest (i + 1) (String.length rest - i - 1) in
            if String.length kid <> kid_chars then
              Error (Printf.sprintf "key id must be %d hex characters" kid_chars)
            else if not (String.for_all is_hex kid) then Error "key id must be lowercase hex"
            else if String.length secret <> secret_chars then
              Error (Printf.sprintf "key secret must be %d characters" secret_chars)
            else if not (String.for_all in_alphabet secret) then
              Error "key secret contains characters outside the base32 alphabet"
            else Ok { kid; secret }


let verify ~secret ~stored =
  match String.index_opt stored ':' with
  | None -> false
  | Some i ->
    let algo = String.sub stored 0 i in
    let hex = String.sub stored (i + 1) (String.length stored - i - 1) in
      if not (String.equal algo "sha256") then false
      else (
        match Digestif.SHA256.of_hex_opt hex with
        | None -> false
        (* [equal], never [unsafe_compare] — the latter is documented as leaking and is banned under
           this directory by a CI lint. *)
        | Some expected -> Digestif.SHA256.equal expected (Digestif.SHA256.digest_string secret))
