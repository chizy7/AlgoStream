module Symbol = Algostream_normalization.Symbol

type t = {
  y : Symbol.t;
  x : Symbol.t;
}

let of_symbols a b =
  let ca = Symbol.to_canonical a in
  let cb = Symbol.to_canonical b in
    if String.compare ca cb <= 0 then { y = a; x = b } else { y = b; x = a }


let y t = t.y

let x t = t.x

let to_string t = Printf.sprintf "%s~%s" (Symbol.to_canonical t.y) (Symbol.to_canonical t.x)

let equal a b = Symbol.equal a.y b.y && Symbol.equal a.x b.x

let hash t = Hashtbl.hash (Symbol.to_canonical t.y, Symbol.to_canonical t.x)
