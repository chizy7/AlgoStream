(** Put two independently-sampled NAV curves on one time grid.

    {!Benchmark_compare.compare} and {!Metrics.of_returns} both require their two series to be
    sampled on the same grid, and simply truncate to the shorter length. That assumption holds for a
    backtest, where one engine emits both curves on one clock. It does not hold for two {i live}
    strategy instances: each samples on its own timer against its own event stream, so they start at
    different moments, drift apart, and one may be paused while the other keeps sampling. Feeding
    such curves to [compare] positionally silently pairs unrelated points and reports a correlation
    that means nothing.

    {2 What this does}

    Restricts to the window both curves cover, takes the sorted union of their timestamps inside it,
    and carries the last observation forward for each series onto that grid.

    Last-observation-carried-forward, not interpolation: a NAV between two samples is the earlier
    one, because that is what the portfolio was actually worth. Interpolating would invent equity
    the strategy never had, and would leak information backwards from a sample that had not happened
    yet.

    The union rather than the intersection: an exact timestamp match between two independently
    sampled curves is a coincidence, so intersecting them usually yields almost nothing. The union
    keeps every observation from both. *)

type aligned = {
  ts_ns : int64 array;
  a : float array;
  b : float array;
  n : int;  (** grid length; [0] when the curves do not overlap *)
  overlap_ns : int64;  (** duration of the common window, [0L] when there is none *)
}

(** Align two [(ts_ns, nav)] curves. Inputs need not be sorted and may contain duplicate timestamps
    — the last value wins for a repeated timestamp, matching the ring's own semantics. Returns an
    empty grid when either curve is empty or the two do not overlap in time. *)
val align : (int64 * float) array -> (int64 * float) array -> aligned

(** Simple period returns of an aligned series: [n - 1] values, or [[||]] when [n < 2]. A period
    whose starting value is not positive yields [0.0] rather than an infinity, so one bad point
    cannot poison every downstream statistic. *)
val returns : float array -> float array

(** Median spacing of the grid, in nanoseconds, or [None] when there are fewer than two points.
    Median rather than mean because a single long gap — a paused instance, a quiet feed — would drag
    a mean far off the cadence that actually produced the samples. *)
val median_interval_ns : int64 array -> int64 option

(** Periods per year implied by [median_interval_ns], for annualizing. [None] when the grid is too
    short or the spacing is not positive. *)
val periods_per_year : int64 array -> float option
