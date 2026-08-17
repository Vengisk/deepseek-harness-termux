#!/usr/bin/env bash
# build-prebuilt.sh — assemble the dsh-termux prebuilt tarball (Plan B).
#
# Run on an arm64 Termux device that already has a WORKING patched install
# (run install.sh once). Produces ./dsh-termux.tgz which users install with:
#   npm i -g https://github.com/Vengisk/deepseek-harness-termux/releases/latest/download/dsh-termux.tgz
#
# Usage:
#   bash scripts/build-prebuilt.sh                 # uses the global install
#   DSH_DIR=/path/to/dsh bash scripts/build-prebuilt.sh
#
# The natives are N-API (ABI stable), so the tarball keeps working across dsh
# updates; rebuild only when the patches or native deps change.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$REPO_DIR/prebuilt"

# ── 1. Locate a working patched install ─────────────────────────────────────
if [ -z "${DSH_DIR:-}" ]; then
    DSH_DIR="$(npm root -g)/@deepseek-ai/dsh"
fi
if [ ! -f "$DSH_DIR/package.json" ]; then
    echo "[ERROR] no @deepseek-ai/dsh found at $DSH_DIR"
    echo "        Run install.sh first, or set DSH_DIR=/path/to/dsh"
    exit 1
fi
echo "==> Using patched install at: $DSH_DIR"

PTY="$DSH_DIR/node_modules/node-pty/build/Release/pty.node"
KOFFI="$DSH_DIR/node_modules/koffi/build/koffi/android_arm64/koffi.node"
if [ ! -f "$PTY" ]; then
    echo "[ERROR] missing $PTY — run install.sh first"
    exit 1
fi
if [ ! -f "$KOFFI" ]; then
    echo "[ERROR] missing $KOFFI — run install.sh first"
    exit 1
fi
echo "    pty.node : $PTY"
echo "    koffi    : $KOFFI"

# ── 2. Sanity-check the natives load in this node ───────────────────────────
echo "==> Verifying natives load..."
if ! (cd "$DSH_DIR" && node -e "require('node-pty'); require('koffi'); console.log('    natives OK')"); then
    echo "[ERROR] natives failed to load — rebuild them first (bash install.sh)"
    exit 1
fi

# ── 3. Assemble the staging package ─────────────────────────────────────────
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/package/bin" \
         "$STAGE/package/patches" \
         "$STAGE/package/prebuilt/android-arm64"

cp "$PKG_DIR/package.json" "$STAGE/package/"
cp "$PKG_DIR/install.js"    "$STAGE/package/"
cp "$PKG_DIR/README.md"     "$STAGE/package/"
cp "$PKG_DIR/README.zh-CN.md" "$STAGE/package/"
cp "$PKG_DIR/bin/dsh"       "$STAGE/package/bin/dsh"
chmod +x "$STAGE/package/bin/dsh"
cp "$REPO_DIR"/patches/*.patch "$STAGE/package/patches/"
cp "$PTY"  "$STAGE/package/prebuilt/android-arm64/pty.node"
cp "$KOFFI" "$STAGE/package/prebuilt/android-arm64/koffi.node"

# ── 4. Tar it up ────────────────────────────────────────────────────────────
OUT="$REPO_DIR/dsh-termux.tgz"
tar -czf "$OUT" -C "$STAGE" package
echo ""
echo "==> Built: $OUT ($(du -h "$OUT" | cut -f1))"
echo ""
echo "Local install test:  npm i -g $OUT"
echo "Upload to GitHub:    gh release upload <tag> $OUT"
echo "Then users install:  npm i -g https://github.com/Vengisk/deepseek-harness-termux/releases/latest/download/dsh-termux.tgz"
