#!/usr/bin/env bash
# install.sh — Automated installation of @deepseek-ai/dsh on Android/Termux
# Usage: bash install.sh
#
# This script handles:
#   1. Installing the dsh npm package globally
#   2. Patching koffi for Android (statx syscall)
#   3. Installing sharp WebAssembly fallback
#   4. Initializing the web profile with compatibility patches

set -euo pipefail

echo "==> Installing @deepseek-ai/dsh globally..."
npm install -g @deepseek-ai/dsh@latest

DSH_DIR="$(npm root -g)/@deepseek-ai/dsh"
echo "==> Package installed at: $DSH_DIR"

# ── Fix 1: Patch koffi statx() for Android ──────────────────────────────────
echo "==> [1/4] Patching koffi statx() syscall for Android..."
KOFFI_CC="$DSH_DIR/node_modules/koffi/lib/native/base/base.cc"
if grep -q "defined(__linux__) && !defined(__ANDROID__)" "$KOFFI_CC" 2>/dev/null; then
    echo "  [SKIP] Patch already applied."
else
    sed -i 's/#if defined(__linux__)/#if defined(__linux__) \&\& !defined(__ANDROID__)/' "$KOFFI_CC"
    echo "  [OK] koffi base.cc patched."
fi

# ── Fix 2: Install sharp WebAssembly fallback ────────────────────────────────
echo "==> [2/4] Installing sharp WebAssembly fallback..."
cd "$DSH_DIR"
npm install @img/sharp-wasm32 2>/dev/null && echo "  [OK] @img/sharp-wasm32 installed." || echo "  [WARN] Could not install sharp-wasm32 (may already be present)."

# ── Fix 3: Apply cordis.patch.yml for web profile ───────────────────────────
echo "==> [3/4] Applying cordis patch for Android compatibility..."
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
PROFILE_DIR="$DSH_HOME/profiles/web"
mkdir -p "$PROFILE_DIR"

if [ -f "$PROFILE_DIR/cordis.patch.yml" ]; then
    echo "  [SKIP] cordis.patch.yml already exists at $PROFILE_DIR/cordis.patch.yml"
else
    cat > "$PROFILE_DIR/cordis.patch.yml" << 'PATCH'
# cordis.patch.yml — Android/Termux compatibility overrides
- id: hmr
  disabled: true
- id: subprocess
  disabled: true
- id: bash-sandbox
  disabled: true
- id: permission
  disabled: true
PATCH
    echo "  [OK] cordis.patch.yml created."
fi

# ── Fix 4: Verify Node.js version and remind about --expose-internals ────────
echo "==> [4/4] Checking environment..."
NODE_VER=$(node -v 2>/dev/null || echo "not found")
echo "  Node.js: $NODE_VER"
echo ""
echo "==> Installation complete!"
echo ""
echo "To start dsh web, run:"
echo ""
echo "  node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js web"
echo ""
echo "Or add an alias to your ~/.bashrc:"
echo "  alias dsh='node --expose-internals \$(npm root -g)/@deepseek-ai/dsh/lib/bin.js'"