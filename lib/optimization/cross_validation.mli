(** Time-series cross-validation with purging and embargo.

    Naive k-fold on financial returns leaks. Observations near a fold boundary are serially
    correlated with observations on the other side, so a model fitted on one has partial knowledge
    of the other, and the out-of-sample Sharpe comes back inflated. The correction (López de Prado)
    is two-part:

    - {b purge}: drop training observations whose evaluation window overlaps the test fold;
    - {b embargo}: additionally drop training observations for a period {i after} the test fold,
      since the test period's information bleeds forward.

    {!Combinatorial_purged} goes further. Rather than one train/test split per fold, it takes every
    combination of [n_test_groups] out of [n_groups] as the test set, producing many distinct
    out-of-sample paths — and therefore a {i distribution} of out-of-sample Sharpe instead of a
    point estimate. Combined with [Stochastic.Quantile.percentile_interval] that gives an honest
    confidence interval on out-of-sample performance with no new dependencies. *)

module Metrics = Algostream_performance.Metrics
module Quantile = Algostream_stochastic.Quantile

type scheme =
  | Purged_kfold of {
      k : int;
      embargo_ns : int64;
    }
  | Combinatorial_purged of {
      n_groups : int;
      n_test_groups : int;
      embargo_ns : int64;
    }

type split = {
  index : int;
  train : (int64 * int64) array;  (** possibly several intervals, since purging cuts holes *)
  test : (int64 * int64) array;
}

(** Build the splits covering [[lo_ns, hi_ns]]. *)
val splits : scheme -> lo_ns:int64 -> hi_ns:int64 -> split array

(** Number of splits a scheme will produce, without building them. For [Combinatorial_purged] this
    is [C(n_groups, n_test_groups)] and grows fast — 10 choose 2 is 45, 20 choose 4 is 4845. *)
val n_splits : scheme -> int

(** True if no training interval in [split] intersects any test interval or its embargo. The
    property the whole module exists to guarantee; asserted directly in the test suite. *)
val is_leak_free : split -> embargo_ns:int64 -> bool

type report = {
  scheme : string;
  per_split : Metrics.t array;
  mean_oos : float;  (** mean of the objective across splits *)
  oos_distribution : Quantile.summary;  (** the point of CPCV: a distribution, not a point *)
  n_splits : int;
  n_failed : int;
}

(** [run] evaluates [eval] on each split's test window and summarizes. [eval] receives the split so
    it can restrict its data accordingly. *)
val run :
  scheme:scheme ->
  lo_ns:int64 ->
  hi_ns:int64 ->
  objective:Objective.t ->
  eval:(split -> Metrics.t) ->
  n_domains:int ->
  report

val report_to_string : report -> string
