#!/usr/bin/env node
// dsh-termux postinstall (Plan B — precompiled native modules).
//
// Installs the patched @deepseek-ai/dsh globally WITHOUT compiling anything:
//   1. npm install -g --ignore-scripts @deepseek-ai/dsh@<pinned>
//   2. apply the Android source patches (bundled in patches/)
//   3. drop in the prebuilt native modules (bundled in prebuilt/)
//      - node-pty  -> node-pty/build/Release/pty.node
//      - koffi     -> koffi/build/koffi/android_arm64/koffi.node
//
// Everything is idempotent: re-running `npm i -g <tarball>` re-applies the
// patches and re-drops the natives (npm re-extracts dsh first, which wipes
// the previous copies).

"use strict";

const { execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

// Bump together with patches/: only a dsh version whose sources the patches
// apply to cleanly is safe to pin here. Overridable via DSH_VERSION.
const DSH_VERSION = process.env.DSH_VERSION || "0.1.0-rc.6";
const PKG_DIR = __dirname;

function run(cmd, opts) {
  execSync(cmd, { stdio: "inherit", ...opts });
}

function sh(cmd, opts) {
  try {
    return execSync(cmd, { stdio: "pipe", ...opts }).toString().trim();
  } catch {
    return "";
  }
}

// ── Locate the npm global root ──────────────────────────────────────────────
let globalRoot = sh("npm root -g");
if (!globalRoot) {
  globalRoot = path.join(
    process.env.PREFIX || "/data/data/com.termux/files/usr",
    "lib",
    "node_modules",
  );
}
const dshDir = path.join(globalRoot, "@deepseek-ai", "dsh");
const dshPkgs = path.join(dshDir, "node_modules", "@deepseek-ai");

// ── Step 1: install dsh (download only, nothing compiles) ──────────────────
console.log(`==> [1/3] Installing @deepseek-ai/dsh@${DSH_VERSION} (no scripts — nothing compiles)`);
run(`npm install -g --ignore-scripts @deepseek-ai/dsh@${DSH_VERSION}`);

// ── Step 2: apply the Android source patches ───────────────────────────────
console.log("==> [2/3] Applying Android platform patches");
const PATCH_TARGETS = [
  ["01-terminal-bash-android-shell.patch", "dsh-terminal-bash"],
  ["02-session-persistence-link-rename.patch", "dsh-session-persistence-jsonl"],
  ["03-subprocess-local-android.patch", "dsh-subprocess-local"],
  ["04-host-apiproxy-termux-open-index.patch", "dsh-host-apiproxy"],
  ["04-host-apiproxy-termux-open-opener.patch", "dsh-host-apiproxy"],
  ["05-host-directory-picker-native-android.patch", "dsh-host-directory-picker-native"],
  ["06-workspace-archive-skip-session-known-check.patch", "dsh-workspace"],
  ["07-sandbox-local-proot-runner.patch", "dsh-sandbox-local"],
  ["koffi-statx.patch", null], // koffi lives outside the @deepseek-ai scope
];
for (const [file, pkg] of PATCH_TARGETS) {
  const patch = path.join(PKG_DIR, "patches", file);
  const dir = pkg ? path.join(dshPkgs, pkg) : path.join(dshDir, "node_modules", "koffi");
  if (!fs.existsSync(patch)) {
    console.log("  [WARN] patch file missing:", file);
    continue;
  }
  if (!fs.existsSync(dir)) {
    console.log("  [SKIP]", file, "(package dir not found)");
    continue;
  }
  if (sh(`patch -p1 --dry-run --forward < "${patch}"`, { cwd: dir })) {
    sh(`patch -p1 --forward < "${patch}"`, { cwd: dir });
    console.log("  [OK]", file);
  } else {
    console.log("  [SKIP]", file, "(already applied or inapplicable)");
  }
}

// ── Step 3: drop in the prebuilt native modules ─────────────────────────────
console.log("==> [3/3] Installing prebuilt native modules (android-arm64)");
const prebuiltDir = path.join(PKG_DIR, "prebuilt", "android-arm64");
const TARGETS = [
  ["pty.node", path.join(dshDir, "node_modules", "node-pty", "build", "Release", "pty.node")],
  ["koffi.node", path.join(dshDir, "node_modules", "koffi", "build", "koffi", "android_arm64", "koffi.node")],
];
for (const [file, dest] of TARGETS) {
  const src = path.join(prebuiltDir, file);
  if (!fs.existsSync(src)) {
    console.log("  [WARN] prebuilt module missing:", file, "(this package only ships android-arm64)");
    continue;
  }
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
  fs.chmodSync(dest, 0o755);
  console.log("  [OK]", file, "->", path.relative(globalRoot, dest));
}

// ── Step 4: sharp WebAssembly fallback ──────────────────────────────────────
// sharp's native (libvips) binary is not available for android-arm64; dsh's
// attachment plugin fails to boot without it. The portable wasm build fixes it.
console.log("==> [4/5] Installing sharp WebAssembly fallback...");
try {
  execSync("npm install @img/sharp-wasm32", { cwd: dshDir, stdio: "pipe" });
  console.log("  [OK] @img/sharp-wasm32 installed");
} catch {
  console.log("  [WARN] could not install @img/sharp-wasm32 (sharp may fail to load)");
}

// ── Step 5: make the `dsh` bin run with --expose-internals ─────────────────
// The nested `npm install -g @deepseek-ai/dsh` links <prefix>/bin/dsh ->
// @deepseek-ai/dsh/lib/bin.js. That file's shebang is a bare `node`, but the
// HMR plugin needs --expose-internals, so we bake the flag into the shebang.
// When the symlink is exec'd the kernel reads the target's shebang and passes
// the flag — this is robust against npm re-linking bin entries. (We do NOT
// declare bin.dsh in our own package.json: that would collide with
// @deepseek-ai/dsh's bin during the nested install, EEXIST.)
console.log("==> [5/5] Ensuring the dsh bin runs with --expose-internals");
const binJs = path.join(dshDir, "lib", "bin.js");
const shebang = `#!${process.execPath} --expose-internals`;
const content = fs.readFileSync(binJs, "utf8");
if (!content.startsWith("#!")) {
  console.log("  [WARN] bin.js has no shebang — leaving as-is");
} else if (content.startsWith(shebang)) {
  console.log("  [OK] bin.js shebang already has --expose-internals");
} else {
  fs.writeFileSync(binJs, shebang + "\n" + content.slice(content.indexOf("\n") + 1));
  console.log("  [OK] bin.js shebang ->", shebang);
}

// ── Summary ─────────────────────────────────────────────────────────────────
console.log("");
console.log("==> dsh-termux installed!");
console.log("");
console.log("Run:  dsh web");
console.log("");
console.log("Optional extras after first boot:");
console.log("  dsh plugin --profile web add github:mexiaosqwq/dsh-web-mobile   # mobile UI");
