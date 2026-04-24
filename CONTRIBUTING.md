# Contributing

Thanks for your interest in improving kiosk-monitor.

## How to Contribute

1. Fork the repo and create a topic branch.
2. Keep PRs small and focused; one change per PR.
3. Run basic checks locally: `bash -n kiosk-monitor.sh` and `shellcheck -x -S warning kiosk-monitor.sh`.
4. Keep docs (README / examples) in sync with behaviour visible to users.
5. GitHub Actions runs the same lint checks; ensure they pass before requesting review.

## Reporting Issues

Open an issue with:
- Expected vs actual behavior
- Steps to reproduce

## Security

Please do not file public issues for vulnerabilities. See `SECURITY.md`.
