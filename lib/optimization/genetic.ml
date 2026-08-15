module Rng = Algostream_rng.Rng
module Variate = Algostream_stochastic.Variate

type config = {
  population : int;
  generations : int;
  crossover_rate : float;
  mutation_rate : float;
  elitism : int;
  tournament_size : int;
}

let default_config =
  {
    population = 64;
    generations = 40;
    crossover_rate = 0.8;
    mutation_rate = 0.1;
    elitism = 2;
    tournament_size = 3;
  }


type error =
  [ `Empty_space
  | `Bad_config of string
  ]

let error_to_string = function
  | `Empty_space -> "the search space has no dimensions, so there is nothing to optimize"
  | `Bad_config m -> "invalid genetic config: " ^ m


let validate (c : config) =
  if c.population < 2 then Error (`Bad_config "population must be at least 2")
  else if c.generations < 0 then Error (`Bad_config "generations must not be negative")
  else if c.elitism < 0 || c.elitism >= c.population then
    Error (`Bad_config "elitism must be in [0, population)")
  else if c.tournament_size < 1 || c.tournament_size > c.population then
    Error (`Bad_config "tournament_size must be in [1, population]")
  else if c.crossover_rate < 0.0 || c.crossover_rate > 1.0 then
    Error (`Bad_config "crossover_rate must be in [0, 1]")
  else if c.mutation_rate < 0.0 || c.mutation_rate > 1.0 then
    Error (`Bad_config "mutation_rate must be in [0, 1]")
  else Ok ()


(* Per-dimension bounds, used to scale mutation. A Grid dimension is treated as the interval its
   values span: the GA moves continuously and Search_space.clamp snaps back to the grid, so a
   discrete dimension stays discrete without needing a separate operator. *)
let dim_range (d : Search_space.dim) =
  match d.Search_space.spec with
  | Search_space.Uniform { lo; hi } | Search_space.Log_uniform { lo; hi } -> (lo, hi)
  | Search_space.Int_range { lo; hi; _ } -> (float_of_int lo, float_of_int hi)
  | Search_space.Grid vs ->
    if Array.length vs = 0 then (0.0, 0.0)
    else Array.fold_left (fun (a, b) v -> (Float.min a v, Float.max b v)) (vs.(0), vs.(0)) vs


let names space = List.map (fun (d : Search_space.dim) -> d.Search_space.name) space

(* Chromosomes are plain float arrays in dimension order, so crossover and mutation are array
   operations rather than assoc-list surgery. *)
let to_vector space (p : (string * float) list) =
  Array.of_list
    (List.map
       (fun (d : Search_space.dim) ->
         match List.assoc_opt d.Search_space.name p with Some v -> v | None -> 0.0)
       space)


let of_vector space v = List.mapi (fun i n -> (n, v.(i))) (names space)

(* Tournament selection: sample [k] individuals uniformly and take the fittest. Pressure is set by
   [k] alone, and unlike fitness-proportionate selection it is invariant to the scale and sign of
   the objective — which matters here because objectives include raw Sharpe, negative drawdown and
   penalised combinations, whose magnitudes are not comparable. A failed trial scores neg_infinity
   and therefore loses every tournament it enters without needing a special case. *)
let tournament rng ~scores ~k =
  let n = Array.length scores in
  let best = ref (Rng.int_below rng n) in
    for _ = 2 to k do
      let c = Rng.int_below rng n in
        if scores.(c) > scores.(!best) then best := c
    done ;
    !best


(* BLX-α: sample each gene uniformly from the parents' interval widened by α on both sides. Widening
   is what stops the population collapsing onto the segment between the initial parents — plain
   interval crossover can only ever contract, so without it the search loses the ability to explore
   outward long before it has converged. α = 0.5 is the standard choice. *)
let blx_alpha rng ~alpha a b =
  Array.init (Array.length a) (fun i ->
    let lo = Float.min a.(i) b.(i) and hi = Float.max a.(i) b.(i) in
    let d = hi -. lo in
      Rng.uniform_range rng ~lo:(lo -. (alpha *. d)) ~hi:(hi +. (alpha *. d)))


(* Gaussian mutation, sigma scaled to each dimension's own range. A single absolute sigma would be
   an enormous step in one dimension and a negligible one in another whenever the ranges differ by
   orders of magnitude — which they do here: a z-score threshold spans ~1..4 while a lookback spans
   tens to hundreds. *)
let mutate rng ~space ~rate ~sigma_frac v =
  let dims = Array.of_list space in
    Array.mapi
      (fun i x ->
        if Rng.uniform rng < rate then
          let lo, hi = dim_range dims.(i) in
          let sigma = sigma_frac *. (hi -. lo) in
            if sigma <= 0.0 then x else x +. Variate.gaussian rng ~mu:0.0 ~sigma
        else x)
      v


let optimize ~space ~objective ~eval ~config ~root_seed ~n_domains =
  match validate config with
  | Error e -> Error e
  | Ok () ->
    if space = [] then Error `Empty_space
    else
      let alpha = 0.5 in
      let sigma_frac = 0.1 in
      (* Every generation draws from its own substream of root_seed, so a run is reproducible
         regardless of how the pool schedules evaluations or how many domains it uses — the same
         property Montecarlo.Engine relies on. *)
      let gen_rng g = Rng.substream ~root_seed ~index:g in
      let init_rng = gen_rng 0 in
      let initial = Array.init config.population (fun _ -> Search_space.sample space init_rng) in

      (* Every trial from every generation is retained, not just the final population. n_evaluated
         must be the true budget spent: it feeds Overfitting.deflated_sharpe_ratio's n_trials, and a
         GA that reported only its survivors would understate its own selection bias — which is
         precisely the failure this module's documentation warns about. *)
      let all_trials = ref [] in
      let next_index = ref 0 in
      let run_batch points =
        let trials = Search.evaluate ~points ~objective ~eval ~n_domains in
        (* Renumber into a single global sequence; Search.evaluate indexes within its own batch. *)
        let renumbered =
          Array.map
            (fun (t : Search.trial) ->
              let t = { t with Search.index = !next_index } in
                incr next_index ;
                t)
            trials in
          all_trials := renumbered :: !all_trials ;
          renumbered in

      let pop = ref initial in
      let scores = ref (Array.map (fun (t : Search.trial) -> t.Search.score) (run_batch initial)) in

      for g = 1 to config.generations do
        let rng = gen_rng g in
        let vectors = Array.map (to_vector space) !pop in
        (* Elites carried through unchanged. Without this the best solution found can be lost to a
           bad draw, and the best-so-far can go backwards between generations. *)
        let order = Array.init (Array.length !pop) (fun i -> i) in
          Array.sort (fun a b -> compare !scores.(b) !scores.(a)) order ;
          let next = Array.make config.population [] in
            for i = 0 to config.elitism - 1 do
              next.(i) <- !pop.(order.(i))
            done ;
            for i = config.elitism to config.population - 1 do
              let pa = vectors.(tournament rng ~scores:!scores ~k:config.tournament_size) in
              let child =
                if Rng.uniform rng < config.crossover_rate then
                  let pb = vectors.(tournament rng ~scores:!scores ~k:config.tournament_size) in
                    blx_alpha rng ~alpha pa pb
                else Array.copy pa in
              let child = mutate rng ~space ~rate:config.mutation_rate ~sigma_frac child in
                (* clamp is what keeps crossover and mutation inside the declared space, and what
                   snaps a Grid or Int_range dimension back onto its legal values. *)
                next.(i) <- Search_space.clamp space (of_vector space child)
            done ;
            pop := next ;
            scores := Array.map (fun (t : Search.trial) -> t.Search.score) (run_batch next)
      done ;

      let trials = Array.concat (List.rev !all_trials) in
        Ok (Search.assemble ~objective ~trials)
