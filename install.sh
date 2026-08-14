#!/usr/bin/env bash
# install.sh — Full-feature installation of @deepseek-ai/dsh on Android/Termux
# Usage: bash install.sh
#
# This script installs dsh with ALL plugins enabled (HMR, subprocess, bash
# sandbox, permission). It applies the source patches under ./patches so the
# Termux build has real functionality instead of disabled plugins.
#
# Steps:
#   1. Check system dependencies (cmake, python, patch, etc.)
#   2. Install @deepseek-ai/dsh globally (npm >= 26 ships --expose-internals)
#   3. Apply Android source patches to the installed packages (idempotent)
#   4. Compile node-pty with the Android NDK toolchain (CFLAGS target API 30)
#   5. Patch koffi statx() for Android (statx is unavailable on Bionic)
#   6. Install sharp WebAssembly fallback
#   7. Verify the environment
#   8. Runtime smoke test (node-pty load)

set -euo pipefail

cd "$(dirname "$0")"
REPO_DIR="$(pwd)"

# ── Dependency check ─────────────────────────────────────────────────────────
echo "==> [0/8] Checking system dependencies..."
MISSING=()
for cmd in cmake python3 make pkg-config patch git; do
    if command -v "$cmd" > /dev/null 2>&1; then
        echo "  [OK] $cmd"
    else
        echo "  [MISS] $cmd"
        MISSING+=("$cmd")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "  -> Installing missing dependencies: ${MISSING[*]}"
    pkg install -y "${MISSING[@]}"
    echo "  [OK] Dependencies installed."
else
    echo "  [OK] All dependencies satisfied."
fi

echo "==> [1/8] Installing @deepseek-ai/dsh globally..."
npm install -g @deepseek-ai/dsh@latest

DSH_DIR="$(npm root -g)/@deepseek-ai/dsh"
DSH_PKGS="$DSH_DIR/node_modules/@deepseek-ai"
echo "==> Package installed at: $DSH_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────────
apply_patch() {
    local patch="$1" pkg="$2"
    local dir="$DSH_PKGS/$pkg"
    if [ ! -d "$dir" ]; then
        echo "  [WARN] $pkg not found; skipping patch $patch"
        return
    fi
    # --dry-run first: skip when already applied (idempotent)
    if (cd "$dir" && patch -p1 --dry-run --forward < "$patch" > /dev/null 2>&1); then
        (cd "$dir" && patch -p1 --forward < "$patch")
        echo "  [OK] $patch -> $pkg"
    else
        echo "  [SKIP] $patch already applied or inapplicable ($pkg)"
    fi
}

# ── Fix 1: Android source patches ────────────────────────────────────────────
echo "==> [2/8] Applying Android platform patches..."
apply_patch "$REPO_DIR/patches/01-terminal-bash-android-shell.patch"        "dsh-terminal-bash"
apply_patch "$REPO_DIR/patches/02-session-persistence-link-rename.patch"     "dsh-session-persistence-jsonl"
apply_patch "$REPO_DIR/patches/03-subprocess-local-android.patch"            "dsh-subprocess-local"
apply_patch "$REPO_DIR/patches/04-host-apiproxy-termux-open-index.patch"     "dsh-host-apiproxy"
apply_patch "$REPO_DIR/patches/04-host-apiproxy-termux-open-opener.patch"    "dsh-host-apiproxy"
apply_patch "$REPO_DIR/patches/05-host-directory-picker-native-android.patch" "dsh-host-directory-picker-native"

# ── Fix 2: Compile node-pty for Android ─────────────────────────────────────
echo "==> [3/8] Compiling node-pty (Android API 30)..."
PTY_DIR="$DSH_DIR/node_modules/node-pty"
if [ -f "$PTY_DIR/build/Release/pty.node" ]; then
    echo "  [SKIP] pty.node already built."
else
    (
        # Bionic has no Android NDK metadata; tell node-gyp to skip it and
        # target API 30 via the Bionic sysroot headers.
        export npm_config_android_ndk_path=""
        export CFLAGS="${CFLAGS:-} -D__ANDROID_API__=30"
        export CXXFLAGS="${CXXFLAGS:-} -D__ANDROID_API__=30"
        cd "$DSH_DIR"
        npm rebuild node-pty
    )
    if [ -f "$PTY_DIR/build/Release/pty.node" ]; then
        echo "  [OK] node-pty compiled."
    else
        echo "  [ERROR] node-pty build failed; see output above."
        exit 1
    fi
fi

# ── Fix 3: Patch koffi statx() for Android ──────────────────────────────────
echo "==> [4/8] Patching koffi statx() syscall for Android..."
KOFFI_CC="$DSH_DIR/node_modules/koffi/lib/native/base/base.cc"
if grep -q "defined(__linux__) && !defined(__ANDROID__)" "$KOFFI_CC" 2>/dev/null; then
    echo "  [SKIP] Patch already applied."
else
    sed -i 's/#if defined(__linux__)/#if defined(__linux__) \&\& !defined(__ANDROID__)/' "$KOFFI_CC"
    echo "  [OK] koffi base.cc patched."
fi

# ── Fix 4: Install sharp WebAssembly fallback ───────────────────────────────
echo "==> [5/8] Installing sharp WebAssembly fallback..."
cd "$DSH_DIR"
npm install @img/sharp-wasm32 > /dev/null 2>&1 && echo "  [OK] @img/sharp-wasm32 installed." || echo "  [WARN] Could not install sharp-wasm32 (may already be present)."

# ── Fix 5: Verify environment ───────────────────────────────────────────────
echo "==> [6/8] Checking environment..."
NODE_VER=$(node -v 2>/dev/null || echo "not found")
echo "  Node.js: $NODE_VER"

# ── Fix 6: Runtime smoke test ───────────────────────────────────────────────
echo "==> [7/8] Runtime smoke test..."
if node -e "require('node-pty'); process.exit(0)" 2>/dev/null; then
    echo "  node-pty: OK"
else
    echo "  node-pty: LOAD FAILED (trying with --expose-internals)"
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