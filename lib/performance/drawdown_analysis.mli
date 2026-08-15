(** Drawdown decomposed into episodes, with recovery times.

    Complements rather than duplicates the two existing drawdown facilities:

    - [Algostream_risk_management.Drawdown.Tracker] is a {i streaming} tracker for live risk gating
      — running peak, current drawdown, time under water. It answers "how bad is it right now".
    - [Portfolio.Risk_metrics.calculate_maximum_drawdown] returns a single scalar over a NAV
      history.

    Neither can answer "how many drawdowns were there, how deep, and how long did each take to
    recover" — drawdown analysis and recovery time calculation, and is what distinguishes a strategy
    with one catastrophic 30% drawdown from one with ten shallow ones that recover in a day.

    An {i episode} runs peak → trough → recovery. It opens when equity first falls below a running
    peak, and closes when equity regains that peak. The final episode may be unrecovered, in which
    case [recovery_ts_ns] and [recovery_ns] are [None] — reported honestly rather than closed at the
    end of the sample, which would understate the true recovery time. *)

type episode = {
  index : int;  (** 0-based, in chronological order *)
  peak_ts_ns : int64;
  trough_ts_ns : int64;
  recovery_ts_ns : int64 option;  (** [None] if still underwater at the end of the sample *)
  peak_equity : float;
  trough_equity : float;
  depth : float;  (** fractional, positive: [(peak - trough) / peak] *)
  decline_ns : int64;  (** peak → trough *)
  recovery_ns : int64 option;  (** trough → recovery *)
  underwater_ns : int64;  (** peak → recovery, or peak → end of sample if unrecovered *)
}

(** Extract every episode deeper than [min_depth] (fractional; default [0.0], i.e. all of them).
    [nav] must be in ascending time order. *)
val episodes : nav:(int64 * float) array -> ?min_depth:float -> unit -> episode array

(** The [n] deepest episodes, deepest first. *)
val worst : episode array -> n:int -> episode array

(** Maximum [depth] across episodes; [0.0] when there are none. Agrees with
    [Portfolio.Risk_metrics.calculate_maximum_drawdown] on the same NAV history — cross-checked in
    the test suite. *)
val max_depth : episode array -> float

(** Longest [underwater_ns] across episodes, recovered or not. Usually a more decision-relevant
    number than maximum depth: a 10% drawdown lasting two years is worse than a 25% one that
    recovers in a week. *)
val longest_underwater_ns : episode array -> int64

(** Mean and median recovery time over {b recovered} episodes only. [None] when none recovered —
    averaging in the unrecovered ones as though they had recovered at the sample end would bias the
    figure downward. *)
val mean_recovery_ns : episode array -> int64 option

val median_recovery_ns : episode array -> int64 option

(** Fraction of episodes that recovered within the sample. *)
val recovery_rate : episode array -> float

(** Underwater curve: fractional drawdown from the running peak at every NAV point. Same length as
    [nav]; the natural input for an underwater plot. *)
val underwater_curve : nav:(int64 * float) array -> (int64 * float) array

(** Ulcer index — root-mean-square of the underwater curve (in percent). Penalizes deep {i and}
    prolonged drawdowns, unlike maximum drawdown which is blind to duration. *)
val ulcer_index : nav:(int64 * float) array -> float

(** Mean of the underwater curve — the average fractional drawdown experienced across the sample. *)
val pain_index : nav:(int64 * float) array -> float

val episode_to_string : episode -> string
