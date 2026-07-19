# axiotask

A keyboard-driven desktop client for Google Tasks. Native, fast, offline-first.

Built with [Tauri 2](https://tauri.app/) (Rust backend) and [Svelte 5](https://svelte.dev/) (frontend).

## Features

- **Keyboard-first** — navigate, create, edit, complete, reschedule, and reorder without ever touching the mouse
- **Offline-first** — tasks are cached locally in SQLite; the app is instant and works with no connection, syncing in the background
- **Smart views** — Focus (due this week), Upcoming, Missed, and Unscheduled, plus All Tasks and a view per list
- **Quick reschedule** — one keystroke or click moves a task to today, tomorrow, next week, or next month, or clears its date
- **Subtasks** — nest tasks, indent/outdent, and see completion progress on the parent
- **Bulk insert** — paste multi-line text to create many tasks at once (one task per line, or first line as the title with the rest as notes)
- **Bulk operations** — multi-select tasks and complete, reschedule, move, or delete them together
- **Reorderable lists** — drag lists in the sidebar into your own order (saved per instance)
- **Sort & filter** — per-view sort (manual, due date, alphabetical, recently created) and an optional show-completed toggle
- **Search** — fuzzy search across every task
- **Backup & restore** — one click to export everything to JSON, or restore the latest backup (non-destructive)
- **Multiple isolated instances** — run a throwaway dev/test instance beside your real one (see below)
- **Read-only by default** — pushing local changes to Google is off until you turn it on, so you can try it safely
- **Cross-platform** — Linux, macOS, and Windows from a single codebase

## Using axiotask

**First run.** Launch the app and click **Sign in with Google** in the sidebar (or work entirely offline). Your tasks appear in the sidebar; pick a smart view or a list. Pushing changes back to Google is **off by default** — enable it in **Properties → Sync → Read-write sync** once you're comfortable.

**Create tasks.** Click **+ New task** or press `n`. To add many at once, copy multi-line text and paste it (`Ctrl+V`) into the task area — a dialog lets you choose *one task per line* or *first line as the title, the rest as notes*.

**Organize.** Drag a task's handle (or `Alt+↑`/`Alt+↓`) to reorder, `Tab`/`Shift+Tab` to indent/outdent into subtasks, and drag the ⠿ handle on a list to reorder your lists. Right-click a task for more actions.

**Reschedule.** With a task focused, press `o`/`t`/`w`/`m` for today/tomorrow/next week/next month, or `r` to clear the date. The same buttons appear on each row.

**Work in bulk.** Press `x` (or `Ctrl`/`Cmd`-click) to select tasks. A bulk bar appears — Complete, reschedule, Move, or Delete them all at once. With a selection active, the normal keys (`Space`, `d`, `o`/`t`/`w`/`m`, `r`, `Ctrl+M`) act on the whole selection. `Esc` clears it.

**Settings & backup.** Press `,` or click the ⚙ **Properties** button for sync mode, account, sync status, the keyboard cheatsheet, the app version, and **Export / Restore backup**.

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

### Android on-device testing

Android builds are available for validating the mobile touch UI: row swipe
actions, pull-to-refresh, the navigation drawer, and the floating add button.

Additional prerequisites:

| Tool | Version | Notes |
|------|---------|-------|
| Android Studio / SDK | API 36 installed | Install SDK Platform 36 and Android SDK Build-Tools |
| Android NDK | 29.x | Install through Android Studio's SDK Manager |
| Java | 17+ | Android Gradle Plugin 8.11 supports current JDKs |
| rustup | current | Required so Tauri can install Android Rust targets |

Set `ANDROID_HOME` to your Android SDK path when it is not discoverable by the
Tauri CLI. For a physical device, enable USB debugging and confirm the device
appears in `adb devices`.

```bash
cd crates/axiotask-app/ui

# One-time only when regenerating the checked-in Android project:
npm run android:init

# Hot-reload on a connected device or emulator:
npm run android:dev

# Produce Android release artifacts:
npm run android:build
```

`cargo tauri android dev` sets `TAURI_DEV_HOST`; the Vite dev server binds to
that host so an Android device can reach the desktop development server.

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

> **Use `cargo tauri build`, not `cargo build --release`.** Only `cargo tauri build`
> embeds the frontend into the binary. A plain `cargo build` produces a **dev-mode**
> binary hardwired to the Vite dev server (`http://localhost:1420`); run on its own it
> just shows *"Could not connect to localhost: Connection refused"*. Plain `cargo build`
> is only useful together with `cargo tauri dev` (or the Vite server running separately).

### Install (Linux, current user)

The easiest way — build the production binary and install it (binary on your
`PATH`, plus an app-menu launcher and icon):

```bash
./install.sh
```

Then run `axiotask` from a terminal or launch it from your application menu.
To remove it: `./install.sh uninstall` (leaves your data untouched).

Or do it manually:

```bash
install -Dm755 target/release/axiotask ~/.local/bin/axiotask
axiotask
```

(Use any directory on your `PATH`; `~/.local/bin` is a common choice on Linux/macOS.)

### Compile the core library only

To type-check / build just the Rust core (no app binary, no frontend):

```bash
cargo build -p axiotask-core            # debug
cargo build -p axiotask-core --release  # optimized
```

(Plain `cargo build` at the workspace root compiles the app binary too, but in
dev mode — see the note under **Production build** above.)

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
| `j` / `k` (or `↓` / `↑`) | Move focus down / up |
| `h` / `l` (or `←` / `→`) | Collapse (or go to parent) / expand |
| `n` | New task |
| `Enter` | Open / close the task detail panel |
| `e` | Edit task title inline |
| `Space` | Toggle complete |
| `s` | Add subtask |
| `d` | Delete task |
| `o` / `t` / `w` / `m` | Due today / tomorrow / next week / next month |
| `r` | Remove due date |
| `Tab` / `Shift+Tab` | Indent / outdent (make subtask / promote) |
| `Alt+↑` / `Alt+↓` | Move task up / down (manual sort) |
| `Ctrl+M` | Move task to another list |
| `x` | Select / deselect for bulk actions |
| `/` | Search all tasks |
| `,` | Open Properties (settings) |
| `?` | Show this cheatsheet |
| `Esc` | Close panel / clear selection |

> **Bulk:** with one or more tasks selected (via `x` or `Ctrl`/`Cmd`-click), `Space`, `d`, `o`/`t`/`w`/`m`, `r`, and `Ctrl+M` act on the **entire selection** instead of the focused task.

The full, always-current list is in the app — press `?`.

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
```

## Data Storage

- **Database:** `~/.local/share/axiotask/axiotask.sqlite` (SQLite)
- **Auth tokens:** `~/.local/share/axiotask/tokens.json` (beside the database)
- **Config:** `~/.config/axiotask/config.toml`
- **Backups:** `~/.local/share/axiotask/backups/` (timestamped JSON)

These paths are per-instance — see [Multiple isolated instances](#multiple-isolated-instances).

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
| Database | `~/.local/share/axiotask/axiotask.sqlite` | `~/.local/share/axiotask-dev/axiotask.sqlite` |
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
