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
echo "==> [0/8] Checking & installing system dependencies..."

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
echo "==> [1/8] Installing @deepseek-ai/dsh globally..."
npm install -g @deepseek-ai/dsh@latest

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
echo "==> [2/8] Applying Android platform patches..."
apply_patch "$REPO_DIR/patches/01-terminal-bash-android-shell.patch"        "dsh-terminal-bash"
apply_patch "$REPO_DIR/patches/02-session-persistence-link-rename.patch"     "dsh-session-persistence-jsonl"
apply_patch "$REPO_DIR/patches/03-subprocess-local-android.patch"            "dsh-subprocess-local"
apply_patch "$REPO_DIR/patches/04-host-apiproxy-termux-open-index.patch"     "dsh-host-apiproxy"
apply_patch "$REPO_DIR/patches/04-host-apiproxy-termux-open-opener.patch"    "dsh-host-apiproxy"
apply_patch "$REPO_DIR/patches/05-host-directory-picker-native-android.patch" "dsh-host-directory-picker-native"

# ── Step 3: Configure build environment for node-gyp ────────────────────────
echo "==> [3/8] Configuring native addon build environment..."

# Termux Bionic has no Android NDK metadata; tell node-gyp to skip the full
# NDK cross-compile and use the Bionic sysroot directly.
export npm_config_android_ndk_path=""

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
echo "==> [4/8] Compiling node-pty (Android API 30)..."
PTY_DIR="$DSH_DIR/node_modules/node-pty"
if [ -f "$PTY_DIR/build/Release/pty.node" ]; then
    echo "  [SKIP] pty.node already built."
else
    echo "  -> Running: npm rebuild node-pty"
    if (cd "$DSH_DIR" && npm rebuild node-pty 2>&1); then
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
echo "==> [5/8] Patching koffi statx() syscall for Android..."
KOFFI_CC="$DSH_DIR/node_modules/koffi/lib/native/base/base.cc"
if grep -q "defined(__linux__) && !defined(__ANDROID__)" "$KOFFI_CC" 2>/dev/null; then
    echo "  [SKIP] Patch already applied."
else
    sed -i 's/#if defined(__linux__)/#if defined(__linux__) \&\& !defined(__ANDROID__)/' "$KOFFI_CC"
    echo "  [OK] koffi base.cc patched."
fi

# ── Step 6: Install sharp WebAssembly fallback ───────────────────────────────
echo "==> [6/8] Installing sharp WebAssembly fallback..."
cd "$DSH_DIR"
if npm install @img/sharp-wasm32 > /dev/null 2>&1; then
    echo "  [OK] @img/sharp-wasm32 installed."
else
    echo "  [WARN] Could not install @img/sharp-wasm32 (may already be present)."
fi

# ── Step 7: Verify environment ───────────────────────────────────────────────
echo "==> [7/8] Verifying environment..."
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
        *) dir="" ;;
    esac
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        if (cd "$dir" && patch -p1 --dry-run --reverse < "$patch_file" > /dev/null 2>&1); then
            echo "    [NOT APPLIED] $name"
        else
            echo "    [APPLIED] $name"
        fi
    else
        echo "    [SKIP] $name (package not found)"
    fi
done

# ── Step 8: Runtime smoke test ───────────────────────────────────────────────
echo "==> [8/8] Runtime smoke test..."
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

echo ""
echo "==> Installation complete!"
echo ""
echo "To start dsh web (all plugins enabled), run:"
echo ""
echo "  node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js web"
echo ""
echo "Or add an alias to your ~/.bashrc:"
echo "  alias dsh='node --expose-internals \$(npm root -g)/@deepseek-ai/dsh/lib/bin.js'"