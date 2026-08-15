# Domain Models Guide

This guide provides a comprehensive overview of AlgoStream's core domain models, which form the foundation of the trading platform.

## Overview

AlgoStream's domain models are built using OCaml's strong type system to ensure correctness and prevent runtime errors. All models support sexp serialization for data persistence and debugging.

## Market Data Models

### Asset (`lib/domain/market/asset.ml`)

Represents different asset classes with proper categorization:

```ocaml
type asset_class =
  | Equity of { sector: string option; market_cap: float option }
  | Forex of { base_currency: string; quote_currency: string }
  | Crypto of { base_currency: string; quote_currency: string }
  | Derivatives of { underlying: string; expiry: Timestamp.t option }

type asset = {
  symbol: string;
  asset_class: asset_class;
  exchange: string;
  tick_size: float;
  lot_size: float;
  created_at: Timestamp.t;
}
```

**Key Functions:**
- `create_asset` - Create new asset with validation
- `is_tradeable` - Check if asset can be traded
- `get_tick_size` - Get minimum price increment

### Tick (`lib/domain/market/tick.ml`)

Real-time market data with bid/ask spreads:

```ocaml
type tick = {
  symbol: string;
  timestamp: Timestamp.t;
  bid_price: float;
  ask_price: float;
  bid_size: float;
  ask_size: float;
  last_price: float;
  volume: float;
}
```

**Key Functions:**
- `create_tick` - Create market tick with validation
- `spread` - Calculate bid-ask spread
- `mid_price` - Calculate mid-market price
- `is_valid` - Validate tick data integrity

### Order Book (`lib/domain/market/order_book.ml`)

Level-2 order book with market depth analysis:

```ocaml
type price_level = {
  price: float;
  size: float;
  order_count: int;
}

type order_book = {
  symbol: string;
  bids: price_level list;
  asks: price_level list;
  timestamp: Timestamp.t;
}
```

**Key Functions:**
- `create_order_book` - Initialize empty order book
- `add_level` - Add price level
- `remove_level` - Remove price level
- `best_bid`/`best_ask` - Get top of book
- `market_depth` - Calculate depth at price levels

## Trading Models

### Order (`lib/domain/orders/order.ml`)

Complete order lifecycle management:

```ocaml
type order_type =
  | Market
  | Limit of { limit_price: float }
  | Stop of { stop_price: float }
  | Stop_limit of { stop_price: float; limit_price: float }
  | Iceberg of { display_size: float; limit_price: float }

type order_status =
  | Pending
  | Partially_filled of { filled_quantity: float }
  | Filled
  | Cancelled
  | Rejected of { reason: string }

type order = {
  id: string;
  symbol: string;
  side: [`Buy | `Sell];
  order_type: order_type;
  quantity: float;
  status: order_status;
  created_at: Timestamp.t;
  updated_at: Timestamp.t;
}
```

**Key Functions:**
- `create_order` - Create new order
- `fill_order` - Process order fill
- `cancel_order` - Cancel pending order
- `is_filled` - Check if order completely filled

### Trade (`lib/domain/trades/trade.ml`)

Trade execution tracking with analytics:

```ocaml
type execution_type = Maker | Taker | Self_trade

type trade = {
  id: string;
  order_id: string;
  symbol: string;
  side: [`Buy | `Sell];
  quantity: float;
  price: float;
  timestamp: Timestamp.t;
  execution_type: execution_type;
  commission: float;
  commission_asset: string;
  exchange: string;
  strategy_id: string option;
}
```

**Key Functions:**
- `create_trade` - Create trade record
- `gross_value` - Calculate gross trade value
- `net_value` - Calculate net value after commission
- `trade_pnl` - Calculate P&L against reference price
- `effective_price` - Price including commission impact

## Portfolio Management

### Position (`lib/domain/portfolio/position.ml`)

Real-time position tracking with P&L:

```ocaml
type position = {
  symbol: string;
  quantity: float;
  average_price: float;
  last_price: float;
  unrealized_pnl: float;
  realized_pnl: float;
  total_cost: float;
  commission_paid: float;
  opened_at: Timestamp.t;
  updated_at: Timestamp.t;
  strategy_id: string option;
}
```

**Key Functions:**
- `create_position` - Initialize empty position
- `add_trade` - Add trade to position (handles averaging)
- `update_last_price` - Update unrealized P&L
- `market_value` - Current market value
- `total_pnl` - Total realized + unrealized P&L

### Portfolio (`lib/domain/portfolio/portfolio.ml`)

Portfolio-level management and analytics:

```ocaml
type portfolio = {
  account_id: string;
  positions: (string, Position.position) Map.Poly.t;
  cash_balance: float;
  initial_capital: float;
  total_commission_paid: float;
  created_at: Timestamp.t;
  updated_at: Timestamp.t;
  strategy_allocations: (string, float) Map.Poly.t;
}
```

**Key Functions:**
- `create_portfolio` - Initialize portfolio
- `add_trade` - Process trade and update positions
- `net_asset_value` - Calculate total NAV
- `total_pnl` - Portfolio-level P&L
- `leverage` - Calculate portfolio leverage
- `position_count` - Number of active positions

**Risk Analytics:**
- `Risk_metrics.calculate_risk_metrics` - VaR, Expected Shortfall
- `calculate_maximum_drawdown` - Historical drawdown analysis
- `portfolio_return` - Return percentage calculation

## Statistical Arbitrage

### Pair (`lib/domain/pairs/pair.ml`)

Trading pairs with statistical relationships:

```ocaml
type pair_relationship =
  | Cointegrated of {
      half_life: float;
      hedge_ratio: float;
      adf_statistic: float;
      p_value: float
    }
  | Correlated of {
      correlation: float;
      rolling_window: int;
      significance_level: float
    }

type pair_state =
  | Normal
  | Diverged of { z_score: float; entry_time: Timestamp.t }
  | Converging of { z_score: float; entry_time: Timestamp.t }
  | Position_open of {
      long_symbol: string;
      short_symbol: string;
      entry_spread: float;
      entry_time: Timestamp.t
    }

type trading_pair = {
  symbol_a: string;
  symbol_b: string;
  relationship: pair_relationship;
  current_state: pair_state;
  spread_series: float list;
  z_score_series: float list;
  entry_threshold: float;
  exit_threshold: float;
  stop_loss_threshold: float;
  lookback_window: int;
}
```

**Key Functions:**
- `create_pair` - Initialize trading pair
- `calculate_spread` - Calculate hedge-ratio adjusted spread
- `calculate_z_score` - Normalize spread to z-score
- `update_pair_data` - Update with new prices
- `should_enter_trade` - Generate entry signals
- `get_trade_signal` - Get long/short recommendations

**Statistical Analysis:**
- `Statistics.calculate_correlation` - Pearson correlation
- `Statistics.calculate_adf_statistic` - Augmented Dickey-Fuller test
- `Statistics.estimate_half_life` - Mean reversion half-life
- `Statistics.johansen_test` - Cointegration testing

## Common Patterns

### Data Validation

All models include validation functions:
```ocaml
let validate_price price =
  if Float.(price <= 0.0) then
    Error "Price must be positive"
  else Ok price

let validate_quantity quantity =
  if Float.(quantity <= 0.0) then
    Error "Quantity must be positive"
  else Ok quantity
```

### Timestamp Management

Consistent timestamp handling across all models:
```ocaml
(* Custom timestamp module for high-precision timing *)
module Timestamp = Algostream_domain_common.Timestamp

let now = Timestamp.now ()
let duration = Timestamp.diff end_time start_time
```

### Immutable Updates

Functional updates preserve data integrity:
```ocaml
let update_position position ~new_price =
  { position with
    last_price = new_price;
    unrealized_pnl = calculate_unrealized_pnl position new_price;
    updated_at = Timestamp.now ();
  }
```

### Error Handling

Comprehensive error handling with Result types:
```ocaml
type 'a result = ('a, string) Result.t

let safe_divide ~numerator ~denominator =
  if Float.(denominator = 0.0) then
    Error "Division by zero"
  else
    Ok (numerator /. denominator)
```

## Performance Considerations

### Memory Efficiency
- Use of OCaml's efficient data structures
- Immutable updates avoid memory leaks
- Map.Poly for efficient key-value lookups

### Computational Efficiency
- Pre-calculated derived values (spreads, P&L)
- Lazy evaluation for expensive calculations
- Optimized mathematical operations

### Type Safety
- Strong typing prevents runtime errors
- Exhaustive pattern matching
- Compile-time validation of business logic

## Testing Patterns

Each domain model includes comprehensive tests:

```ocaml
let test_position_creation () =
  let position = Position.create_position ~symbol:"AAPL" () in
  assert (Float.equal position.quantity 0.0);
  assert (String.equal position.symbol "AAPL")

let test_portfolio_add_trade () =
  let portfolio = Portfolio.create_portfolio ~account_id:"TEST" ~initial_capital:100000.0 in
  let updated = Portfolio.add_trade portfolio ~symbol:"AAPL" ~trade_quantity:100.0 ~trade_price:150.0 ~commission:1.0 () in
  assert (Float.equal updated.cash_balance 84999.0)
```

## Integration Points

### Data Flow
1. **Market Data** → Tick → OrderBook → Asset pricing
2. **Trading** → Order → Trade → Position updates
3. **Portfolio** → Position aggregation → Risk calculations
4. **Pairs** → Statistical analysis → Signal generation

### Event Sourcing
All state changes are captured for audit and replay:
- Order events (created, filled, cancelled)
- Trade events (executed, settled)
- Position events (opened, updated, closed)
- Portfolio events (rebalanced, risk limit hit)

This domain model foundation provides the type-safe, performance-optimized foundation for AlgoStream's trading operations.

---

*For implementation details, see the source code in `lib/domain/` and tests in `test/domain/`.*