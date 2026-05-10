# Contributing

Thanks for your interest in improving kiosk-monitor.

## How to Contribute

1. Fork the repo and create a topic branch.
2. Keep PRs small and focused; one change per PR.
3. Run local checks before pushing:
   - `bash -n kiosk-monitor.sh` — syntax
   - `shellcheck -x -S warning kiosk-monitor.sh` — lint (zero findings expected at warning+ level)
   - `tests/run.sh` — bash test harness (no external dependencies beyond `python3` for one round-trip case)
4. Keep docs (README / examples) in sync with behaviour visible to users.
5. GitHub Actions runs the same checks; ensure they pass before requesting review.

## Test harness

The `tests/` directory contains a minimal bash test harness — pure bash,
no BATS / pytest / external runners. Two patterns:

- **Pure-function tests** extract individual helpers from
  `kiosk-monitor.sh` via `load_function NAME` and call them in the test
  shell. The script's main flow never runs.
- **Integration tests** invoke the script as a subprocess via
  `run_kiosk ...` and inspect captured stdout/stderr/exit.

Add a new test by creating `tests/test_<area>.sh`, sourcing
`tests/lib.sh`, and using the `assert_*` helpers. Each test file
prints a per-file summary and exits non-zero on first failure;
`tests/run.sh` aggregates per-file results across the whole directory.

```bash
tests/run.sh                       # all tests, summary-only
VERBOSE=1 tests/run.sh             # show every PASS line
tests/run.sh test_url_*.sh         # subset (passes globs through)
```

Verified two-platform: macOS arm64 / bash 5.3 (workstation), Raspberry
Pi 5 aarch64 / bash 5.2 (production target). All 57 cases pass on
both as of v6.9.2.

## Reporting Issues

Open an issue with:
- Expected vs actual behavior
- Steps to reproduce

## Security

Please do not file public issues for vulnerabilities. See `SECURITY.md`.
