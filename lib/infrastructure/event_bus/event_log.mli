(** Append-only binary event log with bin_prot framing.

    File layout:
    {v
    +----------------------------------------------------------+
    | Header (64 bytes)                                        |
    |   magic        : int32 LE  (0x41534454, "ASDT")          |
    |   version      : int32 LE  (3 — writer; reader takes 2)  |
    |   record_size  : int32 LE  (0 — variable)                |
    |   record_count : int64 LE  (updated on close, may be 0)  |
    |   start_time   : int64 LE  (first event timestamp_ns)    |
    |   end_time     : int64 LE  (last event timestamp_ns)     |
    |   reserved     : 28 bytes                                |
    +----------------------------------------------------------+
    | Frame: u32 length | u32 crc32 | bin_prot(Event.t) bytes  |
    | ... repeated ...                                         |
    +----------------------------------------------------------+
    v}

    Plain stdlib file I/O is used; mmap support in [Memory_mapped] is a no-op stub in portable mode.
    CRC32 (IEEE 802.3 polynomial) protects each frame; on read, the first bad CRC truncates the
    iteration. *)

val magic : int32

val version : int32

val header_size : int

(** Append-only writer. Not thread-safe — use one writer per file. *)
module Writer : sig
  type t

  (** [create path] opens [path] for writing, creating it if absent or truncating it if present.
      Writes the 64-byte header. *)
  val create : string -> t

  (** Append one event. Computes bin_prot size, writes [length], [crc32], then the bin_prot bytes.
      Updates running record_count, start_time, end_time. *)
  val append : t -> Event_types.Event.t -> unit

  (** Flush OS buffers and rewrite the header with final counts/timestamps. *)
  val close : t -> unit

  val record_count : t -> int64
end

(** Read-only iterator over a log file. *)
module Reader : sig
  type t

  exception Bad_magic of int32

  exception Bad_version of int32

  val open_ : string -> t

  val close : t -> unit

  val record_count : t -> int64

  (** [iter t f] calls [f] on every event in order. Stops cleanly on EOF or the first bad CRC
      (without raising). Returns the number of events successfully delivered. *)
  val iter : t -> (Event_types.Event.t -> unit) -> int
end

(** Stream events from [path] into [bus]. [speed] scales replay relative to real time (1.0 =
    real-time, 10.0 = 10x faster, [Float.infinity] = as fast as possible). [filter] is applied
    before publishing.

    Returns the number of events published. *)
val replay :
  Event_bus.t -> path:string -> ?speed:float -> ?filter:Subscription.Filter.t -> unit -> int
