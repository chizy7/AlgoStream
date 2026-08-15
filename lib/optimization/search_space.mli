(** Parameter search spaces.

    A point is a [(string * float) list] — the flat representation [Strategy.S.params_of_assoc]
    consumes. Keeping it flat is what lets the optimizer traverse any strategy's parameters without
    knowing the concrete [params] type, and without existentials or GADTs. An integer dimension is a
    float that the strategy's own [params_of_assoc] rejects if non-integral. *)

module Rng = Algostream_rng.Rng

type spec =
  | Grid of float array  (** an explicit set of values *)
  | Uniform of {
      lo : float;
      hi : float;
    }
  | Log_uniform of {
      lo : float;
      hi : float;
    }
    (** for scale parameters — window lengths, notionals — where the interesting variation is
        multiplicative. [lo] must be positive. *)
  | Int_range of {
      lo : int;
      hi : int;
      step : int;
    }

type dim = {
  name : string;
  spec : spec;
}

type t = dim list

(** Build a default space from a strategy's declared [param_bounds], discretizing each continuous
    dimension into [points_per_dim] grid values. *)
val of_bounds : (string * float * float) list -> ?points_per_dim:int -> unit -> t

(** Number of grid points, or [None] if any dimension is continuous. *)
val cardinality : t -> int option

(** Full Cartesian product. Returns [`Too_large n] rather than allocating when the product exceeds
    [max_points] — a silent truncation would report a "best" that never searched most of the space.
*)
val grid_points :
  t -> max_points:int -> ((string * float) list array, [ `Too_large of int ]) Stdlib.result

(** One uniformly random point. *)
val sample : t -> Rng.t -> (string * float) list

(** [n] random points. *)
val random_points : t -> Rng.t -> n:int -> (string * float) list array

(** [n] Latin-hypercube points: each dimension is cut into [n] equal strata and every stratum
    receives exactly one sample.

    What this buys, precisely: {b exact marginal coverage} — no axis is left with a large unsampled
    gap, which independent draws routinely produce. What it does {i not} buy is guaranteed joint
    coverage, so on a space whose optimum sits at one specific combination it is not reliably better
    than random search at finding that cell. The advantage shows on smooth objectives and grows with
    dimension, where random draws leave increasingly ragged marginals.

    Chosen over a Sobol sequence, which would give better joint coverage, because Sobol needs
    per-dimension direction-number tables: a single mis-transcribed row degrades the sequence
    silently while it still looks valid. This is correct by construction and checkable — see
    [test_stratified_covers_every_stratum]. Applies at any dimension; there is no table to run out
    of. *)
val stratified_points : t -> Rng.t -> n:int -> (string * float) list array

(** Always [true]; retained so callers can branch uniformly. *)
val stratified_supported : t -> bool

(** Immediate grid neighbours of a point, for coordinate descent. *)
val neighbours : t -> (string * float) list -> (string * float) list array

(** Clamp a point into the space, for optimizers that can step outside it. *)
val clamp : t -> (string * float) list -> (string * float) list

val to_string : t -> string
