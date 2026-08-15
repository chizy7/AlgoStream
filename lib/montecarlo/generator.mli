(** How one Monte Carlo run gets its data.

    A generator is a {b pure function of a generator spec and an [Rng.t]} — that, plus
    [Rng.substream ~root_seed ~index], is what makes run [k] reproducible independently of how many
    Domains ran the batch. Nothing here reads a clock or consults shared mutable state. *)

module Rng = Algostream_rng.Rng
module Data_source = Algostream_backtest.Data_source
module Garch11 = Algostream_advanced_models.Garch11
module Ornstein_uhlenbeck = Algostream_advanced_models.Ornstein_uhlenbeck

type price_series = {
  symbol : string;
  s0 : float;
  start_ts_ns : int64;
  step_ns : int64;
  spread_bps : float;
  volume : float;
}

type t =
  | Historical of Data_source.record array
    (** the same data every run; only execution noise varies. The control against which every
        synthetic generator should be read *)
  | Iid_bootstrap of {
      returns : float array;
      series : price_series;
    }
  | Block_bootstrap of {
      returns : float array;
      block_len : int;
      series : price_series;
    }
  | Stationary_bootstrap of {
      returns : float array;
      mean_block_len : float;
      series : price_series;
    }
  | Record_bootstrap of {
      records : Data_source.record array;
      block_len : int;
    }
    (** resamples whole records, preserving whatever structure they carry, and rewrites timestamps
        onto a monotone grid *)
  | Gbm of {
      mu : float;
      sigma : float;
      dt : float;
      series : price_series;
    }
  | Garch_path of {
      model : Garch11.t;
      series : price_series;
    }
  | Ou_path of {
      params : Ornstein_uhlenbeck.params;
      dt : float;
      series : price_series;
    }
  | Jump_diffusion of {
      mu : float;
      sigma : float;
      lambda : float;
      jump_mu : float;
      jump_sigma : float;
      dt : float;
      series : price_series;
    }
  | Multivariate of {
      symbols : string array;
      s0 : float array;
      mu : float array;
      cov : float array array;
      dt : float;
      start_ts_ns : int64;
      step_ns : int64;
      spread_bps : float;
      volume : float;
    }
    (** {b Use this, not several independent single-asset generators, whenever the strategy trades a
          relationship.} Independent paths contain no relationship, so a pairs strategy backtested
        against them has nothing to trade and the Monte Carlo reports a strategy that cannot
        possibly work. *)
  | Regime_switching of {
      spec : Regime_sim.spec;
      series : price_series;
    }
  | Stressed of {
      base : t;
      scenario : Stress.scenario;
      at_fraction : float;
    }

val default_series : symbol:string -> s0:float -> price_series

(** Build one run's data. [n_steps] is ignored by {!Historical} and {!Record_bootstrap}, which are
    sized by their input. *)
val build : t -> rng:Rng.t -> n_steps:int -> Data_source.t

val to_string : t -> string
