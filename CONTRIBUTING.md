Contributing Rules

Git Identity

All commits MUST use:

  Name:  Illya Yalovyy
  Email: yalovoy@gmail.com

Before starting work, verify:

  git config user.name   # must be "Illya Yalovyy"
  git config user.email  # must be "yalovoy@gmail.com"

NEVER commit with any other identity (corporate, noreply, etc).

Sensitive Data

NEVER commit:
- File paths containing usernames, home directories, or machine names
- Corporate email addresses or internal hostnames
- API keys or tokens (except the embedded OAuth client ID/secret which is intentionally public)
- Any reference to the development machine's filesystem structure

AI / Agent Files

The following MUST be in .gitignore and MUST NEVER be committed:

  .claude/
  .claude_*
  .kiro/
  .aim/
  .cursor/
  .copilot/
  .aider*
  .codex/
  .tabnine/
  .continue/
  .windsurf/
  *.prompt
  *.prompt.md
  .chat_history/
  .ai/
  .agent/

If any of these are accidentally staged, unstage them before committing.

Versioning

axiotask follows Semantic Versioning (https://semver.org). The version starts
at 0.1.0 and is shown to users in the About dialog.

The version is declared in three places that MUST stay in sync. The workspace
Cargo.toml is the source of truth:

  Cargo.toml                              # workspace.package.version (source of truth)
  crates/axiotask-app/tauri.conf.json     # version
  crates/axiotask-app/ui/package.json     # version

Bump the version on every big change, then update all three files together:

- Patch (0.1.X) — bug fixes and small tweaks
- Minor (0.X.0) — new user-facing features
- Major (X.0.0) — breaking changes (reserved while pre-1.0; stays 0.x)

The tests in crates/axiotask-app/tests/version_consistency.rs fail if the three
versions drift apart, so a partial bump is caught by `cargo test`.

Push Policy

Do not push to remote unless explicitly instructed.
All work stays local until a deliberate decision to publish.
