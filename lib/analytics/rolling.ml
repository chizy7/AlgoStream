(* Common circular-buffer scaffolding used by all four modules. *)

module Buf = struct
  type t = {
    data : float array;
    cap : int;
    mutable index : int;
    mutable count : int;
  }

  let create ~cap = { data = Array.make cap 0.0; cap; index = 0; count = 0 }

  let push t x =
    t.data.(t.index) <- x ;
    t.index <- (t.index + 1) mod t.cap ;
    if t.count < t.cap then t.count <- t.count + 1


  let n t = t.count

  let iter t f =
    for i = 0 to t.count - 1 do
      f t.data.(i)
    done
end

module Rolling_mean = struct
  type t = {
    buf : Buf.t;
    mutable sum : float;
    mutable last_value : float;
  }

  let create ~window = { buf = Buf.create ~cap:window; sum = 0.0; last_value = 0.0 }

  let update t x =
    let outgoing =
      if t.buf.count >= t.buf.cap then t.buf.data.(t.buf.index) (* about to be overwritten *)
      else 0.0 in
      Buf.push t.buf x ;
      t.sum <- t.sum -. outgoing +. x ;
      t.last_value <- t.sum /. float_of_int t.buf.count ;
      t.last_value


  let value t = t.last_value

  let n t = Buf.n t.buf
end

(* ───── Rolling_var: incremental sum/sum2 + periodic recompute ────── *)

module Rolling_var = struct
  type t = {
    buf : Buf.t;
    recompute_every : int;
    mutable sum : float;
    mutable sum2 : float;
    mutable since_recompute : int;
    mutable last_value : float;
  }

  let create ~window ~recompute_every =
    {
      buf = Buf.create ~cap:window;
      recompute_every;
      sum = 0.0;
      sum2 = 0.0;
      since_recompute = 0;
      last_value = 0.0;
    }


  let recompute_full t =
    let s = ref 0.0 in
    let s2 = ref 0.0 in
      Buf.iter t.buf (fun v ->
        s := !s +. v ;
        s2 := !s2 +. (v *. v)) ;
      t.sum <- !s ;
      t.sum2 <- !s2 ;
      t.since_recompute <- 0


  let update t x =
    let outgoing = if t.buf.count >= t.buf.cap then t.buf.data.(t.buf.index) else 0.0 in
      Buf.push t.buf x ;
      t.sum <- t.sum -. outgoing +. x ;
      t.sum2 <- t.sum2 -. (outgoing *. outgoing) +. (x *. x) ;
      t.since_recompute <- t.since_recompute + 1 ;
      if t.since_recompute >= t.recompute_every then recompute_full t ;
      let n = t.buf.count in
      let v =
        if n < 2 then 0.0
        else
          let m = t.sum /. float_of_int n in
          let var_unbiased = (t.sum2 -. (float_of_int n *. m *. m)) /. float_of_int (n - 1) in
            max 0.0 var_unbiased in
        t.last_value <- v ;
        v


  let value t = t.last_value

  let std_dev t = sqrt t.last_value

  let n t = Buf.n t.buf
end

(* ───── Rolling_cov ──────────────────────────────────────────────── *)

module Rolling_cov = struct
  type t = {
    buf_x : Buf.t;
    buf_y : Buf.t;
    recompute_every : int;
    mutable sum_x : float;
    mutable sum_y : float;
    mutable sum_xy : float;
    mutable since_recompute : int;
    mutable last_value : float;
  }

  let create ~window ~recompute_every =
    {
      buf_x = Buf.create ~cap:window;
      buf_y = Buf.create ~cap:window;
      recompute_every;
      sum_x = 0.0;
      sum_y = 0.0;
      sum_xy = 0.0;
      since_recompute = 0;
      last_value = 0.0;
    }


  let recompute_full t =
    let sx = ref 0.0 in
    let sy = ref 0.0 in
    let sxy = ref 0.0 in
    let n = t.buf_x.count in
      for i = 0 to n - 1 do
        let xv = t.buf_x.data.(i) in
        let yv = t.buf_y.data.(i) in
          sx := !sx +. xv ;
          sy := !sy +. yv ;
          sxy := !sxy +. (xv *. yv)
      done ;
      t.sum_x <- !sx ;
      t.sum_y <- !sy ;
      t.sum_xy <- !sxy ;
      t.since_recompute <- 0


  let update t x y =
    let outgoing_x = if t.buf_x.count >= t.buf_x.cap then t.buf_x.data.(t.buf_x.index) else 0.0 in
    let outgoing_y = if t.buf_y.count >= t.buf_y.cap then t.buf_y.data.(t.buf_y.index) else 0.0 in
      Buf.push t.buf_x x ;
      Buf.push t.buf_y y ;
      t.sum_x <- t.sum_x -. outgoing_x +. x ;
      t.sum_y <- t.sum_y -. outgoing_y +. y ;
      t.sum_xy <- t.sum_xy -. (outgoing_x *. outgoing_y) +. (x *. y) ;
      t.since_recompute <- t.since_recompute + 1 ;
      if t.since_recompute >= t.recompute_every then recompute_full t ;
      let n = t.buf_x.count in
      let v =
        if n < 2 then 0.0
        else
          let mx = t.sum_x /. float_of_int n in
          let my = t.sum_y /. float_of_int n in
            (t.sum_xy -. (float_of_int n *. mx *. my)) /. float_of_int (n - 1) in
        t.last_value <- v ;
        v


  let value t = t.last_value

  let n t = Buf.n t.buf_x
end

(* ───── Rolling_corr (cov / sqrt(var_x * var_y)) ──────────────────── *)

module Rolling_corr = struct
  type t = {
    cov : Rolling_cov.t;
    var_x : Rolling_var.t;
    var_y : Rolling_var.t;
    mutable last_value : float;
  }

  let create ~window ~recompute_every =
    {
      cov = Rolling_cov.create ~window ~recompute_every;
      var_x = Rolling_var.create ~window ~recompute_every;
      var_y = Rolling_var.create ~window ~recompute_every;
      last_value = 0.0;
    }


  let update t x y =
    let cov = Rolling_cov.update t.cov x y in
    let vx = Rolling_var.update t.var_x x in
    let vy = Rolling_var.update t.var_y y in
    let denom = sqrt (vx *. vy) in
    let v = if denom < 1e-12 then 0.0 else cov /. denom in
    let clamped = max (-1.0) (min 1.0 v) in
      t.last_value <- clamped ;
      clamped


  let value t = t.last_value

  let n t = Rolling_cov.n t.cov
end
