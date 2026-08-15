(** Memory-mapped file systems for ultra-fast market data access *)

exception Mmap_error of string

exception Invalid_offset of int

exception Invalid_size of int

(** Memory-mapped file handle *)
type mmap_handle

(** Memory mapping mode *)
type mmap_mode =
  | Read_only
  | Read_write
  | Write_only

(** Memory mapping flags *)
type mmap_flags = {
  shared : bool; (* MAP_SHARED vs MAP_PRIVATE *)
  populate : bool; (* MAP_POPULATE - prefault pages *)
  locked : bool; (* mlock the mapping *)
  huge_pages : bool; (* Use huge pages if available *)
}

val default_flags : mmap_flags

(** Create a memory-mapped file *)
val create_mmap : ?flags:mmap_flags -> ?mode:mmap_mode -> string -> mmap_handle

(** Close a memory-mapped file *)
val close_mmap : mmap_handle -> unit

(** Sync memory-mapped region to disk *)
val sync_mmap : ?offset:int -> ?length:int option -> mmap_handle -> unit

(** Read functions for different data types *)
module Reader : sig
  val read_uint8 : mmap_handle -> int -> int

  val read_int16_le : mmap_handle -> int -> int

  val read_int16_be : mmap_handle -> int -> int

  val read_int32_le : mmap_handle -> int -> int32

  val read_int32_be : mmap_handle -> int -> int32

  val read_int64_le : mmap_handle -> int -> int64

  val read_int64_be : mmap_handle -> int -> int64

  val read_float32_le : mmap_handle -> int -> float

  val read_float32_be : mmap_handle -> int -> float

  val read_float64_le : mmap_handle -> int -> float

  val read_float64_be : mmap_handle -> int -> float

  val read_string : mmap_handle -> int -> int -> string
end

(** Write functions for different data types *)
module Writer : sig
  val write_uint8 : mmap_handle -> int -> int -> unit

  val write_int16_le : mmap_handle -> int -> int -> unit

  val write_int16_be : mmap_handle -> int -> int -> unit

  val write_int32_le : mmap_handle -> int -> int32 -> unit

  val write_int32_be : mmap_handle -> int -> int32 -> unit

  val write_int64_le : mmap_handle -> int -> int64 -> unit

  val write_int64_be : mmap_handle -> int -> int64 -> unit

  val write_float32_le : mmap_handle -> int -> float -> unit

  val write_float32_be : mmap_handle -> int -> float -> unit

  val write_float64_le : mmap_handle -> int -> float -> unit

  val write_float64_be : mmap_handle -> int -> float -> unit

  val write_string : mmap_handle -> int -> string -> unit
end

(** Market data specific structures *)
module MarketData : sig
  (** OHLCV candle structure *)
  type candle = {
    timestamp : int64;
    open_price : float;
    high_price : float;
    low_price : float;
    close_price : float;
    volume : float;
  }

  val candle_size : int

  val write_candle : mmap_handle -> int -> candle -> unit

  val read_candle : mmap_handle -> int -> candle

  (** Tick data structure *)
  type tick = {
    timestamp : int64;
    price : float;
    volume : float;
  }

  val tick_size : int

  val write_tick : mmap_handle -> int -> tick -> unit

  val read_tick : mmap_handle -> int -> tick

  (** Order book level *)
  type level = {
    price : float;
    quantity : float;
  }

  val level_size : int

  val write_level : mmap_handle -> int -> level -> unit

  val read_level : mmap_handle -> int -> level
end

(** Time series file format for market data *)
module TimeSeries : sig
  (** File header *)
  type header = {
    magic : int32;
    version : int32;
    record_size : int32;
    record_count : int64;
    start_time : int64;
    end_time : int64;
    symbol_length : int32;
    reserved : bytes;
  }

  val header_size : int

  val magic_number : int32

  val current_version : int32

  val write_header : mmap_handle -> header -> unit

  val read_header : mmap_handle -> header

  val get_record_offset : int -> int32 -> int

  val find_timestamp : mmap_handle -> header -> int64 -> int option

  val find_time_range : mmap_handle -> header -> int64 -> int64 -> int * int
end

(** Memory pool for efficient allocation of mapped regions *)
module MmapPool : sig
  type pool

  val create : max_size:int -> pool

  val acquire : pool -> string -> mmap_handle

  val release : pool -> mmap_handle -> unit

  val close_all : pool -> unit
end
