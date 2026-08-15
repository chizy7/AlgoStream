(** Memory-mapped file systems for ultra-fast market data access *)

open Base

exception Mmap_error of string

exception Invalid_offset of int

exception Invalid_size of int

(** Memory-mapped file handle *)
type mmap_handle = {
  fd : Unix.file_descr;
  size : int;
  ptr : nativeint;
  mutable is_closed : bool;
}

module MmapHandle = struct
  type t = mmap_handle

  let compare h1 h2 = Nativeint.compare h1.ptr h2.ptr

  let hash h = Nativeint.hash h.ptr

  let sexp_of_t _h = Sexp.Atom "mmap_handle"
end

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

let default_flags = { shared = true; populate = true; locked = true; huge_pages = false }

(** Simplified stub implementations *)
let mmap_file _fd _size _mode _flags = failwith "Memory mapping not available in stub mode"

let munmap_file _ptr _size = ()

let msync_range _ptr _offset _length = ()

let madvise_sequential _ptr _size = ()

let _madvise_random _ptr _size = ()

let madvise_willneed _ptr _size = ()

let mlock_range _ptr _size = ()

let munlock_range _ptr _size = ()

(** Convert mmap_mode to integer flags *)
let mode_to_int = function Read_only -> 0 | Read_write -> 1 | Write_only -> 2

(** Convert mmap_flags to integer *)
let flags_to_int flags =
  let shared_flag = if flags.shared then 1 else 0 in
  let populate_flag = if flags.populate then 2 else 0 in
  let locked_flag = if flags.locked then 4 else 0 in
  let huge_pages_flag = if flags.huge_pages then 8 else 0 in
    shared_flag lor populate_flag lor locked_flag lor huge_pages_flag


(** Create a memory-mapped file *)
let create_mmap ?(flags = default_flags) ?(mode = Read_only) file_path =
  try
    let fd = Unix.openfile file_path [ Unix.O_RDONLY ] 0o644 in
    let stats = Unix.fstat fd in
    let size = stats.st_size in

    if size <= 0 then (
      Unix.close fd ;
      raise (Invalid_size size)) ;

    let mode_int = mode_to_int mode in
    let flags_int = flags_to_int flags in
    let ptr = mmap_file fd size mode_int flags_int in

    (* Advise kernel about access patterns *)
    madvise_sequential ptr size ;

    (* Prefault pages if requested *)
    if flags.populate then madvise_willneed ptr size ;

    (* Lock pages in memory if requested *)
    if flags.locked then mlock_range ptr size ;

    { fd; size; ptr; is_closed = false }
  with
  | Unix.Unix_error (err, func, arg) ->
    raise (Mmap_error (Printf.sprintf "%s: %s(%s)" (Unix.error_message err) func arg))
  | e -> raise e


(** Close a memory-mapped file *)
let close_mmap handle =
  if not handle.is_closed then
    try
      (* Unlock pages if they were locked *)
      (try munlock_range handle.ptr handle.size with _ -> ()) ;

      (* Unmap the memory *)
      munmap_file handle.ptr handle.size ;

      (* Close the file descriptor *)
      Unix.close handle.fd ;

      handle.is_closed <- true
    with Unix.Unix_error (err, func, arg) ->
      raise (Mmap_error (Printf.sprintf "%s: %s(%s)" (Unix.error_message err) func arg))


(** Sync memory-mapped region to disk *)
let sync_mmap ?(offset = 0) ?(length = None) handle =
  if handle.is_closed then raise (Mmap_error "Cannot sync closed mapping") ;

  let sync_length = match length with None -> handle.size - offset | Some len -> len in

  if offset < 0 || offset >= handle.size then raise (Invalid_offset offset) ;

  if sync_length <= 0 || offset + sync_length > handle.size then raise (Invalid_size sync_length) ;

  try msync_range handle.ptr offset sync_length
  with Unix.Unix_error (err, func, arg) ->
    raise (Mmap_error (Printf.sprintf "%s: %s(%s)" (Unix.error_message err) func arg))


(** Read functions for different data types *)
module Reader = struct
  (* Stub implementations *)
  let read_int8 _ptr _offset = 0

  let read_int16_le _ptr _offset = 0

  let read_int16_be _ptr _offset = 0

  let read_int32_le _ptr _offset = 0l

  let read_int32_be _ptr _offset = 0l

  let read_int64_le _ptr _offset = 0L

  let read_int64_be _ptr _offset = 0L

  let read_float32_le _ptr _offset = 0.0

  let read_float32_be _ptr _offset = 0.0

  let read_float64_le _ptr _offset = 0.0

  let read_float64_be _ptr _offset = 0.0

  let check_bounds handle offset size =
    if handle.is_closed then raise (Mmap_error "Cannot read from closed mapping") ;
    if offset < 0 || offset + size > handle.size then raise (Invalid_offset offset)


  let read_uint8 handle offset =
    check_bounds handle offset 1 ;
    read_int8 handle.ptr offset


  let read_int16_le handle offset =
    check_bounds handle offset 2 ;
    read_int16_le handle.ptr offset


  let read_int16_be handle offset =
    check_bounds handle offset 2 ;
    read_int16_be handle.ptr offset


  let read_int32_le handle offset =
    check_bounds handle offset 4 ;
    read_int32_le handle.ptr offset


  let read_int32_be handle offset =
    check_bounds handle offset 4 ;
    read_int32_be handle.ptr offset


  let read_int64_le handle offset =
    check_bounds handle offset 8 ;
    read_int64_le handle.ptr offset


  let read_int64_be handle offset =
    check_bounds handle offset 8 ;
    read_int64_be handle.ptr offset


  let read_float32_le handle offset =
    check_bounds handle offset 4 ;
    read_float32_le handle.ptr offset


  let read_float32_be handle offset =
    check_bounds handle offset 4 ;
    read_float32_be handle.ptr offset


  let read_float64_le handle offset =
    check_bounds handle offset 8 ;
    read_float64_le handle.ptr offset


  let read_float64_be handle offset =
    check_bounds handle offset 8 ;
    read_float64_be handle.ptr offset


  let read_string handle offset length =
    check_bounds handle offset length ;
    let bytes = Bytes.create length in
      for i = 0 to length - 1 do
        Bytes.set bytes i (Char.of_int_exn (read_int8 handle.ptr (offset + i)))
      done ;
      Bytes.to_string bytes
end

(** Write functions for different data types *)
module Writer = struct
  external write_int8 : nativeint -> int -> int -> unit = "algostream_write_int8"

  external write_int16_le : nativeint -> int -> int -> unit = "algostream_write_int16_le"

  external write_int16_be : nativeint -> int -> int -> unit = "algostream_write_int16_be"

  external write_int32_le : nativeint -> int -> int32 -> unit = "algostream_write_int32_le"

  external write_int32_be : nativeint -> int -> int32 -> unit = "algostream_write_int32_be"

  external write_int64_le : nativeint -> int -> int64 -> unit = "algostream_write_int64_le"

  external write_int64_be : nativeint -> int -> int64 -> unit = "algostream_write_int64_be"

  external write_float32_le : nativeint -> int -> float -> unit = "algostream_write_float32_le"

  external write_float32_be : nativeint -> int -> float -> unit = "algostream_write_float32_be"

  external write_float64_le : nativeint -> int -> float -> unit = "algostream_write_float64_le"

  external write_float64_be : nativeint -> int -> float -> unit = "algostream_write_float64_be"

  let check_bounds handle offset size =
    if handle.is_closed then raise (Mmap_error "Cannot write to closed mapping") ;
    if offset < 0 || offset + size > handle.size then raise (Invalid_offset offset)


  let write_uint8 handle offset value =
    check_bounds handle offset 1 ;
    write_int8 handle.ptr offset value


  let write_int16_le handle offset value =
    check_bounds handle offset 2 ;
    write_int16_le handle.ptr offset value


  let write_int16_be handle offset value =
    check_bounds handle offset 2 ;
    write_int16_be handle.ptr offset value


  let write_int32_le handle offset value =
    check_bounds handle offset 4 ;
    write_int32_le handle.ptr offset value


  let write_int32_be handle offset value =
    check_bounds handle offset 4 ;
    write_int32_be handle.ptr offset value


  let write_int64_le handle offset value =
    check_bounds handle offset 8 ;
    write_int64_le handle.ptr offset value


  let write_int64_be handle offset value =
    check_bounds handle offset 8 ;
    write_int64_be handle.ptr offset value


  let write_float32_le handle offset value =
    check_bounds handle offset 4 ;
    write_float32_le handle.ptr offset value


  let write_float32_be handle offset value =
    check_bounds handle offset 4 ;
    write_float32_be handle.ptr offset value


  let write_float64_le handle offset value =
    check_bounds handle offset 8 ;
    write_float64_le handle.ptr offset value


  let write_float64_be handle offset value =
    check_bounds handle offset 8 ;
    write_float64_be handle.ptr offset value


  let write_string handle offset str =
    let length = String.length str in
      check_bounds handle offset length ;
      for i = 0 to length - 1 do
        write_int8 handle.ptr (offset + i) (Char.to_int str.[i])
      done
end

(** Market data specific structures *)
module MarketData = struct
  (** OHLCV candle structure (32 bytes) *)
  type candle = {
    timestamp : int64; (* 8 bytes *)
    open_price : float; (* 8 bytes *)
    high_price : float; (* 8 bytes *)
    low_price : float; (* 8 bytes *)
    close_price : float; (* 8 bytes *)
    volume : float; (* 8 bytes *)
  }

  let candle_size = 48

  let write_candle handle offset candle =
    Writer.write_int64_le handle offset candle.timestamp ;
    Writer.write_float64_le handle (offset + 8) candle.open_price ;
    Writer.write_float64_le handle (offset + 16) candle.high_price ;
    Writer.write_float64_le handle (offset + 24) candle.low_price ;
    Writer.write_float64_le handle (offset + 32) candle.close_price ;
    Writer.write_float64_le handle (offset + 40) candle.volume


  let read_candle handle offset =
    {
      timestamp = Reader.read_int64_le handle offset;
      open_price = Reader.read_float64_le handle (offset + 8);
      high_price = Reader.read_float64_le handle (offset + 16);
      low_price = Reader.read_float64_le handle (offset + 24);
      close_price = Reader.read_float64_le handle (offset + 32);
      volume = Reader.read_float64_le handle (offset + 40);
    }


  (** Tick data structure (24 bytes) *)
  type tick = {
    timestamp : int64; (* 8 bytes *)
    price : float; (* 8 bytes *)
    volume : float; (* 8 bytes *)
  }

  let tick_size = 24

  let write_tick handle offset tick =
    Writer.write_int64_le handle offset tick.timestamp ;
    Writer.write_float64_le handle (offset + 8) tick.price ;
    Writer.write_float64_le handle (offset + 16) tick.volume


  let read_tick handle offset =
    {
      timestamp = Reader.read_int64_le handle offset;
      price = Reader.read_float64_le handle (offset + 8);
      volume = Reader.read_float64_le handle (offset + 16);
    }


  (** Order book level (16 bytes) *)
  type level = {
    price : float; (* 8 bytes *)
    quantity : float; (* 8 bytes *)
  }

  let level_size = 16

  let write_level handle offset level =
    Writer.write_float64_le handle offset level.price ;
    Writer.write_float64_le handle (offset + 8) level.quantity


  let read_level handle offset =
    {
      price = Reader.read_float64_le handle offset;
      quantity = Reader.read_float64_le handle (offset + 8);
    }
end

(** Time series file format for market data *)
module TimeSeries = struct
  (** File header (64 bytes) *)
  type header = {
    magic : int32; (* 4 bytes - file format identifier *)
    version : int32; (* 4 bytes - format version *)
    record_size : int32; (* 4 bytes - size of each record *)
    record_count : int64; (* 8 bytes - number of records *)
    start_time : int64; (* 8 bytes - timestamp of first record *)
    end_time : int64; (* 8 bytes - timestamp of last record *)
    symbol_length : int32; (* 4 bytes - length of symbol string *)
    reserved : bytes; (* 20 bytes - reserved for future use *)
  }

  let header_size = 64

  let magic_number = 0x41534454l (* "ASDT" - AlgoStream Data File *)

  let current_version = 1l

  let write_header handle header =
    Writer.write_int32_le handle 0 header.magic ;
    Writer.write_int32_le handle 4 header.version ;
    Writer.write_int32_le handle 8 header.record_size ;
    Writer.write_int64_le handle 12 header.record_count ;
    Writer.write_int64_le handle 20 header.start_time ;
    Writer.write_int64_le handle 28 header.end_time ;
    Writer.write_int32_le handle 36 header.symbol_length ;
    (* Write symbol and padding *)
    let symbol = Bytes.to_string header.reserved in
      Writer.write_string handle 40 (String.prefix symbol (Int.min (String.length symbol) 24))


  let read_header handle =
    let magic = Reader.read_int32_le handle 0 in
      if not (Int32.equal magic magic_number) then
        raise (Mmap_error "Invalid file format magic number") ;

      {
        magic;
        version = Reader.read_int32_le handle 4;
        record_size = Reader.read_int32_le handle 8;
        record_count = Reader.read_int64_le handle 12;
        start_time = Reader.read_int64_le handle 20;
        end_time = Reader.read_int64_le handle 28;
        symbol_length = Reader.read_int32_le handle 36;
        reserved = Bytes.of_string (Reader.read_string handle 40 24);
      }


  let get_record_offset record_index record_size =
    header_size + (record_index * (record_size |> Int32.to_int_trunc))


  (** Binary search for timestamp in time series *)
  let find_timestamp handle header target_timestamp =
    let _record_size = Int32.to_int_trunc header.record_size in
    let total_records = Int64.to_int_trunc header.record_count in

    let rec binary_search left right =
      if left > right then None
      else
        let mid = (left + right) / 2 in
        let offset = get_record_offset mid header.record_size in
        let timestamp = Reader.read_int64_le handle offset in

        if Int64.equal timestamp target_timestamp then Some mid
        else if Int64.(timestamp < target_timestamp) then binary_search (mid + 1) right
        else binary_search left (mid - 1) in

    binary_search 0 (total_records - 1)


  (** Find range of records within time window *)
  let find_time_range handle header start_time end_time =
    let _record_size = Int32.to_int_trunc header.record_size in
    let total_records = Int64.to_int_trunc header.record_count in

    let rec find_start_index left right =
      if left > right then left
      else
        let mid = (left + right) / 2 in
        let offset = get_record_offset mid header.record_size in
        let timestamp = Reader.read_int64_le handle offset in

        if Int64.(timestamp < start_time) then find_start_index (mid + 1) right
        else find_start_index left (mid - 1) in

    let rec find_end_index left right =
      if left > right then right
      else
        let mid = (left + right) / 2 in
        let offset = get_record_offset mid header.record_size in
        let timestamp = Reader.read_int64_le handle offset in

        if Int64.(timestamp <= end_time) then find_end_index (mid + 1) right
        else find_end_index left (mid - 1) in

    let start_idx = find_start_index 0 (total_records - 1) in
    let end_idx = find_end_index start_idx (total_records - 1) in

    (start_idx, end_idx)
end

(** Memory pool for efficient allocation of mapped regions *)
module MmapPool = struct
  type pool = {
    available : mmap_handle Queue.t;
    in_use : mmap_handle Hash_set.t;
    max_size : int;
    mutable current_size : int;
  }

  let create ~max_size =
    {
      available = Queue.create ();
      in_use = Hash_set.create (module MmapHandle);
      max_size;
      current_size = 0;
    }


  let acquire pool file_path =
    match Queue.dequeue pool.available with
    | Some handle ->
      Hash_set.add pool.in_use handle ;
      handle
    | None when pool.current_size < pool.max_size ->
      let handle = create_mmap file_path in
        Hash_set.add pool.in_use handle ;
        pool.current_size <- pool.current_size + 1 ;
        handle
    | None ->
      (* Pool is full, need to wait or create temporary mapping *)
      create_mmap file_path


  let release pool handle =
    if Hash_set.mem pool.in_use handle then (
      Hash_set.remove pool.in_use handle ;
      Queue.enqueue pool.available handle)


  let close_all pool =
    Queue.iter pool.available ~f:close_mmap ;
    Hash_set.iter pool.in_use ~f:close_mmap ;
    Queue.clear pool.available ;
    Hash_set.clear pool.in_use ;
    pool.current_size <- 0
end
