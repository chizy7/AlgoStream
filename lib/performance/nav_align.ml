type aligned = {
  ts_ns : int64 array;
  a : float array;
  b : float array;
  n : int;
  overlap_ns : int64;
}

let empty = { ts_ns = [||]; a = [||]; b = [||]; n = 0; overlap_ns = 0L }

(* Sort by timestamp and collapse duplicates, keeping the last value — the same rule the nav ring
   applies when two samples land in the same nanosecond. Stable sort so "last" is well defined. *)
let normalize (curve : (int64 * float) array) =
  let c = Array.copy curve in
    Array.stable_sort (fun (t1, _) (t2, _) -> Int64.compare t1 t2) c ;
    let n = Array.length c in
      if n = 0 then [||]
      else
        let out = Array.make n c.(0) in
        let k = ref 0 in
          out.(0) <- c.(0) ;
          for i = 1 to n - 1 do
            let t, v = c.(i) in
            let pt, _ = out.(!k) in
              if Int64.equal t pt then out.(!k) <- (t, v)
              else (
                incr k ;
                out.(!k) <- (t, v))
          done ;
          Array.sub out 0 (!k + 1)


(* Last observation at or before [t]. [from] is the caller's cursor: the grid is ascending and both
   series are ascending, so the scan advances monotonically and the whole alignment is linear rather
   than quadratic. *)
let advance (c : (int64 * float) array) ~from ~t =
  let n = Array.length c in
  let i = ref from in
    while !i + 1 < n && Int64.compare (fst c.(!i + 1)) t <= 0 do
      incr i
    done ;
    !i


let align ca cb =
  let ca = normalize ca and cb = normalize cb in
  let na = Array.length ca and nb = Array.length cb in
    if na = 0 || nb = 0 then empty
    else
      (* The window both curves actually cover. Outside it one series has no observation to carry
         forward, and inventing one would fabricate a comparison. *)
      let lo = if Int64.compare (fst ca.(0)) (fst cb.(0)) >= 0 then fst ca.(0) else fst cb.(0) in
      let hi_a = fst ca.(na - 1) and hi_b = fst cb.(nb - 1) in
      let hi = if Int64.compare hi_a hi_b <= 0 then hi_a else hi_b in
        if Int64.compare lo hi > 0 then empty
        else
          let within c =
            Array.to_list c
            |> List.filter_map (fun (t, _) ->
                 if Int64.compare t lo >= 0 && Int64.compare t hi <= 0 then Some t else None) in
          let merged = List.sort_uniq Int64.compare (within ca @ within cb) in
          let grid = Array.of_list merged in
          let n = Array.length grid in
            if n = 0 then empty
            else
              let va = Array.make n 0.0 and vb = Array.make n 0.0 in
              let ia = ref 0 and ib = ref 0 in
                Array.iteri
                  (fun k t ->
                    ia := advance ca ~from:!ia ~t ;
                    ib := advance cb ~from:!ib ~t ;
                    va.(k) <- snd ca.(!ia) ;
                    vb.(k) <- snd cb.(!ib))
                  grid ;
                { ts_ns = grid; a = va; b = vb; n; overlap_ns = Int64.sub hi lo }


let returns v =
  let n = Array.length v in
    if n < 2 then [||]
    else
      Array.init (n - 1) (fun i ->
        let p = v.(i) in
          if p > 0.0 then (v.(i + 1) -. p) /. p else 0.0)


let median_interval_ns grid =
  let n = Array.length grid in
    if n < 2 then None
    else
      let d = Array.init (n - 1) (fun i -> Int64.sub grid.(i + 1) grid.(i)) in
        Array.sort Int64.compare d ;
        Some d.(Array.length d / 2)


let periods_per_year grid =
  match median_interval_ns grid with
  | None -> None
  | Some iv ->
    if Int64.compare iv 0L <= 0 then None
    else Some (365.25 *. 24.0 *. 3600.0 *. 1e9 /. Int64.to_float iv)
