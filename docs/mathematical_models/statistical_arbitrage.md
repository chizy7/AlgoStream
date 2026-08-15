# Statistical Arbitrage Mathematical Models

This document describes the mathematical foundations of AlgoStream's statistical arbitrage implementation, focusing on cointegration analysis, spread modeling, and signal generation.

## Overview

Statistical arbitrage exploits statistical relationships between asset prices to generate trading signals. AlgoStream implements two primary approaches:

1. **Cointegration-based pairs trading**
2. **Correlation-based mean reversion**

## Cointegration Analysis

### Theoretical Foundation

Two time series X_t and Y_t are cointegrated if:
1. Both series are integrated of order 1: I(1)
2. There exists a linear combination that is stationary: I(0)

Mathematically: `βX_t + γY_t ~ I(0)` where β and γ are cointegration coefficients.

### Augmented Dickey-Fuller (ADF) Test

Tests the null hypothesis that a time series has a unit root (non-stationary).

**Test Equation:**
```
ΔY_t = α + βt + γY_{t-1} + δ₁ΔY_{t-1} + ... + δₚΔY_{t-p} + ε_t
```

Where:
- `ΔY_t = Y_t - Y_{t-1}` (first difference)
- `α` = intercept
- `βt` = time trend
- `γ` = coefficient on lagged level
- `δᵢ` = coefficients on lagged differences

**Implementation:**
```ocaml
let calculate_adf_statistic price_series =
  (* Calculate first differences *)
  let diffs = List.map2_exn (List.drop price_series 1) price_series
    ~f:(fun p1 p0 -> p1 -. p0) in
  let lagged_levels = List.drop_last_exn price_series in

  (* Regression: diff = α + γ × lagged_level *)
  let beta = covariance diffs lagged_levels /. variance lagged_levels in
  let t_statistic = beta /. standard_error_beta in
  (t_statistic, p_value)
```

**Critical Values (5% significance):**
- No constant, no trend: -1.95
- Constant, no trend: -2.86
- Constant and trend: -3.41

### Johansen Cointegration Test

Tests for cointegration between multiple time series using maximum likelihood estimation.

**Vector Error Correction Model (VECM):**
```
ΔX_t = α₁(βX_{t-1} + γY_{t-1}) + Σδᵢ₁ΔX_{t-i} + Σθᵢ₁ΔY_{t-i} + ε₁t
ΔY_t = α₂(βX_{t-1} + γY_{t-1}) + Σδᵢ₂ΔX_{t-i} + Σθᵢ₂ΔY_{t-i} + ε₂t
```

**Trace Statistic:**
```
λ_trace = -T × Σᵢ₌ᵣ₊₁ⁿ ln(1 - λᵢ)
```

Where T is sample size and λᵢ are eigenvalues.

## Spread Modeling

### Hedge Ratio Estimation

For cointegrated pairs, the hedge ratio β minimizes the variance of the spread:

**Ordinary Least Squares (OLS):**
```
Y_t = α + βX_t + ε_t
```

**Implementation:**
```ocaml
let estimate_hedge_ratio prices_x prices_y =
  let n = Float.of_int (List.length prices_x) in
  let mean_x = List.fold prices_x ~init:0.0 ~f:(+.) /. n in
  let mean_y = List.fold prices_y ~init:0.0 ~f:(+.) /. n in

  let numerator = List.fold2_exn prices_x prices_y ~init:0.0
    ~f:(fun acc x y -> acc +. ((x -. mean_x) *. (y -. mean_y))) in
  let denominator = List.fold prices_x ~init:0.0
    ~f:(fun acc x -> acc +. ((x -. mean_x) ** 2.0)) in

  numerator /. denominator
```

### Spread Calculation

**Cointegrated Spread:**
```
S_t = P₁_t - β × P₂_t
```

**Log-Price Spread (for percentage changes):**
```
S_t = ln(P₁_t) - β × ln(P₂_t)
```

## Mean Reversion Modeling

### Ornstein-Uhlenbeck Process

The spread follows an Ornstein-Uhlenbeck process:
```
dS_t = κ(μ - S_t)dt + σdW_t
```

Where:
- `κ` = mean reversion speed
- `μ` = long-term mean
- `σ` = volatility
- `W_t` = Wiener process

### Half-Life Estimation

Time for spread to revert halfway to its mean:

**Discrete AR(1) Model:**
```
S_t = φS_{t-1} + ε_t
```

**Half-Life:**
```
τ = ln(0.5) / ln(φ) = -ln(2) / ln(φ)
```

**Implementation:**
```ocaml
let estimate_half_life spread_series =
  let lagged_spreads = List.drop_last_exn spread_series in
  let current_spreads = List.drop spread_series 1 in
  let changes = List.map2_exn current_spreads lagged_spreads
    ~f:(fun curr lag -> curr -. lag) in

  (* Regression: change = α + λ × lagged_level *)
  let lambda = -1.0 *. (covariance changes lagged_spreads /. variance lagged_spreads) in
  if Float.(lambda <= 0.0) then Float.infinity
  else (Float.log 2.0) /. lambda
```

## Signal Generation

### Z-Score Normalization

Standardize spread for threshold-based signals:

```
Z_t = (S_t - μ_S) / σ_S
```

Where:
- `μ_S` = rolling mean of spread
- `σ_S` = rolling standard deviation of spread

**Implementation:**
```ocaml
let calculate_z_score values =
  let n = Float.of_int (List.length values) in
  let mean = List.fold values ~init:0.0 ~f:(+.) /. n in
  let variance = List.fold values ~init:0.0 ~f:(fun acc v ->
    acc +. ((v -. mean) *. (v -. mean))) /. (n -. 1.0) in
  let std_dev = Float.sqrt variance in
  let latest_value = List.last_exn values in
  (latest_value -. mean) /. std_dev
```

### Trading Signals

**Entry Conditions:**
- **Long Signal**: Z-score < -entry_threshold (spread unusually low)
- **Short Signal**: Z-score > +entry_threshold (spread unusually high)

**Exit Conditions:**
- **Mean Reversion**: |Z-score| < exit_threshold
- **Stop Loss**: |Z-score| > stop_loss_threshold

**Position Sizing:**
```
position_size = capital × (|Z-score| / max_z_score) × max_position_fraction
```

## Risk Management

### Value at Risk (VaR)

Parametric VaR for normal distribution:
```
VaR_α = μ_portfolio + σ_portfolio × Φ⁻¹(α)
```

**Implementation:**
```ocaml
let calculate_var returns ~confidence_level =
  let sorted_returns = List.sort returns ~compare:Float.compare in
  let index = Int.of_float
    (Float.of_int (List.length returns) *. (1.0 -. confidence_level)) in
  if index < List.length returns && index >= 0 then
    List.nth_exn sorted_returns index
  else 0.0
```

### Expected Shortfall (Conditional VaR)

Expected loss beyond VaR threshold:
```
ES_α = E[L | L ≥ VaR_α]
```

### Maximum Drawdown

Largest peak-to-trough decline:
```
DD_t = max(0, max(V_s, s ≤ t) - V_t)
MDD = max(DD_t, t ∈ [0,T])
```

**Implementation:**
```ocaml
let calculate_maximum_drawdown nav_history =
  let rec find_max_dd peak _current_dd max_dd = function
    | [] -> max_dd
    | nav :: rest ->
        let new_peak = Float.max peak nav in
        let new_dd = if Float.(new_peak = 0.0) then 0.0
          else (new_peak -. nav) /. new_peak in
        let new_max_dd = Float.max max_dd new_dd in
        find_max_dd new_peak new_dd new_max_dd rest in
  match nav_history with
  | [] -> 0.0
  | first :: rest -> find_max_dd first 0.0 0.0 rest
```

## Performance Metrics

### Sharpe Ratio

Risk-adjusted return measure:
```
Sharpe = (μ_portfolio - r_f) / σ_portfolio
```

### Information Ratio

Excess return per unit of tracking error:
```
IR = (μ_portfolio - μ_benchmark) / σ_tracking_error
```

### Calmar Ratio

Annual return divided by maximum drawdown:
```
Calmar = Annual_Return / |MDD|
```

## Implementation Considerations

### Numerical Stability

**Avoid Division by Zero:**
```ocaml
let safe_divide ~numerator ~denominator =
  if Float.(abs denominator < 1e-10) then 0.0
  else numerator /. denominator
```

**Handle Missing Data:**
```ocaml
let filter_valid_prices prices =
  List.filter prices ~f:(fun p -> Float.is_finite p && Float.(p > 0.0))
```

### Statistical Significance

**Minimum Sample Size:**
- Cointegration tests: ≥ 100 observations
- Half-life estimation: ≥ 50 observations
- Z-score calculation: ≥ 20 observations

**Rolling Window Selection:**
- Balance responsiveness vs. stability
- Typical range: 20-60 trading days
- Adaptive windows based on market volatility

### Parameter Optimization

**Grid Search for Thresholds:**
```ocaml
let optimize_thresholds historical_data =
  let entry_thresholds = [1.5; 2.0; 2.5; 3.0] in
  let exit_thresholds = [0.25; 0.5; 0.75; 1.0] in
  (* Backtesting framework to find optimal combination *)
```

## Model Validation

### Out-of-Sample Testing

1. **Training Period**: Estimate parameters
2. **Validation Period**: Generate signals
3. **Test Period**: Evaluate performance

### Rolling Window Analysis

Continuously update parameters as new data arrives:
```ocaml
let rolling_update pair ~new_price_a ~new_price_b =
  let updated_spreads = new_spread :: (List.take pair.spread_series (pair.lookback_window - 1)) in
  let new_z_score = calculate_z_score updated_spreads in
  { pair with spread_series = updated_spreads; z_score_series = new_z_score :: pair.z_score_series }
```

### Model Diagnostics

**Residual Analysis:**
- Ljung-Box test for autocorrelation
- Jarque-Bera test for normality
- ARCH test for heteroskedasticity

**Cointegration Stability:**
- Recursive ADF tests
- Parameter stability tests
- Structural break detection

This mathematical framework provides the theoretical foundation for AlgoStream's statistical arbitrage capabilities, ensuring robust and statistically sound trading strategies.

---

*For implementation details, see `lib/domain/pairs/pair.ml` and related statistical functions.*