module Metrics = Algostream_performance.Metrics
module Benchmark_compare = Algostream_performance.Benchmark_compare
module Nav_align = Algostream_performance.Nav_align
module Supervisor = Algostream_runtime.Supervisor

type t = {
  a_id : string;
  b_id : string;
  n_periods : int;
  overlap_ns : int64;
  periods_per_year : float;
  a_metrics : Metrics.t;
  b_metrics : Metrics.t;
  relative : Benchmark_compare.t;
  a_curve : (int64 * float) array;
  b_curve : (int64 * float) array;
}

type error =
  [ `Unknown_instance of string
  | `Same_instance of string
  | `No_overlap
  | `Too_short of int
  ]

let min_periods = 8

let error_to_string = function
  | `Unknown_instance id -> Printf.sprintf "no running instance with id %S" id
  | `Same_instance id -> Printf.sprintf "cannot compare %S with itself" id
  | `No_overlap -> "the two instances have no overlapping sampled window yet"
  | `Too_short n ->
    Printf.sprintf "only %d aligned points; %d are needed before a comparison means anything" n
      min_periods


let of_curves ~a_id ~b_id ~a ~b =
  if String.equal a_id b_id then Error (`Same_instance a_id)
  else
    let al = Nav_align.align a b in
      if al.Nav_align.n = 0 then Error `No_overlap
      else if al.Nav_align.n < min_periods then Error (`Too_short al.Nav_align.n)
      else
        let ppy =
          (* Falling back to a nominal annualization would quietly turn a broken grid into a
             plausible Sharpe. A degenerate grid gets 0.0, which makes the annualized figures
             obviously unusable rather than subtly wrong. *)
          match Nav_align.periods_per_year al.Nav_align.ts_ns with
          | Some p -> p
          | None -> 0.0 in
        let curve v = Array.mapi (fun i t -> (t, v.(i))) al.Nav_align.ts_ns in
        let a_curve = curve al.Nav_align.a and b_curve = curve al.Nav_align.b in
        let a_metrics = Metrics.of_nav ~nav:a_curve () in
        let b_metrics = Metrics.of_nav ~nav:b_curve () in
        (* A is the benchmark, so alpha/beta/capture read as "B relative to A". *)
        let relative =
          Benchmark_compare.compare
            ~strategy:(Nav_align.returns al.Nav_align.b)
            ~benchmark:(Nav_align.returns al.Nav_align.a)
            ~periods_per_year:ppy () in
          Ok
            {
              a_id;
              b_id;
              n_periods = al.Nav_align.n;
              overlap_ns = al.Nav_align.overlap_ns;
              periods_per_year = ppy;
              a_metrics;
              b_metrics;
              relative;
              a_curve;
              b_curve;
            }


let of_supervisor sup ~a_id ~b_id =
  let curves = Supervisor.nav_curves sup in
  let get id = List.assoc_opt id curves in
    match (get a_id, get b_id) with
    | None, _ -> Error (`Unknown_instance a_id)
    | _, None -> Error (`Unknown_instance b_id)
    | Some a, Some b -> of_curves ~a_id ~b_id ~a ~b


(* Serialised here rather than in Json so that lib/infrastructure/network keeps knowing nothing
   about performance metrics; the server hands this straight through. *)
let series_to_json (c : (int64 * float) array) =
  `List
    (Array.to_list (Array.map (fun (t, v) -> `List [ `Intlit (Int64.to_string t); `Float v ]) c))


let float_json v = if Float.is_finite v then `Float v else `Null

let metrics_to_json (m : Metrics.t) =
  `Assoc (Array.to_list (Array.map (fun (k, v) -> (k, float_json v)) (Metrics.to_assoc m)))


let relative_to_json (r : Benchmark_compare.t) =
  `Assoc
    [
      ("n_periods", `Int r.Benchmark_compare.n_periods);
      ("alpha_ann", float_json r.Benchmark_compare.alpha_ann);
      ("beta", float_json r.Benchmark_compare.beta);
      ("r_squared", float_json r.Benchmark_compare.r_squared);
      ("correlation", float_json r.Benchmark_compare.correlation);
      ("tracking_error_ann", float_json r.Benchmark_compare.tracking_error_ann);
      ("information_ratio", float_json r.Benchmark_compare.information_ratio);
      ("active_return_ann", float_json r.Benchmark_compare.active_return_ann);
      ("up_capture", float_json r.Benchmark_compare.up_capture);
      ("down_capture", float_json r.Benchmark_compare.down_capture);
      ("capture_ratio", float_json r.Benchmark_compare.capture_ratio);
      ("treynor", float_json r.Benchmark_compare.treynor);
    ]


let to_json t =
  `Assoc
    [
      ("a_id", `String t.a_id);
      ("b_id", `String t.b_id);
      ("n_periods", `Int t.n_periods);
      ("overlap_ns", `Intlit (Int64.to_string t.overlap_ns));
      ("periods_per_year", float_json t.periods_per_year);
      ("a", `Assoc [ ("metrics", metrics_to_json t.a_metrics); ("curve", series_to_json t.a_curve) ]);
      ("b", `Assoc [ ("metrics", metrics_to_json t.b_metrics); ("curve", series_to_json t.b_curve) ]);
      (* Named to say which way round it is: every field is B measured against A. *)
      ("b_vs_a", relative_to_json t.relative);
    ]
