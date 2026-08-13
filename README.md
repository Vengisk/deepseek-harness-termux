# deepseek-harness-termux

**Run [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`@deepseek-ai/dsh`) on Android / Termux.**

[English](#english) | [中文](#chinese)

---

## English

`deepseek-harness-termux` is a community-maintained compatibility layer that ports the official [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness) CLI to Android environments running [Termux](https://termux.com/). The official package is built for glibc-based Linux distributions and depends on several native modules that either fail to compile or behave incorrectly on Android's Bionic libc. This repository documents the four fixes required to make it work on Termux and provides automated installation scripts.

### Prerequisites

- **Android 12+** recommended (older versions may work but are untested)
- **Termux** from [F-Droid](https://f-droid.org/en/packages/com.termux/) (the Play Store version is unsupported and outdated)
- **Node.js >= 24** (install via `pkg install nodejs-lts` or `pkg install nodejs`)
- **npm** (bundled with Node.js)
- **Internet connection** for downloading packages

### Known Issues & Fixes

The following four incompatibilities between `@deepseek-ai/dsh` and Android/Termux have been identified and resolved:

#### 1. koffi statx() Syscall (Linux-Specific)

| Issue | The `koffi` native FFI module calls the Linux `statx()` syscall, which does not exist in Android's Bionic libc. This causes a runtime crash (`ENOSYS`) when the module loads. |
|---|---|
| **Fix** | In `koffi/lib/native/base/base.cc`, change `#if defined(__linux__)` to `#if defined(__linux__) && !defined(__ANDROID__)` at line 2952. This conditionally compiles out the `statx()` path on Android, falling back to the POSIX `stat()`/`fstat()` path. |
| **Patch** | [`patches/koffi-statx.patch`](patches/koffi-statx.patch) |

#### 2. sharp Native Binary (Image Processing)

| Issue | The `sharp` image processing library ships prebuilt native binaries for Linux x64/arm64 but not for Android/Termux. Installation fails because the native binary cannot be found or loaded. |
|---|---|
| **Fix** | Install `@img/sharp-wasm32` as a WebAssembly fallback. This provides a fully functional, portable WebAssembly build of `sharp` that works on any platform without native compilation. Run `npm install @img/sharp-wasm32` in the dsh package directory. |
| **Reference** | [`@img/sharp-wasm32` on npm](https://www.npmjs.com/package/@img/sharp-wasm32) |

#### 3. node-pty / Cordis Plugin Incompatibilities

| Issue | The `node-pty` native module (required by `subprocess`, `bash-sandbox`, and `permission` plugins) cannot be compiled on Termux without a full Android NDK. Additionally, `cordis-plugin-hmr` (Hot Module Replacement) requires the `--expose-internals` Node.js flag. |
|---|---|
| **Fix** | Disable incompatible plugins via `cordis.patch.yml` in the web profile (`$DSH_HOME/profiles/web/cordis.patch.yml`). The following plugins are disabled: `hmr`, `subprocess`, `bash-sandbox`, `permission`. |
| **Patch** | [`patches/cordis.patch.yml`](patches/cordis.patch.yml) |

#### 4. `--expose-internals` Node.js Flag

| Issue | The `cordis-plugin-hmr` plugin accesses Node.js internal modules (e.g., `node:internal/modules`). Starting from Node.js 22+, these internals are no longer accessible by default and require the `--expose-internals` CLI flag. |
|---|---|
| **Fix** | Launch dsh with `node --expose-internals /path/to/dsh web` instead of the bare `dsh web` command. |
| **Workaround** | Add an alias to your `~/.bashrc`: `alias dsh='node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js'` |

### Installation

#### Quick Install (Automated)

```bash
# Clone this repository
git clone https://github.com/Vengisk/deepseek-harness-termux.git
cd deepseek-harness-termux

# Run the automated installer
bash install.sh
```

#### Manual Installation

```bash
# 1. Install the dsh package globally
npm install -g @deepseek-ai/dsh@latest

# 2. Patch koffi for Android
DSH_DIR="$(npm root -g)/@deepseek-ai/dsh"
sed -i 's/#if defined(__linux__)/#if defined(__linux__) \&\& !defined(__ANDROID__)/' \
  "$DSH_DIR/node_modules/koffi/lib/native/base/base.cc"

# 3. Install sharp WebAssembly fallback
cd "$DSH_DIR"
npm install @img/sharp-wasm32

# 4. Apply cordis patch for web profile
mkdir -p "$HOME/.dsh/profiles/web"
cat > "$HOME/.dsh/profiles/web/cordis.patch.yml" << 'EOF'
- id: hmr
  disabled: true
- id: subprocess
  disabled: true
- id: bash-sandbox
  disabled: true
- id: permission
  disabled: true
EOF
```

### Usage

```bash
# Start the dsh web interface
node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js web

# Or with an alias set up
dsh web
```

When the server starts successfully, you should see output similar to:

```
✦ dsh web 成功启动了！服务器在 http://127.0.0.1:3080 上运行，返回 HTTP 200。
```

### Project Structure

```
deepseek-harness-termux/
├── README.md              # This file (bilingual)
├── LICENSE                # MIT License
├── patches/
│   ├── koffi-statx.patch  # Patch for koffi statx() syscall
│   └── cordis.patch.yml   # Cordis plugin compatibility patch
└── install.sh             # Automated installation script
```

### Compatibility Matrix

| Component | Status | Notes |
|---|---|---|
| `dsh web` | ✅ Working | Fully functional. Server runs on `http://127.0.0.1:3080`. |
| `dsh headless` | ✅ Working | Single-session headless mode. |
| `dsh plugin` | ✅ Working | Plugin management via pnpm. |
| HMR (Hot Reload) | ❌ Disabled | Requires `--expose-internals`; disabled by default in cordis patch. |
| Subprocess | ❌ Disabled | Requires `node-pty` (native module). |
| Bash Sandbox | ❌ Disabled | Requires `node-pty` (native module). |
| Permission System | ❌ Disabled | Requires `node-pty` (native module). |

### Acknowledgements

- **[DeepSeek AI](https://github.com/deepseek-ai)** — for creating the original [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) project, an excellent agent harness framework.
- **Termux Community** — for maintaining the Android terminal environment that makes this possible.
- **koffi** — for the fast C FFI module (patched for Android compatibility).
- **sharp** — for the high-performance image processing library (WebAssembly fallback available).

---

## Chinese

`deepseek-harness-termux` 是一个社区维护的兼容层，将官方 [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness) CLI 移植到 Android 环境（[Termux](https://termux.com/)）上运行。官方包专为基于 glibc 的 Linux 发行版构建，依赖多个原生模块，这些模块在 Android 的 Bionic libc 上要么编译失败，要么运行异常。本仓库记录了在 Termux 上运行所需的四个修复方案，并提供自动化安装脚本。

### 系统要求

- **Android 12+** 推荐（更早版本可能也可运行，但未经测试）
- **Termux** — 请从 [F-Droid](https://f-droid.org/en/packages/com.termux/) 安装（Play Store 版本不受支持且已过时）
- **Node.js >= 24** — 通过 `pkg install nodejs-lts` 或 `pkg install nodejs` 安装
- **npm**（Node.js 自带）
- **网络连接** — 用于下载依赖包

### 已知问题及修复方案

以下是 `@deepseek-ai/dsh` 在 Android/Termux 上发现的四个不兼容性问题及其解决方案：

#### 1. koffi statx() 系统调用

| 问题 | `koffi` 原生 FFI 模块调用了 Linux 特有的 `statx()` 系统调用，该调用在 Android 的 Bionic libc 中不存在。加载模块时会导致运行时崩溃 (`ENOSYS`)。 |
|---|---|
| **修复** | 在 `koffi/lib/native/base/base.cc` 第 2952 行，将 `#if defined(__linux__)` 改为 `#if defined(__linux__) && !defined(__ANDROID__)`。这会在 Android 上条件编译掉 `statx()` 路径，回退到 POSIX 标准的 `stat()`/`fstat()` 路径。 |
| **补丁** | [`patches/koffi-statx.patch`](patches/koffi-statx.patch) |

#### 2. sharp 原生二进制（图像处理）

| 问题 | `sharp` 图像处理库为 Linux x64/arm64 提供了预编译原生二进制，但不支持 Android/Termux。安装会因找不到或无法加载原生二进制而失败。 |
|---|---|
| **修复** | 安装 `@img/sharp-wasm32` 作为 WebAssembly 回退方案。这提供了一个完全功能、可移植的 `sharp` WebAssembly 构建，无需原生编译即可在任何平台上运行。在 dsh 包目录中运行 `npm install @img/sharp-wasm32`。 |
| **参考** | [`@img/sharp-wasm32` 在 npm 上](https://www.npmjs.com/package/@img/sharp-wasm32) |

#### 3. node-pty / Cordis 插件不兼容

| 问题 | `node-pty` 原生模块（`subprocess`、`bash-sandbox` 和 `permission` 插件所需）在没有完整 Android NDK 的 Termux 上无法编译。此外，`cordis-plugin-hmr`（热模块替换）需要 `--expose-internals` Node.js 标志。 |
|---|---|
| **修复** | 通过 `cordis.patch.yml` 在 web profile 中禁用不兼容的插件（`$DSH_HOME/profiles/web/cordis.patch.yml`）。禁用的插件包括：`hmr`、`subprocess`、`bash-sandbox`、`permission`。 |
| **补丁** | [`patches/cordis.patch.yml`](patches/cordis.patch.yml) |

#### 4. `--expose-internals` Node.js 标志

| 问题 | `cordis-plugin-hmr` 插件访问了 Node.js 内部模块（如 `node:internal/modules`）。从 Node.js 22+ 开始，这些内部模块默认不再可访问，需要 `--expose-internals` CLI 标志。 |
|---|---|
| **修复** | 使用 `node --expose-internals /path/to/dsh web` 代替 `dsh web` 命令启动。 |
| **建议** | 在 `~/.bashrc` 中添加别名：`alias dsh='node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js'` |

### 安装指南

#### 快速安装（自动化）

```bash
# 克隆本仓库
git clone https://github.com/Vengisk/deepseek-harness-termux.git
cd deepseek-harness-termux

# 运行自动化安装脚本
bash install.sh
```

#### 手动安装

```bash
# 1. 全局安装 dsh 包
npm install -g @deepseek-ai/dsh@latest

# 2. 为 Android 打 koffi 补丁
DSH_DIR="$(npm root -g)/@deepseek-ai/dsh"
sed -i 's/#if defined(__linux__)/#if defined(__linux__) \&\& !defined(__ANDROID__)/' \
  "$DSH_DIR/node_modules/koffi/lib/native/base/base.cc"

# 3. 安装 sharp WebAssembly 回退方案
cd "$DSH_DIR"
npm install @img/sharp-wasm32

# 4. 为 web profile 应用 cordis 补丁
mkdir -p "$HOME/.dsh/profiles/web"
cat > "$HOME/.dsh/profiles/web/cordis.patch.yml" << 'EOF'
- id: hmr
  disabled: true
- id: subprocess
  disabled: true
- id: bash-sandbox
  disabled: true
- id: permission
  disabled: true
EOF
```

### 使用方法

```bash
# 启动 dsh web 界面
node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js web

# 或者设置别名后直接使用
dsh web
```

启动成功时，您应该会看到类似如下的输出：

```
✦ dsh web 成功启动了！服务器在 http://127.0.0.1:3080 上运行，返回 HTTP 200。
```

### 项目结构

```
deepseek-harness-termux/
├── README.md              # 本文件（中英双语）
├── LICENSE                # MIT 许可证
├── patches/
│   ├── koffi-statx.patch  # koffi statx() 系统调用补丁
│   └── cordis.patch.yml   # Cordis 插件兼容性补丁
└── install.sh             # 自动化安装脚本
```

### 兼容性矩阵

| 组件 | 状态 | 说明 |
|---|---|---|
| `dsh web` | ✅ 正常工作 | 功能完整。服务器运行在 `http://127.0.0.1:3080`。 |
| `dsh headless` | ✅ 正常工作 | 单会话无头模式。 |
| `dsh plugin` | ✅ 正常工作 | 通过 pnpm 管理插件。 |
| HMR（热重载） | ❌ 已禁用 | 需要 `--expose-internals`；默认在 cordis 补丁中禁用。 |
| 子进程 | ❌ 已禁用 | 需要 `node-pty`（原生模块）。 |
| Bash 沙箱 | ❌ 已禁用 | 需要 `node-pty`（原生模块）。 |
| 权限系统 | ❌ 已禁用 | 需要 `node-pty`（原生模块）。 |

### 致谢

- **[DeepSeek AI](https://github.com/deepseek-ai)** — 感谢创建了优秀的 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 项目，一个出色的智能体开发框架。
- **Termux 社区** — 感谢维护了使这一切成为可能的 Android 终端环境。
- **koffi** — 感谢提供快速 C FFI 模块（已为 Android 兼容性打补丁）。
- **sharp** — 感谢提供高性能图像处理库（提供 WebAssembly 回退方案）。

---

## License

This project is licensed under the [MIT License](LICENSE), the same as the original [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) project.

---

*Maintained by [Vengisk](https://github.com/Vengisk) — not an official DeepSeek product.*