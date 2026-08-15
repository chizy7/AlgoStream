(** Portfolio-level circuit breaker with multiple trigger kinds.

    State machine mirrors the proven shape used by
    {!Algostream_data_ingestion.Connection_supervisor} for network failures:
    [Active → Tripped → Recovering]. Cooldown is in event time (not wall clock); strategies that
    need real-time gates run a separate wall-clock-driven scheduler externally.

    All time arithmetic uses caller-supplied [ts_ns]. *)

type trigger =
  | Drawdown_breach of {
      current : float;
      limit : float;
    }
  | Daily_loss_breach of {
      current : float;
      limit : float;
    }
  | Leverage_breach of {
      current : float;
      limit : float;
    }
  | Vol_spike of {
      current : float;
      baseline : float;
      ratio : float;
    }
  | Manual of string

type state =
  | Active
  | Tripped of {
      trigger : trigger;
      tripped_at_ns : int64;
    }
  | Recovering of { since_ns : int64 }

type config = {
  max_drawdown : float;
  max_daily_loss : float;
  max_leverage : float;
  vol_spike_ratio : float;
  cooldown_ns : int64;
}

type t

val create : config:config -> t

val state : t -> state

val is_tripped : t -> bool

val evaluate :
  t ->
  drawdown:float ->
  daily_pnl:float ->
  leverage:float ->
  realized_vol:float ->
  baseline_vol:float ->
  ts_ns:int64 ->
  state

val trip_manual : t -> reason:string -> ts_ns:int64 -> unit

val reset : t -> ts_ns:int64 -> unit

val trigger_to_string : trigger -> string

val state_to_string : state -> string
