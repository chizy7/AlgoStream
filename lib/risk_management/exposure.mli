(** Aggregate portfolio exposures: gross / net / leverage / per-symbol / per-asset-class.

    Composes existing helpers from {!Algostream_domain_portfolio.Portfolio} (gross_exposure,
    net_exposure, net_asset_value, leverage, position_count) and adds the per-symbol /
    per-asset-class breakdowns that aren't surfaced today. *)

module Portfolio = Algostream_domain_portfolio.Portfolio

type per_symbol_entry = {
  symbol : string;
  market_value : float;  (** signed: long positive, short negative *)
  pct_of_nav : float;  (** signed fraction of NAV *)
}

type t = {
  nav : float;
  gross_exposure : float;
  net_exposure : float;
  leverage_ratio : float;
  largest_position_pct : float;
  n_positions : int;
  per_symbol : per_symbol_entry list;  (** sorted desc by [|pct_of_nav|] *)
  per_asset_class : (string * float) list;  (** asset_class -> gross exposure; sorted desc *)
}

val compute : portfolio:Portfolio.portfolio -> ?asset_class_lookup:(string -> string) -> unit -> t
