# dsh-termux — precompiled Termux deployment (Plan B)

English | [简体中文](README.zh-CN.md)

---

Installs the patched [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness)
globally on Termux **without compiling anything**: the native modules
(`node-pty`, `koffi`) ship prebuilt for **android-arm64** (N-API — ABI stable
across Node versions), so no `clang`, `cmake`, NDK, or multi-minute builds are
needed.

## Install — two variants

### Layered (small, ~360 KB) — recommended

```bash
npm i -g https://github.com/Vengisk/deepseek-harness-termux/releases/latest/download/dsh-termux.tgz
dsh web
```

The postinstall fetches `@deepseek-ai/dsh` from the npm registry (with
npmjs→npmmirror fallback), applies the bundled patches, and drops in the
prebuilt natives. Small artifact; needs the registry at install time.

### Vendored (fully self-contained, ~57 MB)

```bash
npm i -g https://github.com/Vengisk/deepseek-harness-termux/releases/latest/download/dsh-termux-full.tgz
dsh web
```

Bundles the **entire patched dsh + node_modules** (natives and sharp's wasm
included) — one artifact, no postinstall. Like the reference `dsh-termux`
package, npm may still consult the registry on a cold npm cache; with a warm
cache (or after a previous install) it installs from the bundle quickly.

## What the postinstall does (layered variant)

1. `npm install -g --ignore-scripts @deepseek-ai/dsh@<pinned version>` (nothing compiles)
2. Applies the Android source patches bundled in `patches/`
3. Drops in the prebuilt natives:
   - `node-pty/build/Release/pty.node`
   - `koffi/build/koffi/android_arm64/koffi.node`
4. Installs `@img/sharp-wasm32` (sharp's portable WebAssembly fallback —
   required for the attachment plugin to boot on android-arm64)
5. Patches `dsh/lib/bin.js`'s shebang so the `dsh` bin always runs with
   `--expose-internals` (required by the HMR plugin)

Everything is idempotent — re-running the install re-applies patches and
natives (npm re-extracts `dsh` first).

## Requirements

- Termux on **arm64** (aarch64) — this package ships android-arm64 binaries
  only
- Node.js `>= 22.19` (the same requirement as `@deepseek-ai/dsh`)
- `patch` (`pkg install patch`) — used by the layered variant to apply the
  source patches

## Rebuilding the prebuilt packages (for maintainers)

Run on an arm64 Termux device:

```bash
# 1. get a working patched install (compiles the natives once)
bash install.sh
# 2. package the tarballs (both modes by default)
DSH_DIR="$(npm root -g)/@deepseek-ai/dsh" bash scripts/build-prebuilt.sh
#    MODES=layered | MODES=full to build only one
# 3. upload dsh-termux.tgz and dsh-termux-full.tgz to a GitHub release, then
#    users can install from the releases/latest/download URLs above
```

The natives are N-API so they keep working across `dsh` updates; only bump the
pinned `DSH_VERSION` in `install.js` (and re-validate the patches) when
`install.sh`'s patches are updated for a new dsh release.

## Notes

- The `dsh` bin (installed by `@deepseek-ai/dsh` itself, or by the vendored
  package) runs with `--expose-internals` automatically via the patched
  shebang.
- Mobile UI / search plugins are **not** installed by either variant; add them
  with `dsh plugin --profile web add ...` after first boot.
