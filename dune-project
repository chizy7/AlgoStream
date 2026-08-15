(lang dune 3.16)

(name algostream)

(generate_opam_files true)

(map_workspace_root false)

(source (github chizy7/AlgoStream))

(authors "Chizaram Chibueze <chizy@chizyhub.com>")

(maintainers "Chizaram Chibueze <chizy@chizyhub.com>")

(license MIT)

(documentation "https://github.com/chizy7/AlgoStream")

(homepage "https://github.com/chizy7/AlgoStream")

(bug_reports "https://github.com/chizy7/AlgoStream/issues")

(package
 (name algostream)
 (synopsis "High-performance algorithmic trading platform with statistical arbitrage")
 (description "AlgoStream is a production-grade algorithmic trading system built with OCaml, featuring sub-5ms execution latency, statistical arbitrage capabilities, Monte Carlo backtesting with 10,000+ simulations, and processing 50,000+ market events per second. Designed for quantitative trading with advanced risk management and real-time analytics.")
 (depends
  (ocaml (>= 5.0.0))
  dune
  ; Core libraries
  (lwt (>= 5.7.0))
  (cohttp-lwt-unix (>= 5.0.0))
  (conduit-lwt-unix (>= 6.2.0))
  (base (>= v0.16.0))
  (stdio (>= v0.16.0))

  ; JSON and serialization
  (yojson (>= 2.0.0))
  (bin_prot (>= v0.16.0))
  (ppx_bin_prot (>= v0.16.0))
  (ppx_jane (>= v0.16.0))

  ; Market data ingestion (WebSocket + TLS)
  (websocket-lwt-unix (>= 2.16))
  (tls-lwt (>= 0.17.0))
  (uri (>= 4.4.0))

  ; Time and logging
  (logs (>= 0.7.0))

  ; Credentials and the audit chain. Both arrive transitively via tls-lwt, which is
  ; exactly why they are declared explicitly: a build that compiles only because something else
  ; happened to pull in its dependencies breaks the moment that other thing changes.
  (digestif (>= 1.1.0))
  (mirage-crypto-rng (>= 1.0.0))

  ; Peer address for audit records
  (ipaddr (>= 5.0.0))

  ; Memory profiling
  (memtrace (>= 0.2.3))

  ; Filter expression parsing for event-bus replay CLI
  (re (>= 1.10.0))

  ; Testing
  (alcotest :with-test)

  ; Development tools
  (ocaml-lsp-server :with-dev-setup)
  (ocamlformat (and :with-dev-setup (= 0.27.0)))
  (utop :with-dev-setup)))

(using menhir 2.1)

(formatting
 (enabled_for ocaml reason dune))
