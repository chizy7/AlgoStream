(** Markov regime-switching simulation.

    [Analytics.Regime] is a {i detector}: threshold rules with dwell hysteresis that label a series
    it is shown. It has no transition matrix and no sampler, so "market regime change simulation" is
    new work.

    {b What this is, precisely.} The detector labels a historical series; transition probabilities
    are then the Laplace-smoothed counts of observed label changes, and each state's emission is the
    within-state mean and standard deviation of returns. Simulation samples the chain and draws
    returns from the emission of the sampled state.

    {b What this is not.} It is not a hidden Markov model. There is no Baum-Welch, no EM, no state
    uncertainty — the states are taken as observed, because the detector observed them. That is a
    real modelling assumption and it is stated rather than buried: the detector's labels inherit
    whatever bias its thresholds have, and this model inherits it in turn. What it does capture, and
    what an iid bootstrap cannot, is that calm periods cluster, crises are sticky, and the
    transition between them is abrupt. *)

module Rng = Algostream_rng.Rng
module Regime = Algostream_analytics.Regime

type state_params = {
  label : Regime.t;
  mu : float;  (** mean return per period within this state *)
  sigma : float;  (** return standard deviation within this state *)
  n_observed : int;  (** how many observations backed the estimate; low counts are unreliable *)
}

type spec = {
  states : state_params array;
  transition : float array array;  (** row-stochastic: [transition.(i).(j) = P(j | i)] *)
  initial : float array;  (** initial state distribution *)
}

(** Label a return series with the existing detector by driving [Analytics.Per_symbol] headlessly —
    no bus, no Domain, the same Pattern-B usage the determinism tests use.

    [interval_ns] is the spacing between observations; the detector's dwell hysteresis is in event
    time, so this matters. *)
val label_series :
  returns:float array -> start_ts_ns:int64 -> interval_ns:int64 -> s0:float -> Regime.t array

(** Fit a chain from labels and the returns that produced them. Transition counts are
    Laplace-smoothed by [smoothing] (default 1.0) so a state observed once does not get a degenerate
    row of zeros and ones. *)
val fit_from_labels :
  labels:Regime.t array -> returns:float array -> ?smoothing:float -> unit -> spec

(** Convenience: {!label_series} then {!fit_from_labels}. *)
val fit :
  returns:float array ->
  start_ts_ns:int64 ->
  interval_ns:int64 ->
  s0:float ->
  ?smoothing:float ->
  unit ->
  spec

(** Sample [n] steps. Returns the state sequence alongside the returns, so a caller can attribute
    performance by regime afterwards. *)
val simulate : rng:Rng.t -> spec -> n:int -> Regime.t array * float array

(** Force a transition into [to_state] at [at_step] and let the chain run freely either side. The
    literal "market regime change simulation" scenario: how does the strategy behave when calm
    becomes crisis at a known moment? *)
val simulate_with_break :
  rng:Rng.t -> spec -> n:int -> to_state:int -> at_step:int -> Regime.t array * float array

(** Expected dwell time in each state, [1 / (1 - p_ii)] periods. A sanity check on a fitted chain:
    if crisis dwell comes out at 1.2 periods, the labelling window was too short. *)
val expected_dwell : spec -> float array

(** Long-run state distribution, by power iteration from [spec.initial].

    Starting from [initial] rather than from uniform matters whenever the chain is reducible — and a
    fitted chain usually is, because a regime the detector never labelled ends up with an absorbing
    self-loop from the smoothing. A uniform start would park probability mass in states the process
    can never reach and report a distribution the simulator does not produce. For an irreducible
    chain the two agree. *)
val stationary_distribution : spec -> float array

val spec_to_string : spec -> string
