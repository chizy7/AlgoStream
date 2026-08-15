(** Cointegration tests.

    [Engle_granger] is implemented end-to-end. [Johansen] is wired with the public signature but
    returns [`Not_supported_in_v1] until a linear-algebra dependency is added — Johansen needs an
    N×N generalized eigenvalue decomposition that we do not roll by hand. The honest stub is
    intentional: better than silently returning a partial result. *)

module Engle_granger : sig
  type result = {
    beta : float;
    intercept : float;
    residuals : float array;
    residual_adf : Adf.result;
    cointegrated : bool;
  }

  type error =
    [ Adf.error
    | `Length_mismatch
    | `Ols of Ols.error
    ]

  val test :
    y:float array ->
    x:float array ->
    ?signif:float ->
    ?adf_variant:Adf.variant ->
    ?adf_lag:int ->
    unit ->
    (result, error) Stdlib.result
end

module Johansen : sig
  type result = {
    trace_stats : float array;
    max_eig_stats : float array;
    rank : int;
  }

  (** Always returns [Error `Not_supported_in_v1] in this release. A future PR that adds a
      linear-algebra dependency (lacaml / owl) will fill this in. *)
  val test : _ -> (result, [ `Not_supported_in_v1 ]) Stdlib.result
end
