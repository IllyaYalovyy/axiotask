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

Push Policy

Do not push to remote unless explicitly instructed.
All work stays local until a deliberate decision to publish.
