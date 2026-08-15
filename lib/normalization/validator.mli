(** Asset-aware tick validation, complementing the ingestion-side [Data_quality] verdicts.

    Run AFTER [Data_quality.check_market_tick] / [check_trade_print]. The verdicts here are
    informational: callers decide whether to drop or annotate. *)

type extra_verdict =
  | Tick_size_violation of {
      price : float;
      tick_size : float;
    }
  | Min_trade_size_violation of {
      size : float;
      min_size : float;
    }

(** [None] = pass. *)
val check_tick :
  Algostream_domain_market.Asset.asset -> price:float -> size:float -> extra_verdict option
