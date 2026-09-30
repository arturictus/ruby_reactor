# Quickstart: Reproducing & Validating the Analysis

## Prerequisites

- Ruby per `.tool-versions`, `bundle install` done at repo root.
- Test Redis reachable. Default `redis://localhost:6780`, the same one the spec suite uses:

  ```sh
  docker run -d --name rr-test-redis -p 6780:6379 redis:7-alpine   # if not already running
  # or: export RUBY_REACTOR_TEST_REDIS_URL=redis://localhost:6379
  ```

  Probes call `FLUSHDB` on that Redis between scenarios, like the spec suite's storage reset.
  **Do not point them at a Redis holding data you care about.**

## Run the probes

```sh
bundle exec ruby specs/007-execution-flow-analysis/evidence/run.rb \
  | tee specs/007-execution-flow-analysis/evidence/output.txt
```

Optional filter: `PROBE=map bundle exec ruby …/run.rb` runs only scenario ids containing `map`.

**Expected outcome**: every block ends in `MATCH`. The tail line prints
`N scenarios, N match, 0 mismatch`. If a block says `MISMATCH`, behavior has drifted from the
report: fix the report (observation wins, see contracts/report-structure.md).

## Validate the report

```sh
cd specs/007-execution-flow-analysis
# 1. No unfilled matrix cells / placeholders (the report quotes the source's
#    own `# TODO` comment in MapStep, so TODO is not a placeholder marker here)
grep -nE 'TBD|\?\?\?|\[fill' analysis/*.md            # expect: no output
# 2. Every scenario id cited in the report resolves to a probe block
ID='S-(plain|compose|map|async|bg|lock|retry|intr|edge)-[0-9]+[a-z]?'
grep -ohE "$ID" analysis/*.md | sort -u > /tmp/cited
grep -oE "^== $ID" evidence/output.txt | sed 's/== //' | sort -u > /tmp/run
comm -23 /tmp/cited /tmp/run                          # expect: no output
# 3. Zero product diff
git diff --stat main -- lib spec demo_app README.md documentation   # expect: empty
```

## Scenarios that prove the headline answers

| Question | Scenario ids (see analysis/README.md) |
|---|---|
| Q1 map elements rollback | `S-map-*` |
| Q2 earlier composed reactors rollback | `S-compose-*` |
| Q3 map compensate_all / each gap | `S-map-*` + findings-and-options.md |
