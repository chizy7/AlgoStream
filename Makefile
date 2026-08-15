.PHONY: build test bench bench-json replay fmt fmt-check clean \
        deps deps-dev docker-dev docker-shell docker-build \
        perf-record valgrind-massif gprof memtrace help \
        docker-release stack-up stack-down k8s-validate keygen \
        audit-verify backup paced-bench \
        ingest ingest-bench ingest-alloc ingest-live \
        analytics-bench analytics-clock-lint \
        bars ts-bench ts-clock-lint norm-clock-lint \
        pairs-bench pairs-clock-lint \
        adv-bench adv-clock-lint \
        oms-bench oms-clock-lint \
        risk-bench risk-clock-lint \
        sto-bench sto-clock-lint \
        bt-bench bt-clock-lint \
        metrics-bench metrics-clock-lint metrics-dup-lint \
        mc-bench mc-clock-lint \
        opt-clock-lint strategy-clock-lint rng-clock-lint rng-lint \
        backtest fixture determinism-lint \
        site-preview site-build guides \
        dash tel-bench

OCAML_SWITCH ?= 5.1.0
DOCKER_IMAGE  ?= algostream-dev
SITE_PORT    ?= 8000

# ----- Local OCaml workflow -----------------------------------------------

deps:
	opam install . --deps-only --with-test --yes

deps-dev:
	opam install . --deps-only --with-test --with-dev-setup --yes

build:
	opam exec -- dune build

test:
	opam exec -- dune runtest

bench:
	opam exec -- dune exec --profile release bin/benchmark.exe

bench-json:
	opam exec -- dune exec --profile release bin/benchmark.exe -- --json bench_results.json
	@echo "Wrote bench_results.json"

replay:
	@if [ -z "$$LOG" ]; then \
	  echo "Usage: make replay LOG=path/to/log [SPEED=1.0]"; exit 1; \
	fi
	opam exec -- dune exec bin/event_replay.exe -- --log-file $$LOG --speed $${SPEED:-1.0}

# ----- Market data ingestion ------------------------------------

ingest:
	@if [ -z "$$SYMBOLS" ]; then \
	  echo "Usage: make ingest EXCHANGE={binance|coinbase|both} SYMBOLS=BTCUSDT,ETHUSDT [DURATION=60] [PRINT=1]"; exit 1; \
	fi
	opam exec -- dune exec bin/ingest.exe -- \
	  --exchange $${EXCHANGE:-both} \
	  --symbols $$SYMBOLS \
	  --duration $${DURATION:-60} \
	  $${PRINT:+--print-events} \
	  $${LOG_OUTPUT:+--log-output $$LOG_OUTPUT}

ingest-bench:
	opam exec -- dune exec --profile release test/performance/ingestion_throughput.exe -- \
	  --json bench_results.ingestion_throughput.json
	opam exec -- dune exec --profile release test/performance/ingestion_alloc.exe -- \
	  --json bench_results.ingestion_alloc.json

ingest-alloc:
	opam exec -- dune exec --profile release test/performance/ingestion_alloc.exe -- \
	  --json bench_results.ingestion_alloc.json

# ----- Statistical Data Processing ------------------------------

analytics-bench:
	opam exec -- dune exec --profile release test/performance/analytics_throughput.exe -- \
	  --json bench_results.analytics_throughput.json

# ----- Time Series + Normalization ------------------------------

bars:
	@if [ -z "$$LOG" ]; then \
	  echo "Usage: make bars LOG=path/to/log.bin [INTERVAL=1s] [SYMBOL=BTCUSDT]"; exit 1; \
	fi
	opam exec -- dune exec bin/bars.exe -- \
	  --log $$LOG \
	  --interval $${INTERVAL:-1s} \
	  $${SYMBOL:+--symbol $$SYMBOL}

ts-bench:
	opam exec -- dune exec --profile release test/performance/bar_builder_throughput.exe -- \
	  --json bench_results.bar_builder_throughput.json
	opam exec -- dune exec --profile release test/performance/compress_roundtrip.exe -- \
	  --json bench_results.compress_roundtrip.json

ts-clock-lint:
	@if grep -rn 'Clock\.now_\|Unix\.gettimeofday' lib/time_series/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/time_series — must use event time only"; \
	  exit 1; \
	else \
	  echo "OK: no wall-clock leaks in lib/time_series/"; \
	fi

norm-clock-lint:
	@if grep -rn 'Clock\.now_\|Unix\.gettimeofday' lib/normalization/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/normalization — must use event time only"; \
	  exit 1; \
	else \
	  echo "OK: no wall-clock leaks in lib/normalization/"; \
	fi

# Lint guard: lib/analytics must read time only from tick.timestamp_ns (event time)
# so that event_replay.exe is bit-for-bit deterministic across runs.
analytics-clock-lint:
	@if grep -rn 'Clock\.now_\|Unix\.gettimeofday' lib/analytics/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/analytics — analytics must use event time only"; \
	  exit 1; \
	else \
	  echo "OK: no wall-clock leaks in lib/analytics/"; \
	fi

# ----- Pairs Trading Framework -----------------------------------

pairs-bench:
	opam exec -- dune exec --profile release test/performance/pairs_throughput.exe -- \
	  --json bench_results.pairs_throughput.json

pairs-clock-lint:
	@if grep -rn 'Clock\.now_\|Unix\.gettimeofday' lib/pairs/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/pairs — must use event time only"; \
	  exit 1; \
	else \
	  echo "OK: no wall-clock leaks in lib/pairs/"; \
	fi

# ----- Advanced Statistical Models -------------------------------

adv-bench:
	opam exec -- dune exec --profile release test/performance/advanced_models_throughput.exe -- \
	  --json bench_results.advanced_models_throughput.json

adv-clock-lint:
	@if grep -rn 'Clock\.now_\|Unix\.gettimeofday' lib/advanced_models/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/advanced_models — must use event time only"; \
	  exit 1; \
	else \
	  echo "OK: no wall-clock leaks in lib/advanced_models/"; \
	fi

# ----- Order Management System -----------------------------------

oms-bench:
	opam exec -- dune exec --profile release test/performance/order_management_throughput.exe -- \
	  --json bench_results.order_management_throughput.json

oms-clock-lint:
	@if grep -rn 'Clock\.now_\|Unix\.gettimeofday' lib/order_management/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/order_management — must use event time only"; \
	  exit 1; \
	else \
	  echo "OK: no wall-clock leaks in lib/order_management/"; \
	fi

# ----- Risk Management Engine ------------------------------------

risk-bench:
	opam exec -- dune exec --profile release test/performance/risk_management_throughput.exe -- \
	  --json bench_results.risk_management_throughput.json

risk-clock-lint:
	@if grep -rn 'Clock\.now_\|Unix\.gettimeofday' lib/risk_management/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/risk_management — must use event time only"; \
	  exit 1; \
	else \
	  echo "OK: no wall-clock leaks in lib/risk_management/"; \
	fi

# Live smoke against real exchanges. NOT run in CI. Requires network access.
# ----- Monte Carlo backtesting & analytics ----------------------

fixture:
	opam exec -- dune exec test/fixtures/gen/gen_fixture.exe -- $${OUT:-/tmp/algostream_pair.log} $${BARS:-3000}

backtest:
	@if [ -z "$$LOG" ]; then \
	  echo "Usage: make backtest LOG=path/to/log.bin [Y=BTCUSDT] [X=ETHUSDT] [MC=2000]"; \
	  echo "  (run 'make fixture' first for a synthetic log)"; exit 1; \
	fi
	opam exec -- dune exec bin/backtest.exe -- \
	  --log $$LOG --y $${Y:-BTCUSDT} --x $${X:-ETHUSDT} --interval $${INTERVAL:-1m} --fees \
	  $${MC:+--mc-runs $$MC}

sto-bench:
	opam exec -- dune exec --profile release test/performance/rng_throughput.exe -- \
	  --json bench_results.rng_throughput.json

bt-bench:
	opam exec -- dune exec --profile release test/performance/backtest_throughput.exe -- \
	  --json bench_results.backtest_throughput.json

metrics-bench:
	opam exec -- dune exec --profile release test/performance/metrics_throughput.exe -- \
	  --json bench_results.metrics_throughput.json

mc-bench:
	opam exec -- dune exec --profile release test/performance/montecarlo_throughput.exe -- \
	  --json bench_results.montecarlo_throughput.json

# The simulation and analytics layers must read time only from event-time parameters. Stricter
# than the ingestion-side lint in two ways: Timestamp.now is banned as well (the domain mutators now accept ?ts and the
# backtest must always supply it), and the pattern requires a CALL shape so that a doc comment
# naming one of these functions — lib/strategy/strategy.mli explains the rule — does not trip it.
rng-clock-lint:
	@if grep -rn -E 'Clock\.now_[a-z_]+ \(\)|Unix\.gettimeofday \(\)|Timestamp\.now \(\)' lib/rng/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/rng — must be a pure function of its seed"; exit 1; \
	else echo "OK: no wall-clock leaks in lib/rng/"; fi

sto-clock-lint:
	@if grep -rn -E 'Clock\.now_[a-z_]+ \(\)|Unix\.gettimeofday \(\)|Timestamp\.now \(\)' lib/stochastic/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/stochastic — must use event time only"; exit 1; \
	else echo "OK: no wall-clock leaks in lib/stochastic/"; fi

strategy-clock-lint:
	@if grep -rn -E 'Clock\.now_[a-z_]+ \(\)|Unix\.gettimeofday \(\)|Timestamp\.now \(\)' lib/strategy/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/strategy — read time from ctx.ts_ns"; exit 1; \
	else echo "OK: no wall-clock leaks in lib/strategy/"; fi

bt-clock-lint:
	@if grep -rn -E 'Clock\.now_[a-z_]+ \(\)|Unix\.gettimeofday \(\)|Timestamp\.now \(\)' lib/backtest/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/backtest — the engine owns an event clock"; exit 1; \
	else echo "OK: no wall-clock leaks in lib/backtest/"; fi

metrics-clock-lint:
	@if grep -rn -E 'Clock\.now_[a-z_]+ \(\)|Unix\.gettimeofday \(\)|Timestamp\.now \(\)' lib/performance/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/performance — must use event time only"; exit 1; \
	else echo "OK: no wall-clock leaks in lib/performance/"; fi

mc-clock-lint:
	@if grep -rn -E 'Clock\.now_[a-z_]+ \(\)|Unix\.gettimeofday \(\)|Timestamp\.now \(\)' lib/montecarlo/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/montecarlo — runs must be reproducible"; exit 1; \
	else echo "OK: no wall-clock leaks in lib/montecarlo/"; fi

opt-clock-lint:
	@if grep -rn -E 'Clock\.now_[a-z_]+ \(\)|Unix\.gettimeofday \(\)|Timestamp\.now \(\)' lib/optimization/ 2>/dev/null; then \
	  echo "ERROR: wall-clock leak in lib/optimization — searches must be reproducible"; exit 1; \
	else echo "OK: no wall-clock leaks in lib/optimization/"; fi

# The simulation layers must never reach for the legacy generator or a self-seeded one: both
# are irreproducible, and FastRandom additionally correlates nearby seeds. Doc comments that explain
# WHY those are banned are excluded — the .mli files say so deliberately.
rng-lint:
	@found=$$(grep -rn -E 'FastRandom\.[a-z_]+|self_init \(\)' \
	    lib/rng/ lib/stochastic/ lib/backtest/ lib/montecarlo/ lib/optimization/ lib/strategy/ lib/performance/ 2>/dev/null \
	    | grep -v '\[[^]]*FastRandom' | grep -v '\[[^]]*self_init' || true); \
	if [ -n "$$found" ]; then echo "$$found"; \
	  echo "ERROR: Math_utils.FastRandom or Random.self_init used in a simulation layer"; exit 1; \
	else echo "OK: simulation layers use algostream.rng only"; fi

# Stops the metric-duplication count growing further. The allowlist names the known legacy sites; a
# new Sharpe/Sortino/Calmar/max-drawdown definition anywhere else fails the build.
#
# Allowlist rationale:
#   lib/domain/portfolio/portfolio.ml  two Sharpes (different formulas) + a max-drawdown; load-bearing
#                                      for Risk_management.Var.Historical, so not removable here
#   lib/common/utils/math_utils        a third Sharpe and a second max-drawdown in FinancialMath
#   lib/risk_management/drawdown       streaming tracker; a complement, not a duplicate
#   lib/domain/pairs/pair.ml           a THIRD Sharpe formula (per-trade P&L / stdev) and a FOURTH
#                                      max-drawdown (absolute currency over trade P&L). Found by this
#                                      lint on its first run. Zero callers — dead alongside the other
#                                      unused functions in that file
#   lib/optimization/objective.ml      not definitions: these select an existing Metrics field
metrics-dup-lint:
	@found=$$(grep -rn 'let sharpe_ratio\|let sortino\|let calmar\|let max_drawdown\|let calculate_maximum_drawdown' lib/ 2>/dev/null \
	  | grep -v '^lib/performance/' \
	  | grep -v '^lib/domain/portfolio/portfolio.ml' \
	  | grep -v '^lib/common/utils/math_utils' \
	  | grep -v '^lib/risk_management/drawdown' \
	  | grep -v '^lib/domain/pairs/pair.ml' \
	  | grep -v '^lib/optimization/objective.ml' || true); \
	if [ -n "$$found" ]; then \
	  echo "ERROR: a new performance-metric definition appeared outside lib/performance:"; \
	  echo "$$found"; exit 1; \
	else echo "OK: metric definitions are consolidated in lib/performance/"; fi

determinism-lint: rng-clock-lint sto-clock-lint strategy-clock-lint bt-clock-lint metrics-clock-lint mc-clock-lint opt-clock-lint rng-lint metrics-dup-lint
	@echo "Determinism lints passed."


ingest-live:
	@echo "Live smoke test against Binance + Coinbase, 30s..."
	opam exec -- dune exec bin/ingest.exe -- \
	  --exchange both --symbols BTCUSDT --duration 30 --print-events

fmt:
	opam exec -- dune build @fmt --auto-promote

fmt-check:
	opam exec -- dune build @fmt

clean:
	opam exec -- dune clean
	rm -f bench_results.json perf.data perf.data.old massif.out.* gmon.out trace.ctf

# ----- Docker dev workflow ------------------------------------------------

docker-build:
	docker compose build

docker-dev: docker-build
	docker compose up -d
	@echo "Container 'dev' is up. Use 'make docker-shell' to enter."

docker-shell:
	docker compose exec dev bash

# ----- Production image and the observability stack -----------------------

# Distinct from docker-build, which builds the *dev* profiling shell.
docker-release:
	docker build -f Dockerfile -t algostream:latest .

# Brings up the daemon plus Prometheus, Grafana and Alertmanager. Generates a keystore and a
# read-scoped scrape key first if they are absent — Prometheus will not start without the key file,
# and the token must have no trailing newline or every scrape 401s.
stack-up: docker-release
	@mkdir -p secrets
	@if [ ! -f secrets/keys.json ]; then \
		echo "generating a keystore in ./secrets"; \
		opam exec -- dune exec bin/keyctl.exe -- add --file secrets/keys.json --label operator --scopes read,control; \
		opam exec -- dune exec bin/keyctl.exe -- add --file secrets/keys.json --label prometheus --scopes read \
			| awk '/^key:/{printf "%s", $$2}' > secrets/algostream.key; \
		chmod 600 secrets/keys.json secrets/algostream.key; \
	fi
	docker compose -f docker-compose.prod.yml up -d
	@echo
	@echo "  dashboard    http://127.0.0.1:8080/dashboard/"
	@echo "  prometheus   http://127.0.0.1:9090"
	@echo "  grafana      http://127.0.0.1:3000"
	@echo "  alertmanager http://127.0.0.1:9093"

stack-down:
	docker compose -f docker-compose.prod.yml down

# Offline schema validation. kubectl --dry-run=client needs a live API server for schema checks,
# so kubeconform is the tool that actually works without a cluster.
k8s-validate:
	docker run --rm -v "$(PWD)/k8s:/mnt:ro" ghcr.io/yannh/kubeconform:latest \
		-strict -summary /mnt/deployment.yaml /mnt/service.yaml
	docker run --rm -v "$(PWD)/monitoring/prometheus:/mnt:ro" \
		--entrypoint promtool prom/prometheus:v2.53.0 check rules /mnt/rules/algostream.rules.yml

# ----- Security and audit -------------------------------------------------

# The key is printed once and never stored; only its hash goes into the keystore.
keygen:
	@opam exec -- dune exec bin/keyctl.exe -- add --label "$${LABEL:-operator}" --scopes "$${SCOPES:-read,control}"

audit-verify:
	@if [ -z "$$DIR" ]; then echo "usage: make audit-verify DIR=path/to/audit"; exit 2; fi
	opam exec -- dune exec bin/auditctl.exe -- verify "$$DIR"

backup:
	@if [ -z "$$DIR" ]; then echo "usage: make backup DIR=path/to/audit [OUT=./backups]"; exit 2; fi
	AUDITCTL=$(PWD)/_build/default/bin/auditctl.exe ./scripts/backup.sh --audit-dir "$$DIR" --out "$${OUT:-./backups}"

# ----- Profiling (Linux container or Linux host) --------------------------

# Latency at a stated offered load, which is the figure the 5ms target is about. The other latency
# bench saturates the bus on purpose and reports queueing delay; do not compare the two.
paced-bench: build
	opam exec -- dune exec test/performance/event_bus_paced_latency.exe -- --rate $${RATE:-50000} --seconds $${SECONDS:-4}


perf-record: build
	./scripts/perf_record.sh

valgrind-massif: build
	./scripts/valgrind_massif.sh

gprof:
	@echo "gprof requires building with -p flag; not yet wired into dune profile"
	@echo "Use perf-record or valgrind-massif instead for now"

memtrace:
	@if [ -z "$$BIN" ]; then \
	  echo "Usage: make memtrace BIN=bin/algostream.exe [ARGS=...]"; exit 1; \
	fi
	MEMTRACE=trace.ctf opam exec -- dune exec $$BIN -- $$ARGS
	@echo "Wrote trace.ctf — view with: memtrace-viewer trace.ctf"

# ----- Dashboard, telemetry, live runtime ----------------------------------

# Run the daemon with the dashboard. Paper trading only; the API is unauthenticated and
# loopback-bound. Use LOG=... to replay a recorded log instead of connecting to live feeds.
dash:
	opam exec -- dune exec bin/algostream.exe -- \
	  $${LOG:+--replay $$LOG} $${SPEED:+--speed $$SPEED} \
	  --y $${Y:-BTCUSDT} --x $${X:-ETHUSDT} --capital $${CAPITAL:-100000} \
	  --http-port $${PORT:-8080} --static site

tel-bench:
	opam exec -- dune exec --profile release test/performance/telemetry_throughput.exe -- \
	  --json bench_results.telemetry_throughput.json

# ----- Site and docs -------------------------------------------------------
# site/ is published to the gh-pages branch root by .github/workflows/pages.yml.
# The benchmark dashboard reads dev/bench/data.js, which lives only on
# gh-pages — site-build pulls a copy in so the page has data locally.

guides:
	@python3 scripts/gen-guides.py --out _site
	@python3 scripts/check-guides.py _site

site-build:
	@rm -rf _site
	@mkdir -p _site/assets _site/dev/bench
	@cp site/index.html       _site/index.html
	@cp -R site/assets/.      _site/assets/
	@mkdir -p _site/dashboard
	@cp -R site/dashboard/.   _site/dashboard/
	@# Guides are generated from docs/guides/*.md — never hand-edited.
	@python3 scripts/gen-guides.py --out _site --quiet
	@python3 scripts/check-guides.py _site
	@# Everything in site/bench/ except data.js, which is fetched below.
	@rsync -a --exclude 'data.js' site/bench/ _site/dev/bench/
	@if git cat-file -e origin/gh-pages:dev/bench/data.js 2>/dev/null; then \
	  git show origin/gh-pages:dev/bench/data.js > _site/dev/bench/data.js; \
	  echo "pulled dev/bench/data.js from origin/gh-pages"; \
	else \
	  echo "note: origin/gh-pages:dev/bench/data.js not found — the dashboard"; \
	  echo "      will render its empty state. Run: git fetch origin gh-pages"; \
	fi
	@echo "Built _site/"

site-preview: site-build
	@echo "Serving _site/ on http://localhost:$(SITE_PORT)/  (Ctrl-C to stop)"
	@cd _site && python3 -m http.server $(SITE_PORT)

help:
	@echo "AlgoStream Makefile targets"
	@echo "  build           dune build"
	@echo "  test            dune runtest"
	@echo "  bench           run benchmark suite (text output)"
	@echo "  bench-json      run benchmarks, emit bench_results.json"
	@echo "  replay LOG=...  replay an event log via bin/event_replay.exe"
	@echo "  fmt             dune build @fmt --auto-promote"
	@echo "  fmt-check       dune build @fmt (CI-style check)"
	@echo "  deps            opam install --deps-only --with-test"
	@echo "  deps-dev        opam install --deps-only --with-test --with-dev-setup"
	@echo "  docker-build    docker compose build"
	@echo "  docker-dev      bring up the dev container"
	@echo "  docker-shell    bash into the running dev container"
	@echo "  docker-release  build the production image (non-root, no sudo)"
	@echo "  stack-up        daemon + prometheus + grafana + alertmanager"
	@echo "  stack-down      tear the stack down"
	@echo "  k8s-validate    kubeconform + promtool, offline"
	@echo "  keygen          mint an API key (LABEL=, SCOPES=)"
	@echo "  audit-verify    verify the audit chain (DIR=)"
	@echo "  backup          verify then archive the audit log (DIR=, OUT=)"
	@echo "  paced-bench     latency at a stated load (RATE=, SECONDS=)"
	@echo "  perf-record     run perf record against the benchmark binary"
	@echo "  valgrind-massif heap profile event_replay with massif"
	@echo "  memtrace BIN=...  run BIN under memtrace, writing trace.ctf"
	@echo "  ingest EXCHANGE=... SYMBOLS=...  start ingestion CLI (offline if no net)"
	@echo "  ingest-bench    run ingestion throughput + alloc benches"
	@echo "  ingest-live     30s smoke test against live Binance + Coinbase (needs net)"
	@echo "  analytics-bench run analytics direct + bus throughput bench"
	@echo "  analytics-clock-lint  fail if lib/analytics references wall-clock"
	@echo "  pairs-bench     run pairs direct + bus throughput bench"
	@echo "  pairs-clock-lint  fail if lib/pairs references wall-clock"
	@echo "  adv-bench       run advanced models throughput bench (Kalman+GARCH+PCA)"
	@echo "  adv-clock-lint  fail if lib/advanced_models references wall-clock"
	@echo "  oms-bench       run order management throughput bench (routing+book_impact+kelly)"
	@echo "  oms-clock-lint  fail if lib/order_management references wall-clock"
	@echo "  risk-bench      run risk management throughput bench (VaR + drawdown + monitor)"
	@echo "  risk-clock-lint fail if lib/risk_management references wall-clock"
	@echo "  fixture         write a synthetic two-leg event log (OUT=, BARS=)"
	@echo "  backtest LOG=... run the pairs strategy over a log (Y=, X=, MC=)"
	@echo "  sto-bench       RNG + variate throughput"
	@echo "  bt-bench        backtest engine throughput (frictionless/fees/book)"
	@echo "  metrics-bench   performance-analytics throughput"
	@echo "  mc-bench        Monte Carlo throughput and measured parallel speedup"
	@echo "  determinism-lint  all clock, RNG and metric-duplication lints"
	@echo "  clean           dune clean + remove profiling artifacts"
	@echo "  site-build      assemble _site/ (site/ + data.js from origin/gh-pages)"
	@echo "  site-preview    serve _site/ on localhost:$(SITE_PORT)"
	@echo "  guides          generate + verify the doc pages from docs/guides/*.md"
	@echo "  dash            run the daemon + dashboard (LOG= to replay, PORT=)"
	@echo "  tel-bench       telemetry histogram + collector overhead"
