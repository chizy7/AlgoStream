(** Equity curve → return series, and the annualization factor everything else depends on.

    This module is the single source of truth for annualization in the codebase. Neither existing
    Sharpe implementation annualizes at all — [Portfolio.Risk_metrics] divides a per-period mean by
    a per-period standard deviation, and [Portfolio_analytics] divides a {i total} return by a
    per-period standard deviation. Both report the result in a field called [sharpe_ratio]. Any
    number produced here goes through {!periods_per_year} so the convention is explicit and
    consistent.

    A NAV curve is [(ts_ns, equity)] pairs in ascending time order. Nothing here reads a clock. *)

type kind =
  | Simple  (** [r_t = V_t / V_{t-1} - 1] *)
  | Log  (** [r_t = ln(V_t / V_{t-1})] — additive across periods, so preferred for aggregation *)

(** Return series of length [n - 1] from an [n]-point NAV curve. Non-positive or non-finite equity
    values terminate the series rather than producing [nan] or [-inf]: a backtest that blows through
    zero equity has no meaningful return afterwards, and propagating [nan] would silently poison
    every downstream metric. *)
val of_nav : nav:(int64 * float) array -> kind:kind -> float array

(** Median inter-sample gap of the NAV curve, in nanoseconds. Median rather than mean so a single
    long gap (an exchange outage, a weekend) does not distort the inferred sampling cadence. Returns
    [0L] for fewer than two points. *)
val infer_interval_ns : nav:(int64 * float) array -> int64

(** Periods per year for a given sampling interval.

    Defaults to a 24/7 calendar (365 days), which is correct for crypto — the asset class this
    platform actually ingests. For instruments that trade on a session calendar, pass
    [~days_per_year:252] and, for intraday bars, [~hours_per_day:6.5]; the two compose. Returns
    [0.0] for a non-positive interval. *)
val periods_per_year :
  ?days_per_year:float -> ?hours_per_day:float -> interval_ns:int64 -> unit -> float

(** Convert an annual rate to the equivalent per-period rate by geometric compounding:
    [(1 + annual)^(1/ppy) - 1]. Used to turn a risk-free rate into a per-period subtrahend. *)
val per_period_rate : annual_rate:float -> periods_per_year:float -> float

(** [excess ~returns ~risk_free_rate_ann ~periods_per_year] subtracts the per-period equivalent of
    the annual risk-free rate from every observation. *)
val excess :
  returns:float array -> risk_free_rate_ann:float -> periods_per_year:float -> float array

(** Cumulative growth: [Π(1 + r) - 1] for simple returns, [exp(Σ r) - 1] for log returns. *)
val total_return : returns:float array -> kind:kind -> float

(** Sample mean. *)
val mean : float array -> float

(** Sample standard deviation, [n-1] denominator. Returns [0.0] for fewer than two observations. *)
val stddev : float array -> float

(** Downside deviation below [mar] (minimum acceptable return, per period).

    Uses the {b full-sample} [n] denominator — observations at or above [mar] contribute zero rather
    than being excluded. This is the standard Sortino convention and is the single largest source of
    disagreement between implementations, so it is stated here rather than left to be discovered. *)
val downside_deviation : returns:float array -> mar:float -> float
