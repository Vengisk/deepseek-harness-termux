# deepseek-harness-termux

**Run the full [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`@deepseek-ai/dsh`) on Android / Termux — no features disabled.**

English | [简体中文](README.zh-CN.md)

---

`deepseek-harness-termux` is a community-maintained compatibility layer that ports the official `@deepseek-ai/dsh` [agent harness](https://github.com/deepseek-ai/deepseek-harness) to Android environments running [Termux](https://termux.com/). The official npm package is built for glibc-based Linux distributions and depends on several native modules that fail to compile or misbehave on Android's Bionic libc. Instead of disabling plugins that depend on those modules, this repository patches the source code so every feature works on Termux.

All required patches were generated automatically against the pristine upstream tarballs (`@deepseek-ai/dsh` `0.1.0-rc.6`) with `diff -u`, so they are exact and reproducible.

## Feature Status

Every plugin is enabled and working in the Termux build:

| Component | Status | Notes |
|---|---|---|
| `dsh web` | ✅ Working | Server runs on `http://127.0.0.1:3080` |
| `dsh headless` | ✅ Working | Single-session headless mode |
| `dsh plugin` | ✅ Working | Plugin management |
| HMR (Hot Reload) | ✅ Working | Launched with `--expose-internals` |
| Subprocess | ✅ Working | `node-pty` compiled against Android NDK (API 30) |
| Bash Sandbox | ⚠️ Limited | `node-pty` works; `bubblewrap` is blocked by Android sepolicy at runtime and degrades safely (`SandboxUnavailableError`) |
| Permission System | ✅ Working | Restored with `node-pty` |
| Session Persistence | ✅ Fixed | `link(2)` → `rename(2)` fallback for Android sepolicy |
| Bash Terminal (PTY) | ✅ Fixed | Default shell path resolved on Termux (`/usr/bin/bash`) |

## Prerequisites

- **Android 12+** recommended (older versions may work but are untested)
- **Termux** from [F-Droid](https://f-droid.org/en/packages/com.termux/) (the Play Store version is unsupported and outdated)
- **Node.js >= 24**, **npm**, and the build toolchain for native modules:
  ```bash
  pkg update && pkg install nodejs-lts binutils make pkg-config clang python
  ```
- **Internet connection** for downloading packages

## Installation

```bash
# Clone this repository
git clone https://github.com/Vengisk/deepseek-harness-termux.git
cd deepseek-harness-termux

# Run the automated installer (installs dsh, applies patches, builds node-pty)
bash install.sh
```

The installer is idempotent — re-running it skips already-applied patches and already-built artifacts.

### How installation script work

1. **Installs** `@deepseek-ai/dsh` globally.
2. **Applies the Android source patches** under [`patches/`](patches/) to the installed packages.
3. **Compiles `node-pty`** against the Termux NDK toolchain with `-D__ANDROID_API__=30` (Bionic target).
4. **Patches `koffi`** to drop the unsupported `statx()` syscall on Android (it does not exist in Bionic; falls back to POSIX `stat()`/`fstat()`).
5. **Installs `@img/sharp-wasm32`** as a portable WebAssembly fallback for image processing (no native build needed).
6. **Runs a smoke test** to verify `node-pty` loads and the default shell resolves.

## Usage

Start the web interface with all plugins enabled:

```bash
node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js web
```

Or add an alias to your `~/.bashrc`:

```bash
alias dsh='node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js'
```

The `--expose-internals` flag is required because `cordis-plugin-hmr` accesses Node.js internal modules (e.g. `node:internal/modules`), which are gated by default since Node.js 22.

## Patches

| Patch | Package | What it fixes |
|---|---|---|
| [`01-terminal-bash-android-shell.patch`](patches/01-terminal-bash-android-shell.patch) | `dsh-terminal-bash` | Resolves a real shell binary on Termux (no `/bin/bash` on Android) |
| [`02-session-persistence-link-rename.patch`](patches/02-session-persistence-link-rename.patch) | `dsh-session-persistence-jsonl` | Falls back to atomic `rename(2)` when Android sepolicy blocks `link(2)` with `EACCES/EPERM` |
| [`03-subprocess-local-android.patch`](patches/03-subprocess-local-android.patch) | `dsh-subprocess-local` | Treats `android` like `linux` for process-group inspection (`kill(-pid, 0)`) |
| [`04-host-apiproxy-termux-open-index.patch`](patches/04-host-apiproxy-termux-open-index.patch) | `dsh-host-apiproxy` | Opens paths/URLs via `termux-open` on Android; enables native-path detection |
| [`04-host-apiproxy-termux-open-opener.patch`](patches/04-host-apiproxy-termux-open-opener.patch) | `dsh-host-apiproxy` | Same fixes in `lib/types/native-path-opener.js` |
| [`05-host-directory-picker-native-android.patch`](patches/05-host-directory-picker-native-android.patch) | `dsh-host-directory-picker-native` | Routes directory picking through the Linux (zenity) path on Android |
| [`koffi-statx.patch`](patches/koffi-statx.patch) | `koffi` | Conditionally compiles out the `statx()` syscall on Android |

## Compatibility Notes

- **Platform detection**: `process.platform` is `"android"` on Termux, so upstream `platform === "linux"` branches are extended to `platform === "linux" || platform === "android"`.
- **Bash sandbox**: `bubblewrap` requires `user_namespaces` and specific `/proc` access that Android sepolicy denies. The harness detects this at runtime and degrades to a safe `SandboxUnavailableError` instead of crashing — subprocess execution itself still works via `node-pty`.
- **Termux paths**: `termux-open` launches the Android VIEW intent (browser, file viewers, etc.).

## Project Structure

```
deepseek-harness-termux/
├── README.md                  # This file (English)
├── README.zh-CN.md            # 简体中文 README
├── LICENSE                    # MIT License
├── install.sh                 # Automated installer (idempotent)
└── patches/                   # Source patches (patch -p1 inside each package)
    ├── 01-terminal-bash-android-shell.patch
    ├── 02-session-persistence-link-rename.patch
    ├── 03-subprocess-local-android.patch
    ├── 04-host-apiproxy-termux-open-index.patch
    ├── 04-host-apiproxy-termux-open-opener.patch
    ├── 05-host-directory-picker-native-android.patch
    └── koffi-statx.patch
```

## Acknowledgements

- **[DeepSeek AI](https://github.com/deepseek-ai)** for the excellent [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) agent framework.
- **Termux Community** for the Android terminal environment.
- **koffi**, **node-pty**, and **sharp** maintainers.

## License

MIT — same as the original [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness). See [LICENSE](LICENSE).

---

*Maintained by [Vengisk](https://github.com/Vengisk) — not an official DeepSeek product.*