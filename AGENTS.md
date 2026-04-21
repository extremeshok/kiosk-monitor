# Contributor / Agent guidelines

## Branding

**No AI-agent / coding-assistant branding, attribution, or mention.** This applies everywhere:

- Source code (shell, Python, JS, etc.) — no AI tool names in comments, banners, or identifiers.
- Commit messages — no `Co-Authored-By: Claude …`, no `Generated with …`, no emoji tags or tool signatures.
- Pull request / issue text — no "created with", "authored by", "with the help of", etc.
- Documentation (README, CHANGELOG, release notes) — project and human author credits only.
- Config files, error messages, log lines, user-facing strings.

Specifically prohibited (non-exhaustive): Claude, Anthropic, Claude Code, ChatGPT, OpenAI, GitHub Copilot, Copilot, Gemini, Codeium, Cursor, Devin, Replit Agent, Aider, v0, any "AI assistant"/"coding agent" phrasing.

When automated tooling would otherwise add such attribution, strip it before committing / opening PRs.

## Commit / PR style

- Commit messages stay focused on the change and its reason. No trailing attribution footer.
- PR descriptions: describe the change and its motivation. No "generated with" lines.

## Project scope

- Target platform: **Raspberry Pi OS trixie 64-bit Desktop** (Debian 13) or newer. Drop compatibility shims for older distros when touching code paths they no longer exercise.
- Wayland + labwc only; no X11 fallbacks.
- Prerequisites (chromium, vlc, grim, wlr-randr, curl, python3) are part of the stock trixie desktop image — don't add install steps for them.

## Style

- Keep `kiosk-monitor.sh` passing `bash -n` and `shellcheck -x -S warning`.
- No new comments that just describe what the code does; reserve comments for non-obvious "why".
- User-facing log lines prefix with `[<id> <mode>@<output>]` via `log_instance`.
