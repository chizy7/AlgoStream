type subscription =
  | Symbol of string
  | Bars of {
      symbol : string;
      interval_ns : int64;
    }
  | Pair of {
      pair : Algostream_pairs.Pair_id.t;
      y_symbol : string;
      x_symbol : string;
    }
  | Timer_every of {
      interval_ns : int64;
      tag : string;
    }

module type S = sig
  val name : string

  val version : string

  type params

  val default_params : params

  val params_of_assoc : (string * float) list -> (params, string) Stdlib.result

  val params_to_assoc : params -> (string * float) list

  val param_bounds : (string * float * float) list

  type state

  val create : params:params -> symbols:string list -> state

  val subscriptions : state -> subscription list

  val on_event : state -> Context.t -> Event.t -> Action.t list

  val on_stop : state -> Context.t -> Action.t list

  val diagnostics : state -> (string * float) list
end

type packed = (module S)

let require assoc key =
  match List.assoc_opt key assoc with
  | Some v when Float.is_finite v -> Ok v
  | Some v -> Error (Printf.sprintf "parameter %s is not finite (%g)" key v)
  | None -> Error (Printf.sprintf "missing parameter %s" key)


let require_in assoc key ~lo ~hi =
  match require assoc key with
  | Error e -> Error e
  | Ok v ->
    if v < lo || v > hi then
      Error (Printf.sprintf "parameter %s = %g is outside [%g, %g]" key v lo hi)
    else Ok v


let require_int assoc key =
  match require assoc key with
  | Error e -> Error e
  | Ok v ->
    let r = Float.round v in
      if Float.abs (v -. r) > 1e-9 then
        Error (Printf.sprintf "parameter %s = %g must be an integer" key v)
      else Ok (int_of_float r)
