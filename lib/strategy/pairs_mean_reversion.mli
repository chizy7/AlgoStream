(** Reference {!Strategy.S}: market-neutral pairs mean reversion.

    This is the first code in the project that acts on a [Pairs.Snapshot.signal]. It {b consumes}
    the signal the pairs classifier already produces rather than reimplementing the classification —
    [Pairs.Mean_reversion] owns the hysteretic entry/exit/stop band logic, and duplicating it here
    would give two state machines that drift apart.

    On [Long_spread] the strategy buys the y leg and sells [beta_hedge · β] of the x leg; on
    [Short_spread], the mirror. [Exit] flattens both legs. Position size targets a fixed gross
    notional, capped as a fraction of NAV.

    {b Screens.} A signal is ignored unless the snapshot is [ready], is [cointegrated], has an ADF
    p-value at or below [max_adf_pvalue], an absolute rolling correlation at or above
    [min_abs_corr], and a half-life inside [[min_half_life_bars, max_half_life_bars]]. A pair that
    fails a screen while a position is open is flattened rather than held — the relationship the
    trade was predicated on has stopped being demonstrable.

    {b Idempotence.} The classifier repeats [Long_spread] for as long as the z-score sits past the
    band, which is many ticks. The strategy records the signal it last acted on per pair and returns
    no actions until the signal changes, so one crossing produces one entry. *)

type params = {
  target_gross_notional : float;  (** per pair, in quote currency *)
  max_gross_pct_of_nav : float;  (** hard cap on per-pair gross exposure *)
  beta_hedge : float;  (** [1.0] = beta-neutral, [0.0] = dollar-neutral *)
  min_half_life_bars : float;
  max_half_life_bars : float;
  max_adf_pvalue : float;
  min_abs_corr : float;
  use_limit_orders : float;  (** [< 0.5] market, otherwise limit at the near touch, passive *)
}

(** Everything else — [default_params], [params_of_assoc], [param_bounds], [create], [on_event],
    [on_stop], [diagnostics] — comes from {!Strategy.S}. [params] is exposed concretely so callers
    can build one directly instead of going through the assoc list. *)
include Strategy.S with type params := params
