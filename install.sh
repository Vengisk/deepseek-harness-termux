#!/usr/bin/env bash
# install.sh — Fully automated install of @deepseek-ai/dsh on Android/Termux
# Usage: bash install.sh
#
# This script installs dsh with ALL plugins enabled (HMR, subprocess, bash
# sandbox, permission). It automatically detects and installs the Android NDK
# (ndk-sysroot), C toolchain (clang, binutils), and all build-time dependencies.
#
# Why a two-phase install:
#   The old one-phase flow let npm run node-pty/koffi's install scripts DURING
#   `npm install -g`, at which point the build environment (node headers,
#   GYP_DEFINES, the common.gypi android_ndk_path default, the koffi statx()
#   patch) was NOT yet configured — so fresh devices failed with
#   "gyp: Undefined variable android_ndk_path" or "node.h: No such file or
#   directory". Here we install with --ignore-scripts first, configure
#   everything, apply source patches, and only then build the native addons
#   manually with a fully prepared environment.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$(uname -o 2>/dev/null)" != "Android" ]; then
    echo "  [WARN] This script is designed for Termux (Android)."
    echo "  [WARN] Continuing anyway; native builds may fail on other platforms."
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

pkg_installed() {
    dpkg -s "$1" > /dev/null 2>&1
}

cmd_exists() {
    command -v "$1" > /dev/null 2>&1
}

apply_patch() {
    # apply_patch <patch-file> <package-dir>
    # Returns 0 when the patch was applied NOW, 1 when it was skipped
    # (already applied, inapplicable, or missing target).
    local patch="$1" dir="$2"
    if [ ! -f "$patch" ]; then
        echo "  [WARN] patch file missing: $patch"
        return 1
    fi
    if [ ! -d "$dir" ]; then
        echo "  [WARN] $(basename "$patch"): package dir not found ($dir) — skipping"
        return 1
    fi
    if (cd "$dir" && patch -p1 --dry-run --forward < "$patch" > /dev/null 2>&1); then
        (cd "$dir" && patch -p1 --forward < "$patch" > /dev/null 2>&1)
        echo "  [OK] $(basename "$patch") -> $(basename "$dir")"
        return 0
    fi
    echo "  [SKIP] $(basename "$patch") already applied or inapplicable ($dir)"
    return 1
}

# ── Step 0: Install system dependencies ─────────────────────────────────────
echo "==> [0/9] Checking & installing system dependencies..."

# Refresh package lists first. Stale lists are a common cause of "package not
# found" / broken dependency resolution on older setups; if the refresh fails
# we still continue with whatever lists exist (offline-friendly).
echo "  -> Refreshing package lists (pkg update)..."
if pkg update -y; then
    echo "  [OK] package lists refreshed."
else
    echo "  [WARN] pkg update failed — continuing with existing lists"
fi

# Core packages required by the installer and the native builds. If any of
# these fails, install.sh aborts below with a clear message.
SYSTEM_PKGS=(
    ndk-sysroot    # Android platform headers/libs (bionic sysroot: stdio.h etc.)
    clang          # C/C++ compiler (LLVM/Clang for Termux)
    binutils       # ar, strip, etc. (needed by node-gyp)
    cmake          # Native addon build system (koffi)
    make           # Build tool
    python3        # node-gyp/gyp configure scripts
    pkg-config     # Library discovery
    patch          # Apply source patches
    git            # Version check / metadata / git-hosted plugins
    proot          # User-space chroot for bash sandbox (Android fallback)
    nodejs         # Node.js runtime
    npm            # Package manager
    curl           # Header tarball downloads
    which          # command -v fallback / diagnostics
)

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
    if ! pkg install -y "${PKGS_TO_INSTALL[@]}"; then
        echo ""
        echo "  [ERROR] pkg install failed. Common fixes:"
        echo "  - Run 'pkg upgrade -y' once (stale/broken packages block installs)"
        echo "  - Run 'pkg install -y ${PKGS_TO_INSTALL[*]}' manually to see the real error"
        echo "  - Check your network / Termux mirrors (termux-change-repo)"
        exit 1
    fi
    echo "  [OK] System dependencies installed."
else
    echo "  [OK] All system dependencies satisfied."
fi

# Optional-but-recommended packages: not present in every Termux repo, so a
# failure here is non-fatal.
#   ndk-multilib:    multi-ABI NDK toolchain at $PREFIX/opt/ndk-multilib.
#                    Provides the sysroot/headers/libs some devices need for
#                    native compilation (verified on low-Android setups).
#   libandroid-spawn: posix_spawn() shim for old Android bionic; lets builds
#                    link with -landroid-spawn when present.
if ! pkg_installed ndk-multilib; then
    echo "  -> Installing ndk-multilib (multi-ABI NDK toolchain)..."
    pkg install -y ndk-multilib > /dev/null 2>&1 \
        && echo "  [OK] ndk-multilib installed" \
        || echo "  [WARN] ndk-multilib unavailable — continuing without it"
fi
if ! pkg_installed libandroid-spawn; then
    echo "  -> Installing libandroid-spawn (posix_spawn shim)..."
    pkg install -y libandroid-spawn > /dev/null 2>&1 \
        && echo "  [OK] libandroid-spawn installed" \
        || echo "  [WARN] libandroid-spawn unavailable — continuing without it"
fi

TOOLS=(clang clang++ ar cmake make pkg-config patch git python3 node npm curl which)
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

# ── Step 1: Configure the native build environment (BEFORE anything compiles) ─
echo "==> [1/9] Configuring native addon build environment..."

# node-pty/koffi build via gyp: on Termux, gyp sees OS=android (python3 reports
# sys.platform='android') and node's stock common.gypi has an android branch
# that references <(android_ndk_path) with NO default value ->
# "gyp: Undefined variable android_ndk_path". Termux has no standalone Google
# NDK metadata; the Bionic sysroot comes from the ndk-sysroot package. We
# therefore always pin android_ndk_path via GYP_DEFINES (gyp's official -D
# channel, read via ShlexEnv — inherited by every node-gyp/gyp child):
#   - when ndk-multilib is installed we point it at
#     $PREFIX/opt/ndk-multilib (community-tested on low-Android devices),
#   - otherwise we pin it to empty, which is equally fine (the referenced
#     -I<path>/sources/... directory does not exist either way).
# A default value is ALSO patched into node's cached common.gypi (Step 2) to
# cover manual rebuilds where GYP_DEFINES may be unset.
NDK_MULTILIB="${PREFIX:-/data/data/com.termux/files/usr}/opt/ndk-multilib"
if [ -d "$NDK_MULTILIB" ]; then
    export ANDROID_NDK_HOME="$NDK_MULTILIB"
    export ANDROID_NDK_ROOT="$NDK_MULTILIB"
    export GYP_DEFINES="${GYP_DEFINES:+$GYP_DEFINES }android_ndk_path=$NDK_MULTILIB"
    echo "  [OK] ndk-multilib NDK detected: $NDK_MULTILIB"
    echo "  [OK] ANDROID_NDK_HOME/ROOT + android_ndk_path -> $NDK_MULTILIB"
else
    # A stale/foreign NDK env var would make gyp/node-gyp attempt cross-
    # compilation — unset when we have no NDK to point them at.
    unset ANDROID_NDK_HOME
    unset ANDROID_NDK_ROOT
    export GYP_DEFINES="${GYP_DEFINES:+$GYP_DEFINES }android_ndk_path="
fi
echo "  [OK] GYP_DEFINES='$GYP_DEFINES'"

# NOTE: do NOT export -D defines in CFLAGS/CXXFLAGS here. A global
# "-D__ANDROID_API__=30" (or any -D) leaks into cmake-based builds (koffi) via
# the CFLAGS env var and breaks them: Termux's bionic/libc++ headers use clang
# availability checks against the target (android24), so strtof_l()/
# pthread_cond_clockwait() etc. error out. Termux clang's default target
# already works for node-pty and koffi, and the native builds below scrub
# CFLAGS/CXXFLAGS/CPPFLAGS from their own environment.
#
# We DO export LDFLAGS=-landroid-spawn when libandroid-spawn is installed:
# that shim provides posix_spawn() on old Android bionic and is consumed by
# cmake (koffi) during linking. Harmless when the library is absent — we only
# set it when the .so exists.
if [ -f "${PREFIX:-/data/data/com.termux/files/usr}/lib/libandroid-spawn.so" ]; then
    export LDFLAGS="${LDFLAGS:+$LDFLAGS }-landroid-spawn"
    echo "  [OK] LDFLAGS='$LDFLAGS' (libandroid-spawn)"
fi

# node-gyp python discovery: export a deterministic interpreter.
export PYTHON="${PYTHON:-$(command -v python3 || command -v python || echo python3)}"
echo "  [OK] PYTHON=$PYTHON"

export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"
echo "  [OK] CC = $(command -v "$CC" 2>/dev/null || echo "$CC (not on PATH yet)")"
echo "  [OK] CXX = $(command -v "$CXX" 2>/dev/null || echo "$CXX (not on PATH yet)")"

NODE_VER="$(node -v 2>/dev/null | sed 's/^v//' || true)"
if [ -z "$NODE_VER" ]; then
    echo "  [ERROR] node not found after package install — aborting"
    exit 1
fi
NODE_GYP_CACHE="$HOME/.cache/node-gyp/$NODE_VER"
# Note: we deliberately do NOT export npm_config_nodedir. The pre-seeded cache
# below is found by node-gyp on its own, and exporting npm_config_nodedir makes
# every later npm invocation print "npm warn Unknown env config nodedir".

# ── Step 2: Pre-seed node headers + patch common.gypi ───────────────────────
echo "==> [2/9] Ensuring node-gyp headers & patching common.gypi..."

# node-gyp needs the node development headers under ~/.cache/node-gyp/<ver>.
# On a fresh device this cache is empty and node-gyp would download them from
# nodejs.org DURING the npm install — a frequent failure point (slow/blocked
# network in some regions -> "node.h: No such file or directory"). We download
# them up front with a China mirror fallback (npmmirror mirrors nodejs.org).
if [ -d "$NODE_GYP_CACHE/include/node" ]; then
    echo "  [OK] node-gyp headers cache present ($NODE_VER)"
else
    echo "  -> Downloading node headers v$NODE_VER (mirror fallback)..."
    _headers_ok=false
    _tmp="$(mktemp -d)"
    _tar="$_tmp/node-v$NODE_VER-headers.tar.gz"
    for _base in "https://nodejs.org/download/release/v$NODE_VER" \
                 "https://npmmirror.com/mirrors/node/v$NODE_VER"; do
        _url="$_base/node-v$NODE_VER-headers.tar.gz"
        echo "  [INFO] trying $_url"
        if curl -fsSL --connect-timeout 15 --max-time 600 -o "$_tar" "$_url"; then
            mkdir -p "$NODE_GYP_CACHE"
            tar -xzf "$_tar" -C "$_tmp"
            cp -R "$_tmp/node-v$NODE_VER/include" "$NODE_GYP_CACHE/"
            # node-gyp only trusts a cache dir marked complete via installVersion
            _iv="$(node -p "require('$(npm root -g 2>/dev/null)/npm/node_modules/node-gyp/package.json').installVersion" 2>/dev/null || echo 9)"
            echo "$_iv" > "$NODE_GYP_CACHE/installVersion"
            rm -rf "$_tmp"
            echo "  [OK] node headers installed to $NODE_GYP_CACHE"
            _headers_ok=true
            break
        fi
        echo "  [WARN] download failed: $_url"
    done
    rm -rf "$_tmp"
    if ! $_headers_ok; then
        echo "  [ERROR] Could not download node headers for v$NODE_VER"
        echo "  [ERROR] Fix your network, then re-run install.sh (or set"
        echo "  [ERROR] npm_config_nodedir to a local node dev dir)."
        exit 1
    fi
fi

# Belt-and-suspenders: patch node's cached common.gypi so android_ndk_path has
# a default empty value. The stock file references <(android_ndk_path) in its
# OS=="android" branch but declares no default, which makes ANY plain
# `node-gyp rebuild` (GYP_DEFINES unset) fail with
# "gyp: Undefined variable android_ndk_path".
# NOTE: the awk pattern must match the QUOTED key line "  'variables': {".
_common_gypi="$NODE_GYP_CACHE/include/node/common.gypi"
if [ -f "$_common_gypi" ] && grep -q 'android_ndk_path' "$_common_gypi" \
    && ! grep -q "'android_ndk_path%'" "$_common_gypi"; then
    awk '
        /^[[:space:]]*'"'"'?variables'"'"'?[[:space:]]*:[[:space:]]*\{/ && !_done {
            print
            print "    '"'"'android_ndk_path%'"'"': '"'"''"'"',        # Termux: default empty (no NDK metadata)"
            _done=1
            next
        }
        { print }
    ' "$_common_gypi" > "$_common_gypi.tmp" && mv "$_common_gypi.tmp" "$_common_gypi"
    if grep -q "'android_ndk_path%'" "$_common_gypi"; then
        echo "  [OK] patched android_ndk_path default into $_common_gypi"
    else
        echo "  [WARN] common.gypi patch did not apply (awk regex mismatch?) —"
        echo "  [WARN] builds still work via GYP_DEFINES, but manual rebuilds may fail"
    fi
elif [ -f "$_common_gypi" ]; then
    echo "  [OK] common.gypi already patched (android_ndk_path default present)"
fi

# ── Step 3: npm install (download only, no compile yet) ─────────────────────
echo "==> [3/9] Installing @deepseek-ai/dsh globally (no scripts)..."

# Multi-source download: official npm registry first, npmmirror (China) as
# fallback. --ignore-scripts defers ALL native compilation to Step 5, where
# the environment and source patches are ready. --foreground-scripts +
# --loglevel verbose keep progress visible. A stall watchdog kills npm if it
# produces no output for NPM_INSTALL_TIMEOUT seconds and tries the next source.

NPM_INSTALL_TIMEOUT="${NPM_INSTALL_TIMEOUT:-600}"   # seconds without output
NPM_MIRRORS=(
    "https://registry.npmjs.org"
    "https://registry.npmmirror.com"
)
NPM_LOG_FILE="${PREFIX:-/data/data/com.termux/files/usr}/tmp/dsh-npm-install.log"

DSH_DIR="$(npm root -g)/@deepseek-ai/dsh"

# Fast path: if the installed version already matches the latest release, skip
# the npm install entirely. Re-running `npm install -g` re-extracts all 500+
# packages (wiping our patches and native builds, which then all get redone),
# so this check is what makes re-runs of install.sh truly fast and idempotent.
# The patch/build steps below are themselves skip-aware and cover a partial
# or broken previous install (missing pty.node/koffi.node get rebuilt).
DSH_INSTALL_OK=false
if [ -f "$DSH_DIR/package.json" ]; then
    _installed_ver="$(node -p "require('$DSH_DIR/package.json').version" 2>/dev/null || true)"
    _latest_ver="$(npm view @deepseek-ai/dsh version 2>/dev/null || true)"
    if [ -n "$_installed_ver" ] && [ "$_installed_ver" = "$_latest_ver" ]; then
        echo "  [SKIP] @deepseek-ai/dsh@$_installed_ver already installed (latest) — skipping npm install"
        DSH_INSTALL_OK=true
    else
        echo "  [INFO] installed=$_installed_ver latest=$_latest_ver — installing @deepseek-ai/dsh@latest"
    fi
fi

if ! $DSH_INSTALL_OK; then
for _registry in "${NPM_MIRRORS[@]}"; do
    echo "" > "$NPM_LOG_FILE"
    {
        npm install -g --ignore-scripts @deepseek-ai/dsh@latest \
            --registry="$_registry" \
            --foreground-scripts \
            --loglevel verbose
    } > >(tee "$NPM_LOG_FILE") 2>&1 &
    _npm_pid=$!

    # Watchdog: no output for NPM_INSTALL_TIMEOUT seconds => kill, next mirror
    _last_size=0 _stable_count=0
    while kill -0 "$_npm_pid" 2>/dev/null; do
        sleep 10
        _cur_size=$(stat -c %s "$NPM_LOG_FILE" 2>/dev/null || echo 0)
        if [ "$_cur_size" -eq "$_last_size" ]; then
            _stable_count=$((_stable_count + 1))
            _elapsed=$((_stable_count * 10))
            echo "  [INFO] No output for ${_elapsed}s (download stalled?)..."
            if [ "$_elapsed" -ge "$NPM_INSTALL_TIMEOUT" ]; then
                echo "  [ERROR] npm install produced no output for ${NPM_INSTALL_TIMEOUT}s — killing"
                echo "  [DIAG] Network check:"
                curl -sS --connect-timeout 5 -o /dev/null -w "    HTTP %{http_code} (%{time_total}s)" "$_registry" 2>&1 || echo "    UNREACHABLE"
                echo ""
                kill -TERM "$_npm_pid" 2>/dev/null
                sleep 2
                kill -KILL "$_npm_pid" 2>/dev/null
                wait "$_npm_pid" 2>/dev/null || true
                continue 2
            fi
        else
            _stable_count=0
        fi
        _last_size="$_cur_size"
    done

    if wait "$_npm_pid"; then
        DSH_INSTALL_OK=true
        break
    fi
done
fi

if ! $DSH_INSTALL_OK; then
    echo "  [ERROR] All registries failed. Last resort: default npm settings"
    npm install -g --ignore-scripts @deepseek-ai/dsh@latest && DSH_INSTALL_OK=true
fi

if ! $DSH_INSTALL_OK; then
    echo "  [ERROR] npm install failed from all sources"
    echo "  Try manually: npm install -g @deepseek-ai/dsh@latest"
    echo "  Or with mirror: npm install -g @deepseek-ai/dsh@latest --registry=https://registry.npmmirror.com"
    exit 1
fi

DSH_PKGS="$DSH_DIR/node_modules/@deepseek-ai"
echo "  [OK] Package installed at: $DSH_DIR"

# ── Step 4: Apply Android source patches ────────────────────────────────────
echo "==> [4/9] Applying Android platform patches..."

# Note: apply_patch returns 1 for "already applied / inapplicable" — under
# `set -e` a top-level non-zero return would abort the script, so the plain
# patch calls are guarded with `|| true` (their messages still print).
apply_patch "$REPO_DIR/patches/01-terminal-bash-android-shell.patch"         "$DSH_PKGS/dsh-terminal-bash" || true
apply_patch "$REPO_DIR/patches/02-session-persistence-link-rename.patch"      "$DSH_PKGS/dsh-session-persistence-jsonl" || true
apply_patch "$REPO_DIR/patches/03-subprocess-local-android.patch"             "$DSH_PKGS/dsh-subprocess-local" || true
apply_patch "$REPO_DIR/patches/04-host-apiproxy-termux-open-index.patch"      "$DSH_PKGS/dsh-host-apiproxy" || true
apply_patch "$REPO_DIR/patches/04-host-apiproxy-termux-open-opener.patch"     "$DSH_PKGS/dsh-host-apiproxy" || true
apply_patch "$REPO_DIR/patches/05-host-directory-picker-native-android.patch" "$DSH_PKGS/dsh-host-directory-picker-native" || true
apply_patch "$REPO_DIR/patches/06-workspace-archive-skip-session-known-check.patch" "$DSH_PKGS/dsh-workspace" || true
apply_patch "$REPO_DIR/patches/07-sandbox-local-proot-runner.patch"           "$DSH_PKGS/dsh-sandbox-local" || true

# ── Step 5: Build native addons (koffi first — its statx() patch must be     ─
#            baked into the binary) ───────────────────────────────────────────
echo "==> [5/9] Building native addons..."

# node-gyp wrapper shipped with npm, for manual rebuilds
NODE_GYP_BIN="$(dirname "$(dirname "$(command -v npm)")")/lib/node_modules/npm/bin/node-gyp-bin"
if [ -d "$NODE_GYP_BIN" ]; then
    export PATH="$NODE_GYP_BIN:$PATH"
fi

# 5a. koffi — apply the statx() Android patch BEFORE compiling, then build.
KOFFI_DIR="$DSH_DIR/node_modules/koffi"
KOFFI_OUT="$KOFFI_DIR/build/koffi/android_arm64/koffi.node"
KOFFI_BUILD=false
if apply_patch "$REPO_DIR/patches/koffi-statx.patch" "$KOFFI_DIR"; then
    KOFFI_BUILD=true
elif [ ! -f "$KOFFI_OUT" ]; then
    KOFFI_BUILD=true
fi
if $KOFFI_BUILD; then
    echo "  -> Building koffi native lib (this takes a while)..."
    # Scrub CFLAGS/CXXFLAGS/CPPFLAGS: a user-level -D__ANDROID_API__ or other
    # define would leak into cmake via the env and break the build (bionic
    # availability checks vs. the android24 target).
    if (cd "$KOFFI_DIR" && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS \
            node ./cnoke.cjs -P . -D src/koffi --prebuild --release); then
        echo "  [OK] koffi native lib built."
    else
        echo "  [ERROR] koffi build failed!"
        echo "  Common causes: missing cmake (pkg install cmake), missing"
        echo "  ndk-sysroot (pkg install ndk-sysroot), a CFLAGS/CXXFLAGS"
        echo "  override in your environment, or no network for the koffi"
        echo "  prebuild download."
        exit 1
    fi
else
    echo "  [SKIP] koffi already built with patched sources."
fi

# 5b. node-pty — compile against the Termux bionic sysroot.
PTY_DIR="$DSH_DIR/node_modules/node-pty"
if [ -f "$PTY_DIR/build/Release/pty.node" ]; then
    echo "  [SKIP] pty.node already built."
else
    echo "  -> Building node-pty (Termux bionic target)..."
    if (cd "$PTY_DIR" && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS node scripts/prebuild.js); then
        echo "  [OK] node-pty prebuilt binary available."
    elif (cd "$PTY_DIR" && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS node-gyp rebuild --nodedir="$NODE_GYP_CACHE"); then
        echo "  [OK] node-pty compiled."
    else
        echo "  [ERROR] node-pty build failed!"
        echo ""
        echo "  Common causes and fixes:"
        echo "  - Missing ndk-sysroot:  pkg install ndk-sysroot"
        echo "  - Missing binutils:     pkg install binutils"
        echo "  - Missing clang:        pkg install clang"
        echo "  - Missing node headers: rm -rf $NODE_GYP_CACHE && re-run install.sh"
        echo "  - android_ndk_path:     export GYP_DEFINES='android_ndk_path=' && retry"
        echo ""
        echo "  Last 20 lines of the build log:"
        # shellcheck disable=SC2086
        tail -20 "$PTY_DIR"/build/Release/obj.target/*.log 2>/dev/null || true
        exit 1
    fi
fi

# 5c. Restore the executable bit of node-pty's spawn helper (npm strips it).
SUB_DIR="$DSH_PKGS/dsh-subprocess-local"
if [ -f "$SUB_DIR/scripts/ensure-spawn-helper.mjs" ]; then
    (cd "$SUB_DIR" && node scripts/ensure-spawn-helper.mjs) && \
        echo "  [OK] subprocess spawn-helper restored (chmod 755)"
fi

# ── Step 6: Install sharp WebAssembly fallback ───────────────────────────────
echo "==> [6/9] Installing sharp WebAssembly fallback..."
if (cd "$DSH_DIR" && npm install @img/sharp-wasm32 > /dev/null 2>&1); then
    echo "  [OK] @img/sharp-wasm32 installed."
else
    echo "  [WARN] Could not install @img/sharp-wasm32 (may already be present)."
fi

# ── Step 7: Install mobile-adaptive UI plugin ────────────────────────────────
echo "==> [7/9] Installing dsh-web-mobile (mobile-adaptive UI plugin)..."
# dsh-web-mobile by @mexiaosqwq: on narrow screens (<1024px) hides the sidebar
# rail and turns the directory into an overlay drawer, giving the conversation
# full width. Pure client plugin — no effect on desktop (>=1024px).
# https://github.com/mexiaosqwq/dsh-web-mobile
#
# `dsh plugin --profile web add ...` initializes the profile on first use, so
# there is no need to run `dsh web` beforehand. It forwards to pnpm, which must
# be on PATH — install it if missing.

DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
WEB_PROFILE_DIR="$DSH_HOME_DIR/profiles/web"
PLUGIN_CMD="node --expose-internals $DSH_DIR/lib/bin.js plugin --profile web add github:mexiaosqwq/dsh-web-mobile"

if ! cmd_exists pnpm; then
    echo "  -> Installing pnpm (required by the dsh plugin manager)..."
    if npm install -g pnpm; then
        echo "  [OK] pnpm installed ($(command -v pnpm))"
    else
        echo "  [WARN] pnpm install failed — the plugin step will fail without it"
    fi
fi

if [ -f "$WEB_PROFILE_DIR/package.json" ] && grep -q "dsh-mobile-nav" "$WEB_PROFILE_DIR/package.json" 2>/dev/null; then
    echo "  [SKIP] dsh-web-mobile already installed"
elif node --expose-internals "$DSH_DIR/lib/bin.js" plugin --profile web add github:mexiaosqwq/dsh-web-mobile 2>&1; then
    echo "  [OK] dsh-web-mobile installed"
else
    echo "  [WARN] dsh plugin add failed. Install it manually later with:"
    echo "    $PLUGIN_CMD"
fi

# ── Step 8: Verify environment ───────────────────────────────────────────────
echo "==> [8/9] Verifying environment..."
NODE_VER_CUR=$(node -v 2>/dev/null || echo "not found")
echo "  Node.js: $NODE_VER_CUR"
echo "  dsh dir: $DSH_DIR"

echo "  Native modules:"
_NATIVE_MISSING=false
if [ -f "$PTY_DIR/build/Release/pty.node" ]; then
    echo "    [OK] node-pty pty.node"
else
    echo "    [MISS] node-pty pty.node"
    _NATIVE_MISSING=true
fi
if [ -f "$KOFFI_OUT" ]; then
    echo "    [OK] koffi android_arm64 koffi.node"
else
    echo "    [MISS] koffi android_arm64 koffi.node"
    _NATIVE_MISSING=true
fi
if $_NATIVE_MISSING; then
    echo ""
    echo "  [ERROR] Native modules are missing — the install is incomplete."
    echo "  Re-run install.sh; if it persists, capture the output above and"
    echo "  open an issue at https://github.com/Vengisk/deepseek-harness-termux"
    exit 1
fi

echo "  Patches:"
for patch_file in "$REPO_DIR"/patches/*.patch; do
    name="$(basename "$patch_file")"
    # Strip the numeric prefix and extension, then map to the target package
    pkg_name="$(echo "$name" | sed -E 's/^[0-9]+-//; s/\.patch$//')"
    case "$pkg_name" in
        terminal-bash-android-shell)                dir="$DSH_PKGS/dsh-terminal-bash" ;;
        session-persistence-link-rename)            dir="$DSH_PKGS/dsh-session-persistence-jsonl" ;;
        subprocess-local-android)                   dir="$DSH_PKGS/dsh-subprocess-local" ;;
        host-apiproxy-termux-open-index)            dir="$DSH_PKGS/dsh-host-apiproxy" ;;
        host-apiproxy-termux-open-opener)           dir="$DSH_PKGS/dsh-host-apiproxy" ;;
        host-directory-picker-native-android)       dir="$DSH_PKGS/dsh-host-directory-picker-native" ;;
        workspace-archive-skip-session-known-check) dir="$DSH_PKGS/dsh-workspace" ;;
        sandbox-local-proot-runner)                 dir="$DSH_PKGS/dsh-sandbox-local" ;;
        koffi-statx)                                dir="$DSH_DIR/node_modules/koffi" ;;
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
if (cd "$DSH_DIR" && node -e "require('node-pty'); process.exit(0)" 2>/dev/null); then
    echo "  node-pty: OK"
else
    echo "  node-pty: LOAD FAILED (trying with --expose-internals)"
    if (cd "$DSH_DIR" && node --expose-internals -e "require('node-pty'); process.exit(0)" 2>/dev/null); then
        echo "  node-pty: OK (with --expose-internals)"
    else
        echo "  [WARN] node-pty fails to load even with --expose-internals"
        echo "  This may affect the terminal plugin, but other features may work."
    fi
fi

# koffi loads?
if (cd "$DSH_DIR" && node -e "require('koffi'); process.exit(0)" 2>/dev/null); then
    echo "  koffi: OK"
else
    echo "  [WARN] koffi fails to load — FFI features (file dialogs, etc.) may not work"
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

# ── Make `dsh` usable directly (no manual alias needed) ─────────────────────
# 1) Patch the installed bin.js shebang so npm's own `dsh` bin always runs
#    with --expose-internals (required by HMR) — works in ANY shell, even
#    inside scripts. Same trick the prebuilt (Plan B) packages use.
DSH_BIN_JS="$DSH_DIR/lib/bin.js"
if [ -f "$DSH_BIN_JS" ] && ! head -1 "$DSH_BIN_JS" | grep -q -- "--expose-internals"; then
    NODE_BIN="$(command -v node)"
    { printf '#!%s --expose-internals\n' "$NODE_BIN"; tail -n +2 "$DSH_BIN_JS"; } > "$DSH_BIN_JS.new"
    mv "$DSH_BIN_JS.new" "$DSH_BIN_JS"
    echo "  [OK] patched $DSH_BIN_JS shebang (--expose-internals)"
else
    echo "  [OK] dsh bin.js shebang already has --expose-internals"
fi

# 2) Belt-and-suspenders: append a `dsh` alias to the user's shell rc
#    WITHOUT overwriting it (the shebang patch covers re-extracted bin.js
#    cases; the alias covers every interactive shell). Creates the rc file
#    if it does not exist yet, so the alias is always persisted.
_DSH_ALIAS="alias dsh='node --expose-internals \$(npm root -g)/@deepseek-ai/dsh/lib/bin.js'"
_RC_FILE=""
if [ -f "$HOME/.bashrc" ]; then
    _RC_FILE="$HOME/.bashrc"
elif [ -n "${SHELL:-}" ] && [ "${SHELL##*/}" = "zsh" ] && [ -f "$HOME/.zshrc" ]; then
    _RC_FILE="$HOME/.zshrc"
else
    _RC_FILE="$HOME/.bashrc"
    touch "$_RC_FILE"   # ensure the alias is actually persisted
fi
if grep -q "alias dsh=" "$_RC_FILE" 2>/dev/null; then
    echo "  [SKIP] dsh alias already present in $_RC_FILE"
else
    echo "$_DSH_ALIAS" >> "$_RC_FILE"
    echo "  [OK] Appended to $_RC_FILE:"
    echo "    $_DSH_ALIAS"
    echo "  [INFO] Run 'source $_RC_FILE' once (or open a new session) to activate,"
    echo "  [INFO] then you can just type: dsh web"
fi
echo ""
echo "  (Your existing shell config was never overwritten.)"
echo ""
echo "Now run:  dsh web"
