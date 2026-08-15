## What this changes

<!-- One or two sentences. If it fixes an issue, "Fixes #123". -->

## Why

<!-- The reasoning, not a restatement of the diff. If a measurement drove the
     change, give the before and after numbers. -->

## Checklist

- [ ] `dune runtest` passes (709 cases across 25 suites)
- [ ] `dune build @fmt` is clean
- [ ] New behaviour has tests; a bug fix has a test that failed before it
- [ ] Docs updated if the change is user-visible (`docs/guides/`)
- [ ] `CHANGELOG.md` updated for anything notable
- [ ] Benchmarks run if this touches the hot path (`make bench` / `make paced-bench`)

## Notes for the reviewer

<!-- Anything that isn't obvious from the diff: a tradeoff you took, a limitation
     you're aware of, an alternative you rejected. Honest limitations are more
     useful here than claims. -->
