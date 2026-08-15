type t =
  | Split of { ratio : float }
  | Dividend of {
      amount : float;
      currency : string;
    }
  | Symbol_change of {
      from_ : string;
      to_ : string;
    }
  | Fork of {
      parent : string;
      children : (string * float) list;
    }
  | Halt of { until_ns : int64 }

type entry = {
  effective_at_ns : int64;
  break_ : t;
  source : string;
}

type tick = {
  symbol : string;
  ts_ns : int64;
  price : float;
  size : float;
}

type verdict =
  | Pass
  | Rewrite of tick
  | Drop
  | Emit_synthetic of tick list

let apply_one entry (t : tick) : verdict =
  if Int64.compare t.ts_ns entry.effective_at_ns < 0 then Pass
  else
    match entry.break_ with
    | Split { ratio } -> Rewrite { t with price = t.price /. ratio; size = t.size *. ratio }
    | Dividend _ -> Pass (* dividends adjust historical prices via a separate offline pass *)
    | Symbol_change { from_; to_ } ->
      if String.equal t.symbol from_ then Rewrite { t with symbol = to_ } else Pass
    | Fork { parent; children } ->
      if String.equal t.symbol parent then
        Emit_synthetic
          (List.map
             (fun (child_sym, ratio) -> { t with symbol = child_sym; size = t.size *. ratio })
             children)
      else Pass
    | Halt { until_ns } -> if Int64.compare t.ts_ns until_ns < 0 then Drop else Pass


let apply entries tick =
  let folded =
    List.fold_left
      (fun acc entry ->
        match acc with
        | Drop | Emit_synthetic _ -> acc
        | Pass -> (match apply_one entry tick with Pass -> Pass | other -> other)
        | Rewrite t' -> (match apply_one entry t' with Pass -> Rewrite t' | other -> other))
      Pass entries in
    folded


(* ───── JSON config loader ───────────────────────────────────────── *)

let entry_of_json (j : Yojson.Safe.t) : (entry, string) result =
  match j with
  | `Assoc obj ->
    let str k = match List.assoc_opt k obj with Some (`String s) -> Some s | _ -> None in
    let int64 k =
      match List.assoc_opt k obj with
      | Some (`Int n) -> Some (Int64.of_int n)
      | Some (`Intlit s) -> (try Some (Int64.of_string s) with _ -> None)
      | _ -> None in
    let float k =
      match List.assoc_opt k obj with
      | Some (`Float f) -> Some f
      | Some (`Int n) -> Some (float_of_int n)
      | _ -> None in
    let effective = int64 "effective_at_ns" in
    let kind = str "kind" in
    let source = Option.value (str "source") ~default:"local" in
      (match (effective, kind) with
      | None, _ -> Error "missing effective_at_ns"
      | _, None -> Error "missing kind"
      | Some eff, Some k ->
        let break_res =
          match k with
          | "split" ->
            (match float "ratio" with
            | Some r -> Ok (Split { ratio = r })
            | None -> Error "split: missing ratio")
          | "dividend" ->
            (match (float "amount", str "currency") with
            | Some amt, Some cur -> Ok (Dividend { amount = amt; currency = cur })
            | _ -> Error "dividend: missing amount/currency")
          | "symbol_change" ->
            (match (str "from", str "to") with
            | Some f, Some tg -> Ok (Symbol_change { from_ = f; to_ = tg })
            | _ -> Error "symbol_change: missing from/to")
          | "halt" ->
            (match int64 "until_ns" with
            | Some u -> Ok (Halt { until_ns = u })
            | None -> Error "halt: missing until_ns")
          | "fork" ->
            (match (str "parent", List.assoc_opt "children" obj) with
            | Some p, Some (`List xs) ->
              let children =
                List.filter_map
                  (function
                    | `Assoc o ->
                      let s =
                        match List.assoc_opt "symbol" o with
                        | Some (`String s) -> Some s
                        | _ -> None in
                      let r =
                        match List.assoc_opt "ratio" o with
                        | Some (`Float f) -> Some f
                        | Some (`Int n) -> Some (float_of_int n)
                        | _ -> None in
                        (match (s, r) with Some s, Some r -> Some (s, r) | _ -> None)
                    | _ -> None)
                  xs in
                Ok (Fork { parent = p; children })
            | _ -> Error "fork: missing parent/children")
          | other -> Error (Printf.sprintf "unknown kind: %s" other) in
          (match break_res with
          | Ok br -> Ok { effective_at_ns = eff; break_ = br; source }
          | Error e -> Error e))
  | _ -> Error "expected JSON object"


let load_file path =
  match Yojson.Safe.from_file path with
  | exception Yojson.Json_error msg -> Error ("data_break: " ^ msg)
  | exception Sys_error msg -> Error ("data_break: " ^ msg)
  | `List items ->
    let parsed = List.map entry_of_json items in
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | Ok x :: rest -> collect (x :: acc) rest
      | Error e :: _ -> Error e in
      collect [] parsed
  | _ -> Error "expected top-level JSON array"
