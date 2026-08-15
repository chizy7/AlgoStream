(* Lossless column compression.

   Format (both encoders): a 4-byte length prefix (little-endian u32 = number of values) followed by
   the encoded body. Empty arrays produce a 4-byte header only.

   Float body: first value is written as raw 8-byte LE int64 (Int64.bits_of_float). Subsequent
   values are XOR-delta-encoded: - if XOR == 0, write a single byte 0x00 (run-of-zeros marker) -
   otherwise, write a tag byte = (leading-zero-count // 4) packed in the low 4 bits and
   (significant-bytes-count - 1) packed in the high 4 bits, followed by the significant bytes
   (little-endian).

   Int64 body: zigzag-varint of the delta against the previous value (delta of the first value is
   the value itself). *)

(* ───── varint helpers ─────────────────────────────────────────────── *)

let zigzag_encode n =
  let shifted = Int64.shift_left n 1 in
  let masked = Int64.shift_right n 63 in
    Int64.logxor shifted masked


let zigzag_decode n =
  let s1 = Int64.shift_right_logical n 1 in
  let neg = Int64.neg (Int64.logand n 1L) in
    Int64.logxor s1 neg


let varint_write buf n =
  let n = ref n in
  let stop = ref false in
    while not !stop do
      let low = Int64.to_int (Int64.logand !n 0x7fL) in
      let next = Int64.shift_right_logical !n 7 in
        if Int64.equal next 0L then (
          Buffer.add_char buf (Char.chr low) ;
          stop := true)
        else (
          Buffer.add_char buf (Char.chr (low lor 0x80)) ;
          n := next)
    done


let varint_read bytes pos =
  let p = ref pos in
  let acc = ref 0L in
  let shift = ref 0 in
  let stop = ref false in
    while not !stop do
      let b = Char.code (Bytes.unsafe_get bytes !p) in
        incr p ;
        let chunk = Int64.of_int (b land 0x7f) in
          acc := Int64.logor !acc (Int64.shift_left chunk !shift) ;
          shift := !shift + 7 ;
          if b land 0x80 = 0 then stop := true
    done ;
    (!acc, !p)


let put_u32_le buf n =
  Buffer.add_char buf (Char.chr (n land 0xff)) ;
  Buffer.add_char buf (Char.chr ((n lsr 8) land 0xff)) ;
  Buffer.add_char buf (Char.chr ((n lsr 16) land 0xff)) ;
  Buffer.add_char buf (Char.chr ((n lsr 24) land 0xff))


let get_u32_le bytes pos =
  let b0 = Char.code (Bytes.unsafe_get bytes pos) in
  let b1 = Char.code (Bytes.unsafe_get bytes (pos + 1)) in
  let b2 = Char.code (Bytes.unsafe_get bytes (pos + 2)) in
  let b3 = Char.code (Bytes.unsafe_get bytes (pos + 3)) in
    b0 lor (b1 lsl 8) lor (b2 lsl 16) lor (b3 lsl 24)


let put_i64_le buf n =
  for i = 0 to 7 do
    let byte = Int64.to_int (Int64.logand (Int64.shift_right_logical n (i * 8)) 0xffL) in
      Buffer.add_char buf (Char.chr byte)
  done


let get_i64_le bytes pos =
  let acc = ref 0L in
    for i = 0 to 7 do
      let byte = Char.code (Bytes.unsafe_get bytes (pos + i)) in
        acc := Int64.logor !acc (Int64.shift_left (Int64.of_int byte) (i * 8))
    done ;
    !acc


(* ───── float column ────────────────────────────────────────────── *)

(* Returns the number of low-order zero bytes in [n]. We pack tag = (n_zeros << 4 | n_sig - 1).
   n_sig ∈ [1..8]. For XOR with high entropy we always emit at least one significant byte. *)
let count_low_zero_bytes (n : int64) =
  if Int64.equal n 0L then 8
  else
    let z = ref 0 in
    let m = ref n in
      while Int64.logand !m 0xffL = 0L && !z < 8 do
        incr z ;
        m := Int64.shift_right_logical !m 8
      done ;
      !z


let encode_float arr =
  let n = Bigarray.Array1.dim arr in
  let buf = Buffer.create (8 * (n + 1)) in
    put_u32_le buf n ;
    if n > 0 then (
      let prev_bits = ref (Int64.bits_of_float (Bigarray.Array1.unsafe_get arr 0)) in
        put_i64_le buf !prev_bits ;
        for i = 1 to n - 1 do
          let cur_bits = Int64.bits_of_float (Bigarray.Array1.unsafe_get arr i) in
          let xor = Int64.logxor cur_bits !prev_bits in
            (if Int64.equal xor 0L then Buffer.add_char buf (Char.chr 0)
             else
               let zeros = count_low_zero_bytes xor in
               let n_sig = 8 - zeros in
               let n_sig = max 1 n_sig in
               let tag = (zeros lsl 4) lor (n_sig - 1) in
                 Buffer.add_char buf (Char.chr tag) ;
                 let shifted = Int64.shift_right_logical xor (zeros * 8) in
                   for j = 0 to n_sig - 1 do
                     let byte =
                       Int64.to_int (Int64.logand (Int64.shift_right_logical shifted (j * 8)) 0xffL)
                     in
                       Buffer.add_char buf (Char.chr byte)
                   done) ;
            prev_bits := cur_bits
        done) ;
    Buffer.to_bytes buf


let decode_float bytes =
  let n = get_u32_le bytes 0 in
  let arr = Bigarray.Array1.create Bigarray.float64 Bigarray.c_layout n in
    if n > 0 then (
      let pos = ref 4 in
      let prev_bits = ref (get_i64_le bytes !pos) in
        pos := !pos + 8 ;
        Bigarray.Array1.unsafe_set arr 0 (Int64.float_of_bits !prev_bits) ;
        for i = 1 to n - 1 do
          let tag = Char.code (Bytes.unsafe_get bytes !pos) in
            incr pos ;
            let cur_bits =
              if tag = 0 then !prev_bits
              else
                let zeros = (tag lsr 4) land 0xf in
                let n_sig = (tag land 0xf) + 1 in
                let acc = ref 0L in
                  for j = 0 to n_sig - 1 do
                    let byte = Char.code (Bytes.unsafe_get bytes !pos) in
                      incr pos ;
                      acc := Int64.logor !acc (Int64.shift_left (Int64.of_int byte) (j * 8))
                  done ;
                  let xor = Int64.shift_left !acc (zeros * 8) in
                    Int64.logxor xor !prev_bits in
              Bigarray.Array1.unsafe_set arr i (Int64.float_of_bits cur_bits) ;
              prev_bits := cur_bits
        done) ;
    arr


(* ───── int64 column (delta + zigzag varint) ───────────────────── *)

let encode_int64 arr =
  let n = Bigarray.Array1.dim arr in
  let buf = Buffer.create (n * 2) in
    put_u32_le buf n ;
    if n > 0 then (
      let prev = ref (Bigarray.Array1.unsafe_get arr 0) in
        varint_write buf (zigzag_encode !prev) ;
        for i = 1 to n - 1 do
          let cur = Bigarray.Array1.unsafe_get arr i in
          let delta = Int64.sub cur !prev in
            varint_write buf (zigzag_encode delta) ;
            prev := cur
        done) ;
    Buffer.to_bytes buf


let decode_int64 bytes =
  let n = get_u32_le bytes 0 in
  let arr = Bigarray.Array1.create Bigarray.int64 Bigarray.c_layout n in
    if n > 0 then (
      let pos = ref 4 in
      let raw, p1 = varint_read bytes !pos in
        pos := p1 ;
        let prev = ref (zigzag_decode raw) in
          Bigarray.Array1.unsafe_set arr 0 !prev ;
          for i = 1 to n - 1 do
            let raw, p_next = varint_read bytes !pos in
              pos := p_next ;
              let delta = zigzag_decode raw in
              let cur = Int64.add !prev delta in
                Bigarray.Array1.unsafe_set arr i cur ;
                prev := cur
          done) ;
    arr
