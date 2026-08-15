(* Int64 helpers. Named rather than operator-ised: shadowing [**] or [lsl] for Int64 reads worse
   than it saves, and this file is short. *)
let xor = Int64.logxor

let ior = Int64.logor

let add64 = Int64.add

let mul64 = Int64.mul

let shl = Int64.shift_left

let shr = Int64.shift_right_logical

let rotl x k = ior (shl x k) (shr x (64 - k))

(* ───── SplitMix64 ─────────────────────────────────────────────────── *)

(* Steele, Lea & Flood (2014), "Fast Splittable Pseudorandom Number Generators". Used only to expand
   a seed into xoshiro's 256-bit state — its avalanche is what makes adjacent seeds produce
   uncorrelated streams. *)

let golden = 0x9E3779B97F4A7C15L

let splitmix64 state =
  let z = add64 !state golden in
    state := z ;
    let z = mul64 (xor z (shr z 30)) 0xBF58476D1CE4E5B9L in
    let z = mul64 (xor z (shr z 27)) 0x94D049BB133111EBL in
      xor z (shr z 31)


(* ───── xoshiro256++ ───────────────────────────────────────────────── *)

(* Blackman & Vigna (2018). Period 2^256 - 1, passes BigCrush. *)

type t = {
  mutable s0 : int64;
  mutable s1 : int64;
  mutable s2 : int64;
  mutable s3 : int64;
}

let of_seed64 seed =
  let sm = ref seed in
  let s0 = splitmix64 sm in
  let s1 = splitmix64 sm in
  let s2 = splitmix64 sm in
  let s3 = splitmix64 sm in
    (* SplitMix64 cannot emit four zeros from any seed, so the all-zero xoshiro state — its one
       degenerate fixed point — is unreachable here. *)
    { s0; s1; s2; s3 }


let create ~seed = of_seed64 (Int64.of_int seed)

let substream ~root_seed ~index =
  (* Offsetting by index * golden before expansion means every (root_seed, index) pair lands on a
     different SplitMix64 trajectory. Pure function of the arguments — no dependence on draw
     history, which is the property Pool relies on. *)
  of_seed64 (add64 root_seed (mul64 (Int64.of_int index) golden))


let bits t =
  let result = add64 (rotl (add64 t.s0 t.s3) 23) t.s0 in
  let tmp = shl t.s1 17 in
    t.s2 <- xor t.s2 t.s0 ;
    t.s3 <- xor t.s3 t.s1 ;
    t.s1 <- xor t.s1 t.s2 ;
    t.s0 <- xor t.s0 t.s3 ;
    t.s2 <- xor t.s2 tmp ;
    t.s3 <- rotl t.s3 45 ;
    result


let split t = of_seed64 (bits t)

let copy t = { s0 = t.s0; s1 = t.s1; s2 = t.s2; s3 = t.s3 }

(* ───── float conversions ──────────────────────────────────────────── *)

(* 2^-53. Taking the top 53 bits gives the full mantissa with uniform spacing; taking the low bits
   would be biased on generators with weak low-order bits (xoshiro's are fine, but the high-bit
   convention is the portable one). *)
let two_pow_neg53 = 0x1.0p-53

let uniform t = Int64.to_float (shr (bits t) 11) *. two_pow_neg53

let uniform_pos t =
  (* Shifting by half a ulp maps [0, 1) onto (0, 1): the smallest value is 2^-54 and the largest is
     1 - 2^-54. Guarantees [log] is finite, which Box-Muller requires. *)
  (Int64.to_float (shr (bits t) 11) +. 0.5) *. two_pow_neg53


let uniform_range t ~lo ~hi = if hi <= lo then lo else lo +. (uniform t *. (hi -. lo))

(* ───── integers ───────────────────────────────────────────────────── *)

let int_below t n =
  if n <= 0 then invalid_arg "Rng.int_below: n must be positive" ;
  (* Lemire (2019), "Fast Random Integer Generation in an Interval", using the top 62 bits so the
     product stays inside OCaml's 63-bit int without overflow. The rejection loop removes the modulo
     bias; it retries with probability < n / 2^62, i.e. effectively never. *)
  let n64 = Int64.of_int n in
  let limit = Int64.sub Int64.max_int (Int64.rem Int64.max_int n64) in
  let rec draw () =
    let r = shr (bits t) 1 in
      if Int64.compare r limit >= 0 then draw () else Int64.to_int (Int64.rem r n64) in
    draw ()


let shuffle t a =
  let n = Array.length a in
    for i = n - 1 downto 1 do
      let j = int_below t (i + 1) in
      let tmp = a.(i) in
        a.(i) <- a.(j) ;
        a.(j) <- tmp
    done
