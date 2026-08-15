(** Pair universe enumeration + screening / ranking.

    [Explicit] keeps the candidate pair list under the caller's control. [All_pairs_of] enumerates
    the [N(N-1)/2] symmetric pairs of a symbol list (lexicographic [y < x] ordering, mirroring
    [Pair_id.of_symbols]).

    [candidates] reads [Snapshot.t] values (allocated by the Processor and read via [Atomic.get])
    and applies the [criteria] filter, then sorts by [rank] descending. The default ranker is a
    weighted score over (1 − p_value), |corr|, and 1/(1 + half_life) — sensible heuristic;
    strategies override by computing their own [candidate] list. *)

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

val default_criteria : criteria

val enumerate_pairs : universe -> Pair_id.t list

val candidates : Snapshot.t list -> criteria -> candidate list
