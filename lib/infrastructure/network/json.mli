(** Outbound JSON encoding.

    Yojson was already a dependency, but only ever for {i inbound} parsing — exchange frames and
    config files. There is not one [to_yojson] in the rest of the tree, and there is deliberately
    none added: [lib/performance] and [lib/risk_management] are pure and dependency-light, and
    teaching them to serialize would be new dependency surface on the two libraries least suited to
    it. Encoding lives here instead, reading the [to_assoc] accessors those layers already expose —
    the precedent [Performance.Metrics.to_assoc] set.

    {1 Non-finite floats}

    [Yojson] happily emits [NaN] and [Infinity], which are not JSON and which every browser's
    [JSON.parse] rejects. Financial metrics produce both routinely — a Sharpe ratio over zero
    variance, a leverage ratio on an empty portfolio. {!float} maps them to [null] so a single
    degenerate metric cannot make an entire response unparseable. *)

type t = Yojson.Safe.t

(** Finite floats encode as numbers; NaN and infinities encode as [null]. *)
val float : float -> t

val int : int -> t

val int64 : int64 -> t

val string : string -> t

val bool : bool -> t

(** [(string * float) list] to an object, guarding each value. *)
val of_assoc : (string * float) list -> t

val list : ('a -> t) -> 'a list -> t

val array : ('a -> t) -> 'a array -> t

val opt : ('a -> t) -> 'a option -> t

val obj : (string * t) list -> t

val to_string : t -> string

(** {1 Domain encoders} *)

val of_histogram_summary : Algostream_telemetry.Histogram.summary -> t

val of_health_status : Algostream_telemetry.Health.status -> t

val of_alert : Algostream_telemetry.Alert.t -> t

val of_telemetry : Algostream_telemetry.Snapshot.t -> t

val of_runtime_instance : Algostream_runtime.Snapshot.instance -> t

val of_runtime : Algostream_runtime.Snapshot.t -> t

(** [(ts_ns, value)] series, as [[[ts, v], ...]] — the shape the charting code consumes. *)
val of_series : (int64 * float) array -> t

val error : string -> t
