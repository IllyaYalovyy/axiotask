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
- API keys or tokens
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
  .ktask/

If any of these are accidentally staged, unstage them before committing.

Design Process

An RFC (designs/RFC-000-template.md) is REQUIRED for:
- Any feature touching >3 files or introducing new abstractions
- New external dependencies
- Changes to the data model or API surface
- Architectural decisions that are hard to reverse

Do not begin implementation until the RFC reaches Accepted.

Versioning

axiotask follows Semantic Versioning (https://semver.org). The version starts
at 0.1.0 and is shown to users in the About dialog.

The version is declared in exactly ONE place:

  pubspec.yaml    # version: X.Y.Z+B (B = build number, bump with every version change)

Bump the version on EVERY change that is merged (ruled 2026-09-07). A merge
without a version bump is incomplete work — the release pipeline tags and
publishes from the pubspec version, so two different builds must never carry
the same version.

- Patch (X.Y.Z+1) — bug fixes, small tweaks, tests-only or tooling changes
- Minor (X.Y+1.0) — new user-facing features
- Major (X+1.0.0) — breaking changes to data or behaviour

The build number B increments with every version change. The AppStream
metainfo (linux/packaging/*.metainfo.xml) gets a matching <release> entry for
every minor and major version; patch versions update the newest entry's
version attribute. 1.0.0 is the first release (2026-09-07); there is no
pre-1.0 reservation any more.

Push Policy

Do not push to remote unless explicitly instructed.
All work stays local until a deliberate decision to publish.
