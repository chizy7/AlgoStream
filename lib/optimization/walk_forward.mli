(** Walk-forward analysis: optimize on a training window, evaluate on the window that follows, then
    roll forward.

    {b The headline number is the stitched out-of-sample curve, not the average of per-fold
      Sharpes.} Averaging per-fold ratios hides compounding — three consecutive losing folds average
    to the same number as three scattered ones, but the drawdown they produce is entirely different.
    Concatenating the out-of-sample equity across folds and measuring once is the honest figure, and
    it is what {!report.stitched_oos} reports.

    For the same reason each fold's test period begins from the {i previous} fold's terminal NAV
    rather than from the initial capital. Resetting equity at every boundary would silently erase
    every drawdown that spans one. *)

module Metrics = Algostream_performance.Metrics

type scheme =
  | Rolling of {
      train_ns : int64;
      test_ns : int64;
      step_ns : int64;
    }
    (** fixed-length training window that slides — adapts to regime change, at the cost of a shorter
        estimation sample *)
  | Anchored of {
      initial_train_ns : int64;
      test_ns : int64;
      step_ns : int64;
    }  (** training window grows from a fixed start — more data per fit, slower to adapt *)

type fold = {
  index : int;
  train_lo_ns : int64;
  train_hi_ns : int64;
  test_lo_ns : int64;
  test_hi_ns : int64;
}

val folds : scheme -> lo_ns:int64 -> hi_ns:int64 -> fold array

type window = {
  fold : fold;
  best_params : (string * float) list;
  in_sample : Metrics.t;
  out_of_sample : Metrics.t;
  n_trials : int;
  score_stdev : float;  (** across the fold's trials; feeds the deflated Sharpe *)
}

type report = {
  windows : window array;
  stitched_oos : Metrics.t;  (** the headline: metrics over the concatenated OOS equity curve *)
  stitched_oos_nav : (int64 * float) array;
  walk_forward_efficiency : float;  (** mean OOS objective / mean IS objective; below ~0.5 is bad *)
  degradation : float;  (** mean IS − mean OOS, in objective units *)
  param_stability : (string * float) array;
    (** per dimension, [stdev / |mean|] across folds. A parameter that jumps around between folds
        was never really estimated — it was fitted to noise. *)
  n_folds : int;
  n_folds_positive : int;
  deflated_sharpe : float;  (** of the stitched OOS curve, against the total trial count *)
}

(** [run] optimizes within each fold's training window and evaluates on its test window.

    [optimize] receives the fold and returns the winning parameters plus the search report; [eval]
    evaluates a parameter set over an explicit time window and returns both metrics and the NAV
    curve, so the stitcher can chain terminal equity across folds. *)
val run :
  scheme:scheme ->
  lo_ns:int64 ->
  hi_ns:int64 ->
  objective:Objective.t ->
  optimize:(fold -> Search.report) ->
  eval:(fold -> (string * float) list -> Metrics.t * (int64 * float) array) ->
  report

val report_to_string : report -> string
