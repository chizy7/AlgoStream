type t = {
  mutable data : float array;
  mutable n : int;
}

let create ?(capacity = 1024) () = { data = Array.make capacity 0.0; n = 0 }

let length t = t.n

let capacity t = Array.length t.data

let grow t =
  let cap = Array.length t.data in
  let new_cap = if cap = 0 then 64 else cap * 2 in
  let next = Array.make new_cap 0.0 in
    Array.blit t.data 0 next 0 t.n ;
    t.data <- next


let push t x =
  if t.n >= Array.length t.data then grow t ;
  t.data.(t.n) <- x ;
  t.n <- t.n + 1


let freeze t =
  let arr = Bigarray.Array1.create Bigarray.float64 Bigarray.c_layout t.n in
    for i = 0 to t.n - 1 do
      Bigarray.Array1.unsafe_set arr i t.data.(i)
    done ;
    arr


module Int64_col = struct
  type t = {
    mutable data : Int64.t array;
    mutable n : int;
  }

  let create ?(capacity = 1024) () = { data = Array.make capacity 0L; n = 0 }

  let length t = t.n

  let grow t =
    let cap = Array.length t.data in
    let new_cap = if cap = 0 then 64 else cap * 2 in
    let next = Array.make new_cap 0L in
      Array.blit t.data 0 next 0 t.n ;
      t.data <- next


  let push t x =
    if t.n >= Array.length t.data then grow t ;
    t.data.(t.n) <- x ;
    t.n <- t.n + 1


  let freeze t =
    let arr = Bigarray.Array1.create Bigarray.int64 Bigarray.c_layout t.n in
      for i = 0 to t.n - 1 do
        Bigarray.Array1.unsafe_set arr i t.data.(i)
      done ;
      arr
end
