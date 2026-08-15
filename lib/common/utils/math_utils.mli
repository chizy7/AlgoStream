(** Mathematical utilities optimized for trading applications *)

(** Fast mathematical operations with minimal allocations *)
module FastMath : sig
  val fast_inv_sqrt : float -> float

  val fast_log : float -> float

  val fast_exp : float -> float

  val fast_pow : float -> int -> float
end

(** Statistical functions optimized for financial data *)
module Statistics : sig
  type streaming_stats

  val create_streaming_stats : unit -> streaming_stats

  val update_streaming_stats : streaming_stats -> float -> unit

  val get_variance : streaming_stats -> float

  val get_std_dev : streaming_stats -> float

  type moving_average

  val create_moving_average : int -> moving_average

  val update_moving_average : moving_average -> float -> float

  type ema

  val create_ema : period:int -> ema

  val update_ema : ema -> float -> float

  type percentile_tracker

  val create_percentile_tracker : int -> percentile_tracker

  val update_percentile_tracker : percentile_tracker -> float -> unit

  val get_percentile : percentile_tracker -> float -> float
end

(** Financial mathematics functions *)
module FinancialMath : sig
  val black_scholes : call:bool -> s:float -> k:float -> t:float -> r:float -> sigma:float -> float

  val value_at_risk : float array -> float -> float

  val sharpe_ratio : float array -> float -> float

  val max_drawdown : float array -> float
end

(** High-performance linear algebra operations *)
module LinearAlgebra : sig
  val dot_product : float array -> float array -> float

  val vector_norm : float array -> float

  val normalize_vector : float array -> float array

  val matrix_2x2_det : float array array -> float

  val matrix_2x2_inv : float array array -> float array array

  val correlation : float array -> float array -> float
end

(** Random number generation optimized for financial simulations *)
module FastRandom : sig
  type xorshift_state

  val create_xorshift : int -> xorshift_state

  val uniform_float : xorshift_state -> float

  type normal_state

  val create_normal_rng : int -> normal_state

  val normal_sample : normal_state -> float

  val monte_carlo_estimate : samples:int -> f:(float -> float) -> rng:xorshift_state -> float
end
