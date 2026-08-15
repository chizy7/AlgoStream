# Contributing to AlgoStream

Thank you for your interest in contributing to AlgoStream! This document provides guidelines and information for contributors.

## Project Overview

AlgoStream is a high-performance algorithmic trading platform built with OCaml, featuring:
- Sub-5ms execution latency
- Statistical arbitrage capabilities
- Monte Carlo backtesting with 10,000+ simulations
- Processing 50,000+ market events per second
- Advanced risk management and real-time analytics

## Development Environment Setup

### Prerequisites
- OCaml 5.1.x recommended; 5.0.x supported. The project uses `Domain`, so 4.x will not build it.
- OPAM package manager
- Git

### Setup Instructions
```bash
# Clone the repository
git clone https://github.com/chizy7/algostream.git
cd algostream

# Create local OPAM switch
opam switch create . ocaml-base-compiler.5.1.1
eval $(opam env)

# Install dependencies
opam install . --deps-only --with-test --with-dev-setup

# Build the project
dune build

# Run tests
dune runtest
```

## Code Style and Standards

### OCaml Style Guidelines
- Follow the project's `.ocamlformat` configuration
- Use meaningful variable and function names
- Prefer immutable data structures
- Include comprehensive documentation for public APIs
- `Base` and `Stdio` are available; `Core` is not a dependency

### Performance Requirements
- Critical paths must maintain sub-5ms latency requirements
- Use profiling tools to validate performance impacts
- Prefer lock-free data structures in high-frequency components
- Minimize memory allocations in hot paths

### Code Formatting
```bash
# Format all OCaml files
dune build @fmt --auto-promote

# Check formatting
dune build @fmt
```

## Testing

### Test Requirements
- All new features must include comprehensive unit tests
- Performance-critical components require benchmarks
- Integration tests for end-to-end workflows
- New code needs tests; there is no coverage tool wired up, so use judgement rather than a number

### Running Tests
```bash
# Run all tests
dune runtest

# Run one suite — each test directory builds a test_runner
dune exec test/domain/test_runner.exe
dune exec test/pairs/test_runner.exe

# Performance benchmarks
make bench
make paced-bench
```

## Contribution Process

### 1. Issue Discussion
- Check existing issues before creating new ones
- For major features, create an issue to discuss the approach
- Use issue templates for bug reports and feature requests

### 2. Development Workflow
```bash
# Create feature branch
git checkout -b feature/statistical-arbitrage-enhancement

# Make changes with clear, focused commits
git commit -m "Add cointegration testing for pairs trading

- Implement Engle-Granger cointegration test
- Add Johansen test for multiple time series
- Include statistical significance validation
- Add comprehensive unit tests with edge cases"

# Push branch
git push origin feature/statistical-arbitrage-enhancement
```

### 3. Pull Request Guidelines
- Use the pull request template
- Include clear description of changes
- Reference related issues
- Ensure all tests pass
- Update documentation as needed

### Pull Request Checklist
- [ ] Tests pass (`dune runtest`)
- [ ] Code is formatted (`dune build @fmt`)
- [ ] Documentation updated
- [ ] Performance benchmarks run (for performance-critical changes)
- [ ] CHANGELOG.md updated
- [ ] No breaking changes without version bump discussion

## Code Organization

### Module Structure
```
lib/                     # All library code
├── common/              # Shared utilities, lock-free structures, timing
├── domain/              # Domain models — orders, trades, portfolio, pairs
├── infrastructure/      # Event bus, Lwt host, HTTP/SSE, auth, audit log
├── data_ingestion/      # Exchange connectors and the ingestion supervisor
├── analytics/ pairs/    # Statistics and cointegration
├── strategy/ backtest/  # The strategy contract and the simulator
├── runtime/             # Live runner, simulated execution
└── telemetry/           # Metrics, health, alerting

bin/                     # Executables — daemon, keyctl, auditctl, backtest, benchmark
test/                    # One directory per library, each with a test_runner
```

### Component Guidelines
- **Data Ingestion**: Focus on throughput and reliability
- **Statistical Models**: Emphasize mathematical accuracy
- **Execution**: Prioritize latency optimization
- **Risk Management**: Ensure comprehensive validation

## Performance Considerations

### Latency Requirements
- Order execution: < 5ms end-to-end
- Market data processing: < 1ms per event
- Risk calculations: < 2ms for position updates

### Benchmarking
```bash
# Run performance benchmarks
dune exec bin/benchmark.exe

# Profile specific components
perf record -g dune exec bin/algostream.exe
perf report
```

## Documentation

### API Documentation
- Use OCaml documentation comments
- Include usage examples
- Document performance characteristics
- Specify error conditions

### Mathematical Models
- Document algorithms with references to academic papers
- Include implementation details and assumptions
- Provide validation test cases

## Security Considerations

### Financial Data
- Never commit real trading credentials
- Use placeholder data in tests
- Sanitize logs of sensitive information
- Follow secure coding practices

### Code Review Focus
- Validate mathematical correctness
- Check for potential race conditions
- Verify error handling completeness
- Assess performance impact

## Communication

### Getting Help
- GitHub Issues for bugs and feature requests  
- GitHub Discussions for questions and ideas
- Code reviews for implementation feedback

### Reporting Issues
- **Security Issues**: Report privately via email
- **Bug Reports**: Use GitHub issue templates
- **Feature Requests**: Include use case and requirements

## Recognition

Contributors are recognized in:
- CHANGELOG.md for significant contributions
- README.md contributors section
- GitHub contributor insights

## License

By contributing to AlgoStream, you agree that your contributions will be licensed under the [MIT License](LICENSE).

## Questions?

If you have questions about contributing, please open a GitHub Discussion or contact the maintainers.

Thank you for helping make AlgoStream a world-class algorithmic trading platform!