(** Lossless float column compression (Gorilla-style XOR-delta-of-bits) and integer column
    compression (delta + varint).

    Float strategy: encode each value as [Int64.bits_of_float], XOR with the previous value, write
    the leading-zero count + meaningful-bits block. Round-trips exactly for ALL Float64 values —
    NaN, Infinity, denormals, signed zero — because the encoder never interprets the value as a
    number.

    Int64 strategy (timestamps): write the delta against the previous value as a zigzag-varint.
    Monotonically-increasing timestamps with sub-millisecond gaps compress to ~1-2 bytes per value.
*)

(** Encode a Float64 Bigarray. Returns a [Bytes.t] you can persist or ship over the wire. *)
val encode_float : (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t -> bytes

val decode_float : bytes -> (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t

val encode_int64 : (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t -> bytes

val decode_int64 : bytes -> (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
