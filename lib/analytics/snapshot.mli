(** Immutable per-symbol snapshot.

    Cross-Domain reads: a [Per_symbol.t] writes its current state into a [Snapshot.t Atomic.t] via
    [Atomic.set]. Readers in other Domains call [Atomic.get] and receive the whole immutable record
    — no torn reads, no per-field atomicity dance. The release-acquire ordering on
    [Atomic.set]/[Atomic.get] is sufficient because the published value is itself immutable. *)

type t = {
  symbol : string;
  last_event_ts_ns : int64;
  n_ticks : int;
  last_price : float;
  denoised_price : float;
  realized_vol : float;
  ewma_vol : float;
  rolling_mean_price : float;
  rolling_std_price : float;
  drawdown_from_peak : float;
  regime : Regime.t;
  regime_dwell_ns : int64;
  rejected_count : int;
  ready : bool;
}

val empty : symbol:string -> t

val to_string : t -> string
