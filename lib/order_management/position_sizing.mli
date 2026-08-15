(** Position sizing algorithms.

    All pure functions; callers feed in pre-computed mean / variance / vol from upstream layers
    (e.g., [Pairs] / [Advanced_models] / [Analytics]). *)

module Kelly : sig
  (** Continuous-return Kelly fraction: [f* = mean / variance].

      Assumes log-normal returns; for normal returns the approximation is reasonable when [|mean|]
      is small compared to the standard deviation. Returns 0 if [variance <= 0]. *)
  val full : mean:float -> variance:float -> float

  (** Fractional Kelly: [fraction] times {!full}. Recommended default [fraction = 0.25] — reduces
      variance ~93% while sacrificing only ~25% of geometric growth. *)
  val fractional : mean:float -> variance:float -> fraction:float -> float

  (** Discrete-bet Kelly: [f* = p − q/b] where [p = win_prob], [q = 1 − p], [b = win_loss_ratio].
      Returns 0 if [win_loss_ratio <= 0]. *)
  val from_winrate : win_prob:float -> win_loss_ratio:float -> float

  (** Convert a Kelly fraction to a share count. [cap_pct] hard-caps the position at this fraction
      of [capital] (default 1.0). Negative or NaN fractions are floored to 0. *)
  val size_position :
    capital:float -> kelly_fraction:float -> price:float -> ?cap_pct:float -> unit -> float
end

module Volatility_scaling : sig
  (** Size targeting a per-period dollar volatility of [target_vol]. [asset_vol] is the per-period
      return standard deviation as a decimal. Cap at [capital / price] (100% gross exposure).
      Returns 0 if [asset_vol <= 0] or [price <= 0]. *)
  val size : capital:float -> target_vol:float -> asset_vol:float -> price:float -> float

  (** ATR-based size: risk [risk_pct] of capital, stop loss placed [atr] units away. Shares =
      [(capital * risk_pct) / atr]; capped at [capital / price]. *)
  val atr_size : capital:float -> risk_pct:float -> atr:float -> price:float -> float
end
