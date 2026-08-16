#!/usr/bin/env bash
# install.sh — Fully automated install of @deepseek-ai/dsh on Android/Termux
# Usage: bash install.sh
#
# This script installs dsh with ALL plugins enabled (HMR, subprocess, bash
# sandbox, permission). It automatically detects and installs the Android NDK
# (ndk-sysroot), C toolchain (clang, binutils), and all build-time dependencies.
# Environment variables for node-gyp are set automatically so native addons
# (node-pty, koffi) compile against the Termux Bionic sysroot.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────

pkg_installed() {
    dpkg -s "$1" > /dev/null 2>&1
}

cmd_exists() {
    command -v "$1" > /dev/null 2>&1
}

# ── Step 0: Install system dependencies ─────────────────────────────────────
echo "==> [0/9] Checking & installing system dependencies..."

# Packages to install via pkg (both metapackages and individual tools)
SYSTEM_PKGS=(
    ndk-sysroot    # Android NDK platform headers/libs (Bionic sysroot)
    clang          # C/C++ compiler (LLVM/Clang for Termux)
    binutils       # ar, strip, etc. (needed by node-gyp)
    cmake          # Native addon build system
    make           # Build tool
    python3        # node-gyp configure scripts
    pkg-config     # Library discovery
    patch          # Apply source patches
    git            # Version check / metadata
    proot          # User-space chroot for bash sandbox (Android fallback)
)

# Determine which packages are NOT installed
PKGS_TO_INSTALL=()
for pkg in "${SYSTEM_PKGS[@]}"; do
    if pkg_installed "$pkg"; then
        echo "  [OK] $pkg"
    else
        echo "  [MISS] $pkg"
        PKGS_TO_INSTALL+=("$pkg")
    fi
done

if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
    echo "  -> Installing: ${PKGS_TO_INSTALL[*]}"
    pkg install -y "${PKGS_TO_INSTALL[@]}"
    echo "  [OK] System dependencies installed."
else
    echo "  [OK] All system dependencies satisfied."
fi

# Now verify that key CLI tools are actually on PATH
# (ndk-sysroot is a header/library package, not a command — no need to check)
TOOLS=(clang clang++ ar cmake make pkg-config patch git python3)
TOOLS_MISSING=false
for tool in "${TOOLS[@]}"; do
    if cmd_exists "$tool"; then
        echo "  [OK] $tool ($(command -v "$tool"))"
    else
        echo "  [WARN] $tool not found on PATH — may cause build failures"
        TOOLS_MISSING=true
    fi
done

if $TOOLS_MISSING; then
    echo "  [INFO] Some tools are missing; continuing anyway (they may be installed by pkg hooks)"
fi

# ── Step 1: Install @deepseek-ai/dsh ────────────────────────────────────────
echo "==> [1/9] Installing @deepseek-ai/dsh globally..."

# node-pty's install lifecycle runs `node scripts/prebuild.js || node-gyp rebuild`
# with NO CLI arguments. On Android, gyp detects OS=android and node's stock
# common.gypi has an android branch that references <(android_ndk_path) — but
# provides NO default value for that variable -> "gyp: Undefined variable
# android_ndk_path in binding.gyp".
#
# node-gyp's configure.js does NOT forward npm_config_android_ndk_path to gyp
# (verified: it never appears in gyp spawn args). The only channels that work
# for the bare `node-gyp rebuild` inside the npm install lifecycle are:
#   1. GYP_DEFINES env var — gyp reads it via ShlexEnv() (gyp/__init__.py).
#      This is gyp's OFFICIAL env-var channel for -D defines, not a plain
#      shell variable. npm lifecycle children inherit it.
#   2. Patching common.gypi with a default value (done in Step 3 as backstop).
# We use BOTH: GYP_DEFINES for the npm install lifecycle, and the common.gypi
# patch for any subsequent manual rebuilds where GYP_DEFINES may be unset.
export GYP_DEFINES="${GYP_DEFINES:+$GYP_DEFINES }android_ndk_path="
echo "  [OK] GYP_DEFINES='$GYP_DEFINES'"

# ── npm install with multi-source, progress, and timeout safety ─────────────
# Layer 1: Multi-source download — try official npm registry first, fall back
# to npmmirror (China) if the official source is slow or unreachable.
# Layer 2: Progress feedback — --foreground-scripts makes node-pty's compile
# output visible; --loglevel verbose shows download progress.
# Layer 3: Timeout safety — a watchdog kills npm if it produces no output for
# NPM_INSTALL_TIMEOUT seconds (default 300 = 5 min), then prints diagnostics
# (was clang compiling? network reachable?).

NPM_INSTALL_TIMEOUT="${NPM_INSTALL_TIMEOUT:-300}"   # seconds without output
NPM_MIRRORS=(
    "https://registry.npmjs.org"
    "https://registry.npmmirror.com"
)
NPM_LOG_FILE="/data/data/com.termux/files/usr/tmp/dsh-npm-install.log"

DSH_INSTALL_OK=false
for _registry in "${NPM_MIRRORS[@]}"; do
    NPM_LOG_FILE="/data/data/com.termux/files/usr/tmp/dsh-npm-install.log"
    echo "" > "$NPM_LOG_FILE"

    # Run npm install with output redirected to log file (so watchdog can check size)
    # while also teeing to stdout for user visibility
    {
        npm install -g @deepseek-ai/dsh@latest \
            --registry="$_registry" \
            --foreground-scripts \
            --loglevel verbose
    } > >(tee "$NPM_LOG_FILE") 2>&1 &
    _npm_pid=$!

    # Watchdog
    _last_size=0 _stable_count=0
    while kill -0 "$_npm_pid" 2>/dev/null; do
        sleep 10
        _cur_size=$(stat -c %s "$NPM_LOG_FILE" 2>/dev/null || echo 0)
        if [ "$_cur_size" -eq "$_last_size" ]; then
            _stable_count=$((_stable_count + 1))
            _elapsed=$((_stable_count * 10))
            echo "  [INFO] Still working... (${_elapsed}s since last output)"
            # Check if clang is compiling (that's legitimate)
            if pgrep -f 'clang|cc1plus' > /dev/null 2>&1; then
                echo "  [INFO] clang is compiling node-pty (this is normal, please wait)"
            fi
            if [ "$_elapsed" -ge "$NPM_INSTALL_TIMEOUT" ]; then
                echo "  [ERROR] npm install timed out after ${NPM_INSTALL_TIMEOUT}s with no output"
                echo "  [DIAG] Running processes:"
                ps aux 2>/dev/null | grep -E 'clang|cc1plus|node-gyp|npm' | grep -v grep || echo "    (none)"
                echo "  [DIAG] Network check:"
                curl -sS --connect-timeout 5 -o /dev/null -w "    HTTP %{http_code} (%{time_total}s)" "$_registry" 2>&1 || echo "    UNREACHABLE"
                echo ""
                kill -TERM "$_npm_pid" 2>/dev/null
                sleep 2
                kill -KILL "$_npm_pid" 2>/dev/null
                wait "$_npm_pid" 2>/dev/null
                continue 2
            fi
        else
            _stable_count=0
        fi
        _last_size="$_cur_size"
    done

    wait "$_npm_pid" && {
        DSH_INSTALL_OK=true
        break
    }
done

if ! $DSH_INSTALL_OK; then
    echo "  [ERROR] All registries failed. Last resort: try with default settings"
    npm install -g @deepseek-ai/dsh@latest && DSH_INSTALL_OK=true
fi

if ! $DSH_INSTALL_OK; then
    echo "  [ERROR] npm install failed from all sources"
    echo "  Try manually: npm install -g @deepseek-ai/dsh@latest"
    echo "  Or with mirror: npm install -g @deepseek-ai/dsh@latest --registry=https://registry.npmmirror.com"
    exit 1
fi

DSH_DIR="$(npm root -g)/@deepseek-ai/dsh"
DSH_PKGS="$DSH_DIR/node_modules/@deepseek-ai"
echo "  [OK] Package installed at: $DSH_DIR"

# ── Patch helpers ────────────────────────────────────────────────────────────
apply_patch() {
    local patch="$1" pkg="$2"
    local dir="$DSH_PKGS/$pkg"
    if [ ! -d "$dir" ]; then
        echo "  [WARN] $pkg not found; skipping patch $patch"
        return
    fi
    if (cd "$dir" && patch -p1 --dry-run --forward < "$patch" > /dev/null 2>&1); then
        (cd "$dir" && patch -p1 --forward < "$patch")
        echo "  [OK] $patch -> $pkg"
    else
        echo "  [SKIP] $patch already applied or inapplicable ($pkg)"
    fi
}

# ── Step 2: Apply Android patches ────────────────────────────────────────────
echo "==> [2/9] Applying Android platform patches..."
apply_patch "$REPO_DIR/patches/01-terminal-bash-android-shell.patch"        "dsh-terminal-bash"
apply_patch "$REPO_DIR/patches/02-session-persistence-link-rename.patch"     "dsh-session-persistence-jsonl"
apply_patch "$REPO_DIR/patches/03-subprocess-local-android.patch"            "dsh-subprocess-local"
apply_patch "$REPO_DIR/patches/04-host-apiproxy-termux-open-index.patch"     "dsh-host-apiproxy"
apply_patch "$REPO_DIR/patches/04-host-apiproxy-termux-open-opener.patch"    "dsh-host-apiproxy"
apply_patch "$REPO_DIR/patches/05-host-directory-picker-native-android.patch" "dsh-host-directory-picker-native"
apply_patch "$REPO_DIR/patches/07-sandbox-local-proot-runner.patch"         "dsh-sandbox-local"

# ── Step 3: Configure build environment for node-gyp ────────────────────────
echo "==> [3/9] Configuring native addon build environment..."

# Belt-and-suspenders: patch node's cached common.gypi to give
# android_ndk_path a default empty value. node's stock common.gypi has an
# `['OS == "android"', { 'cflags': [ '-I<(android_ndk_path)/...' ] }]` branch
# but NO corresponding variable default, so loading it on Android triggers
# "Undefined variable android_ndk_path". This is idempotent and covers any
# node-gyp call that bypasses the npm_config channel (e.g. manual rebuilds,
# other native addons).
for _cg in "$HOME"/.cache/node-gyp/*/include/node/common.gypi; do
    [ -f "$_cg" ] || continue
    if grep -q 'android_ndk_path' "$_cg" && ! grep -q "'android_ndk_path%'" "$_cg"; then
        # Insert the variable default right after the opening 'variables': { block
        # (line ~14). Use awk for a portable, robust insertion.
        awk '
            /^[[:space:]]*'variables'[[:space:]]*:[[:space:]]*\{/ && !_done {
                print
                print "    '"'"'android_ndk_path%'"'"': '"'"''"'"',        # Termux: default empty (no NDK metadata)"
                _done=1
                next
            }
            { print }
        ' "$_cg" > "$_cg.tmp" && mv "$_cg.tmp" "$_cg"
        echo "  [OK] patched android_ndk_path default in $_cg"
    fi
done

# Termux has no standalone NDK metadata; node-gyp's android_ndk_path must be
# empty so the build uses the Bionic sysroot from ndk-sysroot. It is provided
# via GYP_DEFINES (Step 1) and the common.gypi default patch above.
#
# We DO unset ANDROID_NDK_HOME/ROOT in case the user has them set to a
# non-existent or incomplete NDK — that would cause node-gyp to attempt
# cross-compilation instead of using the native Termux clang.
unset ANDROID_NDK_HOME
unset ANDROID_NDK_ROOT

# Node.js headers for native addon compilation
NODE_DIR="$(node -e "console.log(require('path').join(require('os').homedir(), '.cache/node-gyp', process.version))" 2>/dev/null || true)"
if [ -n "$NODE_DIR" ] && [ -d "$NODE_DIR/include/node" ]; then
    export npm_config_nodedir="$NODE_DIR"
    echo "  [OK] nodedir = $NODE_DIR"
fi

# C/C++ flags: target Android API 30 so the NDK headers expose the right
# API level. This is required for ioctls, termios, and process management
# (process group, session, etc.) that node-pty depends on.
export CFLAGS="-D__ANDROID_API__=30"
export CXXFLAGS="-D__ANDROID_API__=30"
echo "  [OK] CFLAGS/CXXFLAGS = -D__ANDROID_API__=30"

# Ensure CC/CXX point to Termux clang (they already do by default on Termux,
# but some node-gyp wrappers may reset them)
export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"
echo "  [OK] CC = $(command -v "$CC" 2>/dev/null || echo "$CC (not on PATH yet)")"
echo "  [OK] CXX = $(command -v "$CXX" 2>/dev/null || echo "$CXX (not on PATH yet)")"

# ── Step 4: Build node-pty ──────────────────────────────────────────────────
echo "==> [4/9] Compiling node-pty (Android API 30)..."
PTY_DIR="$DSH_DIR/node_modules/node-pty"
if [ -f "$PTY_DIR/build/Release/pty.node" ]; then
    echo "  [SKIP] pty.node already built."
else
    # android_ndk_path is provided via GYP_DEFINES (exported in Step 1, still
    # in the environment here) and via the common.gypi default-value patch
    # (Step 3). No CLI arg needed — gyp only accepts -Dkey=val format anyway,
    # not --key=val, and the bare `node-gyp rebuild` inside npm install
    # lifecycle has no CLI args at all yet must succeed (it does, via
    # GYP_DEFINES).
    #
    # We also need node-gyp on PATH.  npm's bundled node-gyp wrapper is at
    # npm/bin/node-gyp-bin/node-gyp — we add it to PATH manually.
    NODE_GYP_BIN="$(dirname "$(dirname "$(which npm)")")/lib/node_modules/npm/bin/node-gyp-bin"
    if [ -d "$NODE_GYP_BIN" ]; then
        export PATH="$NODE_GYP_BIN:$PATH"
    fi

    echo "  -> Running: node-gyp rebuild --nodedir=\"$NODE_DIR\""
    if (cd "$PTY_DIR" && node-gyp rebuild --nodedir="$NODE_DIR" 2>&1); then
        echo "  [OK] node-pty compiled."
    else
        echo "  [ERROR] node-pty build failed!"
        echo ""
        echo "  Common causes and fixes:"
        echo "  - Missing ndk-sysroot:  pkg install ndk-sysroot"
        echo "  - Missing binutils:     pkg install binutils"
        echo "  - Missing clang:        pkg install clang"
        echo "  - Missing node headers: npm cache clean -f && npm install -g @deepseek-ai/dsh"
        echo ""
        echo "  Last 20 lines of the build log:"
        PTY_LOG="$PTY_DIR/build/Release/obj.target/*.log"
        # shellcheck disable=SC2086
        tail -20 $PTY_LOG 2>/dev/null || true
        exit 1
    fi
fi

# ── Step 5: Patch koffi statx() for Android ──────────────────────────────────
echo "==> [5/9] Patching koffi statx() syscall for Android..."
KOFFI_CC="$DSH_DIR/node_modules/koffi/lib/native/base/base.cc"
if grep -q "defined(__linux__) && !defined(__ANDROID__)" "$KOFFI_CC" 2>/dev/null; then
    echo "  [SKIP] Patch already applied."
else
    sed -i 's/#if defined(__linux__)/#if defined(__linux__) \&\& !defined(__ANDROID__)/' "$KOFFI_CC"
    echo "  [OK] koffi base.cc patched."
fi

# ── Step 6: Install sharp WebAssembly fallback ───────────────────────────────
echo "==> [6/9] Installing sharp WebAssembly fallback..."
cd "$DSH_DIR"
if npm install @img/sharp-wasm32 > /dev/null 2>&1; then
    echo "  [OK] @img/sharp-wasm32 installed."
else
    echo "  [WARN] Could not install @img/sharp-wasm32 (may already be present)."
fi

# ── Step 7: Install mobile-adaptive UI plugin ────────────────────────────────
echo "==> [7/9] Installing dsh-web-mobile (mobile-adaptive UI plugin)..."
# dsh-web-mobile by @mexiaosqwq: on narrow screens (<1024px) hides the sidebar
# rail and turns the directory into an overlay drawer, giving the conversation
# full width. Pure client plugin — no effect on desktop (≥1024px).
# https://github.com/mexiaosqwq/dsh-web-mobile

DSH_HOME_DIR="${DSSH_HOME:-$HOME/.dsh}"
WEB_PROFILE_DIR="$DSH_HOME_DIR/profiles/web"

if [ ! -d "$WEB_PROFILE_DIR" ]; then
    echo "  [WARN] Web profile directory not found at $WEB_PROFILE_DIR"
    echo "  [INFO] Run 'dsh web' once to generate the profile, then re-run install.sh"
else
    # Check if already installed
    if grep -q "dsh-mobile-nav" "$WEB_PROFILE_DIR/package.json" 2>/dev/null; then
        echo "  [SKIP] dsh-web-mobile already installed"
    else
        echo "  -> Installing via dsh plugin command..."
        if node --expose-internals "$DSH_DIR/lib/bin.js" --profile web plugin add github:mexiaosqwq/dsh-web-mobile 2>&1; then
            echo "  [OK] dsh-web-mobile installed"
        else
            echo "  [WARN] dsh plugin command failed, trying manual install..."
            # Manual fallback: add to package.json and install via pnpm
            cd "$WEB_PROFILE_DIR"
            # Add dependency to package.json
            node -e "
                const fs = require('fs');
                const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
                pkg.dependencies = pkg.dependencies || {};
                pkg.dependencies['@dsh-external/dsh-mobile-nav'] = 'github:mexiaosqwq/dsh-web-mobile';
                pkg.dsh = pkg.dsh || {};
                pkg.dsh.profile = pkg.dsh.profile || {};
                pkg.dsh.profile.bundles = pkg.dsh.profile.bundles || [];
                if (!pkg.dsh.profile.bundles.includes('@dsh-external/dsh-mobile-nav')) {
                    pkg.dsh.profile.bundles.push('@dsh-external/dsh-mobile-nav');
                }
                fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
            " 2>&1
            if pnpm install 2>&1; then
                echo "  [OK] dsh-web-mobile installed (manual)"
            else
                echo "  [WARN] Manual install also failed; you can install it later:"
                echo "    dsh --profile web plugin add github:mexiaosqwq/dsh-web-mobile"
            fi
        fi
    fi
fi

# ── Step 8: Verify environment ───────────────────────────────────────────────
echo "==> [8/9] Verifying environment..."
NODE_VER=$(node -v 2>/dev/null || echo "not found")
echo "  Node.js: $NODE_VER"
echo "  dsh dir: $DSH_DIR"

# Check that patches are applied
echo "  Patches:"
for patch_file in "$REPO_DIR"/patches/*.patch; do
    name="$(basename "$patch_file")"
    # Extract the package name from the patch filename (everything after the number)
    pkg_name="$(echo "$name" | sed -E 's/^[0-9]+-//; s/\.patch$//')"
    # Map to dsh package directory name
    case "$pkg_name" in
        terminal-bash-android-shell)     dir="$DSH_PKGS/dsh-terminal-bash" ;;
        session-persistence-link-rename) dir="$DSH_PKGS/dsh-session-persistence-jsonl" ;;
        subprocess-local-android)        dir="$DSH_PKGS/dsh-subprocess-local" ;;
        host-apiproxy-termux-open-index) dir="$DSH_PKGS/dsh-host-apiproxy" ;;
        host-apiproxy-termux-open-opener) dir="$DSH_PKGS/dsh-host-apiproxy" ;;
        host-directory-picker-native-android) dir="$DSH_PKGS/dsh-host-directory-picker-native" ;;
        sandbox-local-proot-runner) dir="$DSH_PKGS/dsh-sandbox-local" ;;
        *) dir="" ;;
    esac
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        if (cd "$dir" && patch -p1 --dry-run --reverse < "$patch_file" > /dev/null 2>&1); then
            echo "    [APPLIED] $name"
        else
            echo "    [NOT APPLIED] $name"
        fi
    else
        echo "    [SKIP] $name (package not found)"
    fi
done

# ── Step 9: Runtime smoke test ───────────────────────────────────────────────
echo "==> [9/9] Runtime smoke test..."
if node -e "require('node-pty'); process.exit(0)" 2>/dev/null; then
    echo "  node-pty: OK"
else
    echo "  node-pty: LOAD FAILED (trying with --expose-internals)"
    if node --expose-internals -e "require('node-pty'); process.exit(0)" 2>/dev/null; then
        echo "  node-pty: OK (with --expose-internals)"
    else
        echo "  [WARN] node-pty fails to load even with --expose-internals"
        echo "  This may affect the terminal plugin, but other features may work."
    fi
fi

# Sandbox smoke test: verify proot runner is active for Android
echo "  bash sandbox:"
if [ "$(uname -o)" = "Android" ] && command -v proot >/dev/null 2>&1; then
    SANDBOX_TEST=$(node --expose-internals -e "
const { LocalSandboxProvider } = require('$DSH_DIR/node_modules/@deepseek-ai/dsh-sandbox-local');
console.log('loaded');
" 2>&1)
    if echo "$SANDBOX_TEST" | grep -q "loaded"; then
        echo "    proot runner: registered"
    else
        echo "    proot runner: module load issue"
    fi
else
    echo "    (non-Android or proot missing — skipped)"
fi

echo ""
echo "==> Installation complete!"
echo ""
echo "To start dsh web (all plugins enabled), run:"
echo ""
echo "  node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js web"
echo ""
echo "Or add an alias to your ~/.bashrc:"
echo "  alias dsh='node --expose-internals \$(npm root -g)/@deepseek-ai/dsh/lib/bin.js'"