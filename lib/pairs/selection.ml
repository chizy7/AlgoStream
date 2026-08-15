module Symbol = Algostream_normalization.Symbol

type universe =
  | Explicit of (Symbol.t * Symbol.t) list
  | All_pairs_of of Symbol.t list

type criteria = {
  min_n : int;
  min_corr : float;
  max_adf_pvalue : float;
  min_half_life_bars : float;
  max_half_life_bars : float;
  max_beta_stdev : float;
  min_avg_volume : float;
}

type candidate = {
  pair : Pair_id.t;
  corr : float;
  beta : float;
  beta_stdev : float;
  adf_t_stat : float;
  adf_p_value : float;
  half_life : float;
  avg_volume : float;
  rank : float;
}

let default_criteria =
  {
    min_n = 64;
    min_corr = 0.5;
    max_adf_pvalue = 0.05;
    min_half_life_bars = 1.0;
    max_half_life_bars = 100.0;
    max_beta_stdev = 0.5;
    min_avg_volume = 0.0;
  }


let enumerate_pairs = function
  | Explicit ps -> List.map (fun (a, b) -> Pair_id.of_symbols a b) ps
  | All_pairs_of syms ->
    let arr = Array.of_list syms in
    let n = Array.length arr in
    let acc = ref [] in
      for i = 0 to n - 1 do
        for j = i + 1 to n - 1 do
          acc := Pair_id.of_symbols arr.(i) arr.(j) :: !acc
        done
      done ;
      List.rev !acc


let rank_score ~corr ~p_value ~half_life =
  let p_term = max 0.0 (1.0 -. p_value) in
  let c_term = abs_float corr in
  let hl_safe = if half_life <> half_life then 0.0 else max 0.0 half_life in
  let hl_term = 1.0 /. (1.0 +. hl_safe) in
    (0.4 *. p_term) +. (0.4 *. c_term) +. (0.2 *. hl_term)


let is_nan x = x <> x

let candidates snaps criteria =
  List.filter_map
    (fun (s : Snapshot.t) ->
      if s.n_ticks < criteria.min_n then None
      else if abs_float s.corr < criteria.min_corr then None
      else if s.adf_p_value > criteria.max_adf_pvalue then None
      else if
        is_nan s.half_life_bars
        || s.half_life_bars < criteria.min_half_life_bars
        || s.half_life_bars > criteria.max_half_life_bars
      then None
      else if s.beta_stdev > criteria.max_beta_stdev then None
      else if s.avg_volume < criteria.min_avg_volume then None
      else
        Some
          {
            pair = s.pair;
            corr = s.corr;
            beta = s.beta;
            beta_stdev = s.beta_stdev;
            adf_t_stat = s.adf_t_stat;
            adf_p_value = s.adf_p_value;
            half_life = s.half_life_bars;
            avg_volume = s.avg_volume;
            rank = rank_score ~corr:s.corr ~p_value:s.adf_p_value ~half_life:s.half_life_bars;
          })
    snaps
  |> List.sort (fun a b -> compare b.rank a.rank)
