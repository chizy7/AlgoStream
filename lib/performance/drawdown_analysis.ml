type episode = {
  index : int;
  peak_ts_ns : int64;
  trough_ts_ns : int64;
  recovery_ts_ns : int64 option;
  peak_equity : float;
  trough_equity : float;
  depth : float;
  decline_ns : int64;
  recovery_ns : int64 option;
  underwater_ns : int64;
}

let episodes ~nav ?(min_depth = 0.0) () =
  let n = Array.length nav in
    if n < 2 then [||]
    else
      let out = ref [] in
      let count = ref 0 in
      (* Running peak. An episode is open whenever equity sits below it. *)
      let peak_ts, peak_eq = nav.(0) in
      let peak_ts = ref peak_ts and peak_eq = ref peak_eq in
      let in_episode = ref false in
      let trough_ts = ref 0L and trough_eq = ref 0.0 in
      let close_episode ~recovery_ts_ns ~end_ts_ns =
        let depth = if !peak_eq > 0.0 then (!peak_eq -. !trough_eq) /. !peak_eq else 0.0 in
          if depth >= min_depth && depth > 0.0 then (
            let ep =
              {
                index = !count;
                peak_ts_ns = !peak_ts;
                trough_ts_ns = !trough_ts;
                recovery_ts_ns;
                peak_equity = !peak_eq;
                trough_equity = !trough_eq;
                depth;
                decline_ns = Int64.sub !trough_ts !peak_ts;
                recovery_ns =
                  (match recovery_ts_ns with
                  | Some r -> Some (Int64.sub r !trough_ts)
                  | None -> None);
                underwater_ns = Int64.sub end_ts_ns !peak_ts;
              } in
              out := ep :: !out ;
              incr count) in
        for i = 1 to n - 1 do
          let ts, eq = nav.(i) in
            if eq >= !peak_eq then (
              (* Regained the peak: close any open episode, then advance the peak. *)
              if !in_episode then (
                close_episode ~recovery_ts_ns:(Some ts) ~end_ts_ns:ts ;
                in_episode := false) ;
              peak_eq := eq ;
              peak_ts := ts)
            else if not !in_episode then (
              in_episode := true ;
              trough_eq := eq ;
              trough_ts := ts)
            else if eq < !trough_eq then (
              trough_eq := eq ;
              trough_ts := ts)
        done ;
        (* A still-open episode at the end of the sample is reported unrecovered, not retroactively
           closed — closing it would understate the true recovery time. *)
        (if !in_episode then
           let last_ts, _ = nav.(n - 1) in
             close_episode ~recovery_ts_ns:None ~end_ts_ns:last_ts) ;
        Array.of_list (List.rev !out)


let worst eps ~n =
  let sorted = Array.copy eps in
    Array.sort (fun a b -> compare b.depth a.depth) sorted ;
    let k = min n (Array.length sorted) in
      Array.sub sorted 0 k


let max_depth eps = Array.fold_left (fun acc e -> if e.depth > acc then e.depth else acc) 0.0 eps

let longest_underwater_ns eps =
  Array.fold_left
    (fun acc e -> if Int64.compare e.underwater_ns acc > 0 then e.underwater_ns else acc)
    0L eps


let recovered eps = Array.to_list eps |> List.filter_map (fun e -> e.recovery_ns)

let mean_recovery_ns eps =
  match recovered eps with
  | [] -> None
  | rs ->
    let total = List.fold_left (fun acc r -> Int64.add acc r) 0L rs in
      Some (Int64.div total (Int64.of_int (List.length rs)))


let median_recovery_ns eps =
  match recovered eps with
  | [] -> None
  | rs ->
    let a = Array.of_list rs in
      Array.sort Int64.compare a ;
      Some a.(Array.length a / 2)


let recovery_rate eps =
  let n = Array.length eps in
    if n = 0 then 0.0
    else
      let r = List.length (recovered eps) in
        float_of_int r /. float_of_int n


let underwater_curve ~nav =
  let n = Array.length nav in
    if n = 0 then [||]
    else
      let peak = ref (snd nav.(0)) in
        Array.map
          (fun (ts, eq) ->
            if eq > !peak then peak := eq ;
            let dd = if !peak > 0.0 then (!peak -. eq) /. !peak else 0.0 in
              (ts, dd))
          nav


let ulcer_index ~nav =
  let uw = underwater_curve ~nav in
  let n = Array.length uw in
    if n = 0 then 0.0
    else
      let ss = Array.fold_left (fun acc (_, d) -> acc +. (d *. d)) 0.0 uw in
        sqrt (ss /. float_of_int n) *. 100.0


let pain_index ~nav =
  let uw = underwater_curve ~nav in
  let n = Array.length uw in
    if n = 0 then 0.0 else Array.fold_left (fun acc (_, d) -> acc +. d) 0.0 uw /. float_of_int n


let ns_to_days ns = Int64.to_float ns /. (24.0 *. 3600.0 *. 1e9)

let episode_to_string e =
  Printf.sprintf
    "#%d depth=%.2f%% decline=%.2fd recovery=%s underwater=%.2fd (peak=%.2f trough=%.2f)" e.index
    (e.depth *. 100.0) (ns_to_days e.decline_ns)
    (match e.recovery_ns with
    | Some r -> Printf.sprintf "%.2fd" (ns_to_days r)
    | None -> "unrecovered")
    (ns_to_days e.underwater_ns) e.peak_equity e.trough_equity
