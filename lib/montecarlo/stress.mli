(** Stress scenarios applied to a record stream.

    {b The presets are stylized, not replays.} [black_monday_1987] applies a gap and a volatility
    multiplier of roughly the magnitude that day is remembered for; it is not a tick replay of 19
    October 1987, and this system has no such data. Treat them as shaped what-ifs with round
    numbers, subject to the same two-significant-figure honesty the rest of the codebase claims.

    When enough history exists, {!conditional} is strictly preferable: it bootstraps from the worst
    windows the instrument {i actually} experienced, so the magnitudes are empirical rather than
    invented. Reach for the presets when you need a shock more extreme than your sample contains. *)

module Rng = Algostream_rng.Rng
module Data_source = Algostream_backtest.Data_source

type shock =
  | Price_pct of float  (** instantaneous gap, e.g. [-0.22] *)
  | Drift_pct_per_day of float
  | Vol_multiplier of float  (** scales deviations from the local mean *)
  | Spread_multiplier of float  (** widens the quoted spread *)
  | Depth_multiplier of float  (** liquidity evaporation; thins synthetic book levels *)
  | Halt of { duration_ns : int64 }  (** records suppressed; resting orders age through it *)

type decay =
  | Instant  (** full magnitude for the whole window, then gone *)
  | Linear  (** ramps to zero across the window *)
  | Exponential of float  (** half-life as a fraction of the window *)

type scenario = {
  name : string;
  description : string;
  shocks : (string option * shock) list;  (** [None] applies to every symbol *)
  onset_ns : int64;
  duration_ns : int64;
  decay : decay;
}

(** Round-number scenarios shaped after well-known episodes. Magnitudes are approximate by
    construction — see the header. *)
val black_monday_1987 : scenario

val ltcm_1998 : scenario

val lehman_2008 : scenario

val flash_crash_2010 : scenario

val covid_march_2020 : scenario

val luna_may_2022 : scenario

val ftx_nov_2022 : scenario

val all_presets : scenario array

val find_preset : string -> scenario option

(** Apply a scenario to a record stream. Timestamps are preserved except where a [Halt] suppresses
    records entirely. *)
val apply : scenario -> records:Data_source.record array -> Data_source.record array

(** Rebase a scenario's onset to a fraction of the way through a record stream — so a preset written
    with absolute timestamps can be dropped into any sample. *)
val at_fraction : scenario -> records:Data_source.record array -> fraction:float -> scenario

(** Bootstrap restricted to the worst [worst_pct] of historical windows of length [block_len].
    Empirical stress with no invented magnitudes. Prefer this when the sample is long enough to
    contain the kind of event you want to stress against. *)
val conditional :
  rng:Rng.t -> data:float array -> worst_pct:float -> block_len:int -> n:int -> float array

val scenario_to_string : scenario -> string
