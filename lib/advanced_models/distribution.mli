(** Probability distributions used by [Hypothesis_test].

    All implementations are coarse — sufficient for the project's ≤ 2-significant-figure p-value
    contract. PDFs are exact closed-form; CDFs and quantiles use the approximations in [Special]. *)

module Normal : sig
  val cdf : x:float -> float

  val pdf : x:float -> float

  val quantile : p:float -> float
end

module Student_t : sig
  val cdf : x:float -> df:float -> float

  val pdf : x:float -> df:float -> float
end

module Chi_squared : sig
  val cdf : x:float -> df:float -> float
end

module F : sig
  val cdf : x:float -> d1:float -> d2:float -> float
end
