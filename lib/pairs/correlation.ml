module Rolling = Algostream_analytics.Rolling

type t = Rolling.Rolling_corr.t

let create ~window ~recompute_every = Rolling.Rolling_corr.create ~window ~recompute_every

let update t ~y ~x = Rolling.Rolling_corr.update t x y

let value = Rolling.Rolling_corr.value

let n = Rolling.Rolling_corr.n
