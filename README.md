# axiotask

A keyboard-driven desktop client for Google Tasks. Native, fast, offline-first.

Built with [Tauri 2](https://tauri.app/) (Rust backend) and [Svelte 5](https://svelte.dev/) (frontend).

## Features

- **Keyboard-first** — every action reachable without a mouse (j/k navigate, Enter edits, d deletes, t/w/m/r reschedule)
- **Offline-first** — tasks cached locally in SQLite, sync in background
- **Smart views** — Focus (this week), Upcoming, Missed, Unscheduled
- **One-click reschedule** — tomorrow, next week, next month buttons on every task
- **Flat task list** — subtasks shown in detail panel, not cluttering the main view
- **Reorderable lists** — drag lists in the sidebar into your own order (saved per instance)
- **Cross-platform** — Linux, macOS, Windows from a single codebase

## Recurring tasks

Google's Tasks REST API exposes **no** recurrence field — `tasks.get`/`tasks.list`
never return a repeat rule, even for tasks that repeat, and there is no way to
read or set recurrence through the public API (tracked upstream at
[issuetracker.google.com/166896024](https://issuetracker.google.com/issues/166896024)).

axiotask therefore does not implement its own recurrence. Instead, every task
links straight to its page in the Google Tasks web app (the **Open in Google
Tasks** button in the detail panel), where you can set or change a repeat rule.
Recurrence stays owned by Google, the single source of truth.

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Rust | 1.85+ | `rustup update stable` |
| Node.js | 18+ | For the Svelte frontend |
| npm | 9+ | Comes with Node.js |
| Tauri CLI | 2.x | `cargo install tauri-cli` |

### Linux system dependencies

Tauri requires system libraries for WebView and window management:

```bash
# Debian/Ubuntu
sudo apt install libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf libssl-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev

# Fedora
sudo dnf install webkit2gtk4.1-devel libappindicator-gtk3-devel librsvg2-devel openssl-devel libsoup3-devel

# Arch
sudo pacman -S webkit2gtk-4.1 libappindicator-gtk3 librsvg openssl libsoup3
```

### macOS

Xcode Command Line Tools are required:

```bash
xcode-select --install
```

### Windows

Install [Visual Studio Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/) with the "Desktop development with C++" workload, plus WebView2 (included in Windows 10/11).

## Setup

### 1. Clone and install frontend dependencies

```bash
git clone https://github.com/yalovoy/axiotask.git
cd axiotask
cd crates/axiotask-app/ui
npm install
cd ../../..
```

### 2. Configure Google OAuth credentials

axiotask uses Google's Tasks API via OAuth 2.0. You need to create credentials:

1. Go to [Google Cloud Console → APIs & Credentials](https://console.cloud.google.com/apis/credentials)
2. Create a project (or select an existing one)
3. Enable the **Google Tasks API** under "APIs & Services → Library"
4. Create an **OAuth 2.0 Client ID** with application type **Desktop app**
5. Copy the Client ID and Client Secret

Then create the config file:

```bash
mkdir -p ~/.config/axiotask
cat > ~/.config/axiotask/config.toml << 'EOF'
[google]
client_id = "YOUR_CLIENT_ID.apps.googleusercontent.com"
client_secret = "YOUR_CLIENT_SECRET"
scopes = ["https://www.googleapis.com/auth/tasks"]

[sync]
push_enabled = false
auto_sync_on_start = true
EOF
```

> **Note:** The app works fully offline without credentials — you just won't be able to sync with Google. A default config is auto-created on first launch if none exists.

## Building

### Development (with hot reload)

```bash
cd crates/axiotask-app
cargo tauri dev
```

This starts the Vite dev server for the frontend and the Tauri app with hot reloading.

### Production build

```bash
cd crates/axiotask-app
cargo tauri build
```

The binary is output to `target/release/axiotask`.

### Backend only (no UI)

```bash
cargo build          # debug
cargo build --release  # optimized
```

## Running Tests

```bash
# Rust tests (core logic + Tauri commands)
cargo test

# Frontend tests (Vitest + testing-library)
cd crates/axiotask-app/ui
npm test

# Lint
cargo clippy
```

## Project Structure

```
axiotask/
├── crates/
│   ├── axiotask-core/         # Pure Rust: auth, API client, SQLite store, sync engine
│   │   └── src/
│   │       ├── api/           # Google Tasks API client (trait + HTTP + in-memory test double)
│   │       ├── auth/          # OAuth 2.0 PKCE flow, token store
│   │       ├── store/         # SQLite repository, sync state tracking
│   │       ├── sync/          # Pull/push sync engine
│   │       ├── config.rs      # App configuration (TOML)
│   │       ├── dates.rs       # Date arithmetic for reschedule
│   │       └── model.rs       # Domain types (Task, TaskList, etc.)
│   └── axiotask-app/          # Tauri desktop app
│       ├── src/
│       │   ├── commands.rs    # IPC commands exposed to frontend
│       │   ├── state.rs       # App state management
│       │   └── main.rs        # Tauri bootstrap
│       └── ui/                # Svelte 5 frontend
│           └── src/
│               ├── App.svelte         # Main app shell
│               ├── Sidebar.svelte     # List navigation + smart views
│               ├── TaskRow.svelte     # Task widget with metadata
│               ├── TaskDetail.svelte  # Detail panel
│               └── __tests__/         # Vitest component tests
├── designs/                   # UX design docs and RFCs
├── Cargo.toml                 # Workspace root
└── VISION.md                  # Product vision
```

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `j` / `k` | Move focus down / up |
| `Enter` | Open task detail panel |
| `e` | Inline edit task title |
| `n` | Quick-add new task |
| `d` | Delete task |
| `Space` | Toggle complete |
| `t` | Due tomorrow |
| `w` | Due next week |
| `m` | Due next month |
| `r` | Remove due date |
| `Ctrl+M` | Move to list picker |
| `/` | Focus quick-add |
| `?` | Show keyboard cheatsheet |
| `Escape` | Close panel / cancel |
| `Alt+↑/↓` | Reorder task |

## Configuration

Config file location: `~/.config/axiotask/config.toml`

```toml
[google]
client_id = ""
client_secret = ""
scopes = ["https://www.googleapis.com/auth/tasks"]

[sync]
# Push local changes to Google (disabled by default for safety)
push_enabled = false
# Auto-sync on app startup when authenticated
auto_sync_on_start = true
# EXPERIMENTAL: drop the local cache and re-pull everything from Google on the
# next sync. Disabled by default; behavior may change.
full_sync_enabled = false
```

## Data Storage

- **Database:** `~/.local/share/axiotask/axiotask.db` (SQLite)
- **Auth tokens:** OS keychain (macOS Keychain / Windows Credential Manager / Linux Secret Service) or fallback to `~/.config/axiotask/tokens.json`
- **Config:** `~/.config/axiotask/config.toml`

## Multiple isolated instances

You can run a separate, fully isolated instance alongside your normal one — for
example a `dev` instance to test against throwaway data while your real account
keeps running. Set `AXIOTASK_PREFIX` to a short name when launching:

```bash
AXIOTASK_PREFIX=dev axiotask
```

That instance namespaces **everything** under `axiotask-<prefix>` instead of
`axiotask`:

| Resource | Default | `AXIOTASK_PREFIX=dev` |
|----------|---------|------------------------|
| Config | `~/.config/axiotask/config.toml` | `~/.config/axiotask-dev/config.toml` |
| Database | `~/.local/share/axiotask/axiotask.db` | `~/.local/share/axiotask-dev/axiotask.db` |
| Auth tokens | `~/.local/share/axiotask/tokens.json` | `~/.local/share/axiotask-dev/tokens.json` |
| Backups | `~/.local/share/axiotask/backups/` | `~/.local/share/axiotask-dev/backups/` |
| UI state (localStorage) | `axiotask:*` | `axiotask:dev:*` |

The two instances share no config, data, credentials, or UI preferences, so a
dev instance can sign into a different Google account and never touch your
production tasks. The window title shows the instance name (`axiotask (dev)`),
and it's listed under **Properties → About**.

The prefix must be a short, filesystem-safe name (letters, digits, `-`, `_`).
An invalid value makes the app refuse to start rather than silently fall back
to the production directories.

## License

Apache-2.0
