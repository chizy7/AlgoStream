module Rng = Algostream_rng.Rng
module Resample = Algostream_stochastic.Resample
module Metrics = Algostream_performance.Metrics
module Quantile = Algostream_stochastic.Quantile
module Backtest_engine = Algostream_backtest.Engine
module Result = Algostream_backtest.Result
module Strategy = Algostream_strategy.Strategy

type config = {
  n_runs : int;
  root_seed : int64;
  n_domains : int;
  generator : Generator.t;
  n_steps : int;
  backtest : Backtest_engine.config;
  keep_first_n_results : int;
}

let default_config ~n_runs ~root_seed ~generator ~backtest =
  {
    n_runs;
    root_seed;
    n_domains = Pool.recommended_domains ();
    generator;
    n_steps = 1000;
    backtest;
    keep_first_n_results = 3;
  }


type summary = {
  n_runs : int;
  n_failed : int;
  root_seed : int64;
  generator : string;
  per_metric : (string * Quantile.summary) array;
  failures : (int * string) array;
  retained : Result.t array;
}

(* Transpose per-run metric vectors into per-metric distributions. Field order comes from
   Metrics.to_assoc and is stable, so index j is the same metric in every run. *)
let summarize_metrics (vectors : (string * float) array list) =
  match vectors with
  | [] -> [||]
  | first :: _ ->
    let k = Array.length first in
    let n = List.length vectors in
      Array.init k (fun j ->
        let name = fst first.(j) in
        let samples = Array.make n 0.0 in
          List.iteri (fun i v -> samples.(i) <- snd v.(j)) vectors ;
          (name, Quantile.summarize samples))


let run (type p) (module S : Strategy.S with type params = p) ~params ~(config : config) =
  let n = config.n_runs in
  let results =
    Pool.map_result ~n_domains:config.n_domains ~n ~f:(fun i ->
      (* Index 2i for data, 2i+1 for execution. Disjoint, and a pure function of (root_seed, i) — so
         this run is identical no matter which Domain picks it up. *)
      let rng_data = Rng.substream ~root_seed:config.root_seed ~index:(2 * i) in
      let data = Generator.build config.generator ~rng:rng_data ~n_steps:config.n_steps in
      let bt =
        { config.backtest with Backtest_engine.root_seed = config.root_seed; run_index = i } in
      let r = Backtest_engine.run (module S) ~params ~config:bt ~data in
      (* Metrics are computed HERE, in the worker. Only the ~27-float vector crosses back; a full
         equity curve per run would be gigabytes at 10k runs. *)
      let m = Metrics.of_nav ~nav:(Result.nav_curve r) () in
      let keep = if i < config.keep_first_n_results then Some r else None in
        (Metrics.to_assoc m, keep)) in
  let vectors = ref [] in
  let failures = ref [] in
  let retained = ref [] in
    Array.iteri
      (fun i r ->
        match r with
        | Ok (v, keep) ->
          vectors := v :: !vectors ;
          (match keep with Some res -> retained := res :: !retained | None -> ())
        | Error e -> failures := (i, Printexc.to_string e) :: !failures)
      results ;
    let vectors = List.rev !vectors in
      {
        n_runs = n;
        n_failed = List.length !failures;
        root_seed = config.root_seed;
        generator = Generator.to_string config.generator;
        per_metric = summarize_metrics vectors;
        failures = Array.of_list (List.rev !failures);
        retained = Array.of_list (List.rev !retained);
      }


let run_paths ~returns ~n_runs ~root_seed ~n_domains ~periods_per_year ?block_len ?n_domains_hint:_
  () =
  let n_src = Array.length returns in
  let b = match block_len with Some b -> b | None -> Resample.rule_of_thumb ~n:n_src in
  let results =
    Pool.map_result ~n_domains ~n:n_runs ~f:(fun i ->
      let rng = Rng.substream ~root_seed ~index:(2 * i) in
      (* Block, not iid: an iid resample of returns destroys volatility clustering and reports a
         drawdown distribution far too benign to be useful. *)
      let sample = Resample.circular_block rng ~data:returns ~block_len:b ~n:n_src in
      let m = Metrics.of_returns ~returns:sample ~periods_per_year () in
        Metrics.to_assoc m) in
  let vectors = ref [] in
  let failures = ref [] in
    Array.iteri
      (fun i r ->
        match r with
        | Ok v -> vectors := v :: !vectors
        | Error e -> failures := (i, Printexc.to_string e) :: !failures)
      results ;
    {
      n_runs;
      n_failed = List.length !failures;
      root_seed;
      generator = Printf.sprintf "path_level_block_bootstrap(b=%d)" b;
      per_metric = summarize_metrics (List.rev !vectors);
      failures = Array.of_list (List.rev !failures);
      retained = [||];
    }


type 'p arm = {
  params : 'p;
  backtest : Backtest_engine.config option;
}

let arm params = { params; backtest = None }

let arm_with params backtest = { params; backtest = Some backtest }

type comparison = {
  n_runs : int;
  n_failed : int;
  failures : (int * string) array;
  per_metric : (string * Quantile.summary) array;
}

let run_comparative (type p) (module S : Strategy.S with type params = p) ~(a : p arm) ~(b : p arm)
  ~(config : config) =
  let n = config.n_runs in
  let diffs =
    Pool.map_result ~n_domains:config.n_domains ~n ~f:(fun i ->
      (* Common random numbers: both arms see the SAME market, so the paired difference isolates the
         change under test instead of drowning it in path noise. *)
      let build_data () =
        let rng_data = Rng.substream ~root_seed:config.root_seed ~index:(2 * i) in
          Generator.build config.generator ~rng:rng_data ~n_steps:config.n_steps in
      (* root_seed and run_index are forced on both arms so the execution substream matches too; an
         arm supplying its own backtest config must not be able to change the draw. *)
      let bt_of arm_ =
        let base = match arm_.backtest with Some c -> c | None -> config.backtest in
          { base with Backtest_engine.root_seed = config.root_seed; run_index = i } in
      let ra =
        Backtest_engine.run (module S) ~params:a.params ~config:(bt_of a) ~data:(build_data ())
      in
      (* Rebuild the data for arm B from the same substream, so both arms genuinely share the path
         rather than sharing a consumed generator. *)
      let rb =
        Backtest_engine.run (module S) ~params:b.params ~config:(bt_of b) ~data:(build_data ())
      in
      let ma = Metrics.to_assoc (Metrics.of_nav ~nav:(Result.nav_curve ra) ()) in
      let mb = Metrics.to_assoc (Metrics.of_nav ~nav:(Result.nav_curve rb) ()) in
        Array.mapi (fun j (name, va) -> (name, snd mb.(j) -. va)) ma) in
  let vectors = ref [] in
  let failures = ref [] in
    Array.iteri
      (fun i r ->
        match r with
        | Ok v -> vectors := v :: !vectors
        | Error e -> failures := (i, Printexc.to_string e) :: !failures)
      diffs ;
    {
      n_runs = n;
      n_failed = List.length !failures;
      failures = Array.of_list (List.rev !failures);
      per_metric = summarize_metrics (List.rev !vectors);
    }


(* Annotated because [comparison] also has a [per_metric] field and would otherwise win inference by
   being defined later. *)
let metric (s : summary) name =
  Array.find_opt (fun (n, _) -> String.equal n name) s.per_metric |> Option.map snd


let summary_to_string (s : summary) =
  let b = Buffer.create 512 in
    Buffer.add_string b
      (Printf.sprintf "Monte Carlo: %d runs (%d failed) seed=%Ld generator=%s\n" s.n_runs s.n_failed
         s.root_seed s.generator) ;
    (* The headline metrics; the full set is in per_metric. *)
    List.iter
      (fun name ->
        match metric s name with
        | None -> ()
        | Some d ->
          Buffer.add_string b
            (Printf.sprintf
               "  %-16s mean=%+.4f  p05=%+.4f  p50=%+.4f  p95=%+.4f  ci95=[%+.4f, %+.4f]  \
                P(<0)=%.1f%%  mc_se(p05)=%.4f\n"
               name d.Quantile.mean d.Quantile.p05 d.Quantile.p50 d.Quantile.p95 d.Quantile.ci95_lo
               d.Quantile.ci95_hi
               (d.Quantile.prob_negative *. 100.0)
               d.Quantile.mc_se_p05))
      [ "total_return"; "cagr"; "sharpe"; "sortino"; "calmar"; "max_drawdown" ] ;
    if s.n_failed > 0 then (
      Buffer.add_string b (Printf.sprintf "  failures (%d):\n" s.n_failed) ;
      Array.iteri
        (fun i (idx, msg) ->
          if i < 5 then Buffer.add_string b (Printf.sprintf "    run %d: %s\n" idx msg))
        s.failures) ;
    Buffer.contents b
