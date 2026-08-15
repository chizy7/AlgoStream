(** Fixed-window rolling statistics with periodic full recompute.

    The naive sliding-Welford trick (subtract the outgoing point's contribution from M2) suffers
    catastrophic cancellation on long-running streams. Each module here keeps the most recent
    [window] samples in a circular buffer and runs an O(window) full recompute every
    [recompute_every] ticks. Between recomputes, an incremental update is applied for cheap reads,
    but the contract is: the value returned at recompute boundaries is exact; intermediate values
    are bounded-error approximations. *)

(* ───── Rolling mean (circular buffer, exact each tick) ───────────── *)

module Rolling_mean : sig
  type t

  val create : window:int -> t

  val update : t -> float -> float

  val value : t -> float

  val n : t -> int
end

(* ───── Rolling variance ──────────────────────────────────────────── *)

module Rolling_var : sig
  type t

  val create : window:int -> recompute_every:int -> t

  val update : t -> float -> float

  val value : t -> float

  val std_dev : t -> float

  val n : t -> int
end

(* ───── Rolling covariance (paired stream) ────────────────────────── *)

module Rolling_cov : sig
  type t

  val create : window:int -> recompute_every:int -> t

  val update : t -> float -> float -> float

  val value : t -> float

  val n : t -> int
end

(* ───── Rolling Pearson correlation ───────────────────────────────── *)

module Rolling_corr : sig
  type t

  val create : window:int -> recompute_every:int -> t

  val update : t -> float -> float -> float

  val value : t -> float

  val n : t -> int
end
