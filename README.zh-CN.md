# deepseek-harness-termux

**在 Android / Termux 上运行完整的 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`@deepseek-ai/dsh`)— 功能完整全部可用。**

[English](README.md) | [简体中文](README.zh-CN.md)

---

`deepseek-harness-termux` 是一个社区维护的兼容层,将官方 [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness) 智能体框架移植到基于 [Termux](https://termux.com/) 的 Android 环境。官方 npm 包面向 glibc 系的 Linux 发行版构建,依赖的原生模块在 Android 的 Bionic libc 上要么编译失败、要么行为异常。本项目做法是直接修改关键源码以适配原生 Android 层,而不是禁用依赖这些模块的插件,让每个功能在 Termux 上都真实可用。

所有补丁均由干净的官方 tarball(`@deepseek-ai/dsh` `0.1.0-rc.6)`通过 `diff -u` 自动生成,精确、可复现。

## 功能状态

Termux 构建中所有插件均启用并可用:

| 组件 | 状态 | 说明 |
|---|---|---|
| `dsh web` | ✅ 正常 | 服务运行于 `http://127.0.0.1:3080` |
| `dsh headless` | ✅ 正常 | 单会话无头模式 |
| `dsh plugin` | ✅ 正常 | 插件管理 |
| HMR(热重载) | ✅ 正常 | 以 `--expose-internals` 启动 |
| 子进程 (Subprocess) | ✅ 正常 | `node-pty` 已针对 Android NDK(API 30)编译 |
| Bash 沙箱 | ⚠️ 有限 | `node-pty` 正常;`bubblewrap` 在运行时被 Android sepolicy 拦截,安全降级为 `SandboxUnavailableError`,不崩溃 |
| 权限系统 (Permission) | ✅ 正常 | 随 `node-pty` 一并恢复 |
| 会话持久化 | ✅ 已修复 | Android sepolicy 下 `link(2)` 回退为 `rename(2)` |
| Bash 终端 (PTY) | ✅ 已修复 | 在 Termux 上正确解析默认 shell 路径(`/usr/bin/bash`) |

## 系统要求

- **Android 12+** 推荐(更早版本可能可运行,但未经测试)
- **Termux** — 请从 [F-Droid](https://f-droid.org/en/packages/com.termux/) 安装(Play Store 版本不受支持且已过时)
- **Node.js >= 24**、**npm**、以及原生模块构建工具链:
  ```bash
  pkg update && pkg install nodejs-lts binutils make pkg-config clang python
  ```
- **网络连接** — 用于下载依赖包

## 安装

```bash
# 克隆本仓库
git clone https://github.com/Vengisk/deepseek-harness-termux.git
cd deepseek-harness-termux

# 运行自动化安装脚本(安装 dsh、应用补丁、编译 node-pty)
bash install.sh
```

安装脚本是幂等的 —— 重复执行时会跳过已应用的补丁和已构建的产物。

### 安装脚本原理

1. **全局安装** `@deepseek-ai/dsh`。
2. **应用 [`patches/`](patches/) 下的 Android 源码补丁**到已安装的各个包。
3. **编译 `node-pty`**:使用 Termux NDK 工具链,带 `-D__ANDROID_API__=30`(Bionic 目标)。
4. **修补 `koffi`**:在 Android 上剔除不支持的 `statx()` 系统调用(Bionic 中不存在,回退到 POSIX `stat()`/`fstat()`)。
5. **安装 `@img/sharp-wasm32`** 作为图像处理的可移植 WebAssembly 回退方案(无需原生编译)。
6. **冒烟测试**:验证 `node-pty` 可以加载、默认 shell 可以解析。

## 使用方法

以全插件模式启动 Web 界面:

```bash
node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js web
```

或在 `~/.bashrc` 中添加别名:

```bash
alias dsh='node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js'
```

`--expose-internals` 标志是必需的,因为 `cordis-plugin-hmr` 会访问 Node.js 内部模块(如 `node:internal/modules`),自 Node.js 22 起默认禁止访问。

## 源码补丁

| 补丁 | 目标包 | 修复内容 |
|---|---|---|
| [`01-terminal-bash-android-shell.patch`](patches/01-terminal-bash-android-shell.patch) | `dsh-terminal-bash` | 在 Termux 上解析真实存在的 shell(Android 没有 `/bin/bash`) |
| [`02-session-persistence-link-rename.patch`](patches/02-session-persistence-link-rename.patch) | `dsh-session-persistence-jsonl` | Android sepolicy 拒绝 `link(2)`(`EACCES/EPERM`)时回退为原子 `rename(2)` |
| [`03-subprocess-local-android.patch`](patches/03-subprocess-local-android.patch) | `dsh-subprocess-local` | 进程组检查(`kill(-pid, 0)`)将 `android` 视同 `linux` |
| [`04-host-apiproxy-termux-open-index.patch`](patches/04-host-apiproxy-termux-open-index.patch) | `dsh-host-apiproxy` | Android 下用 `termux-open` 打开路径/URL;启用原生路径检测 |
| [`04-host-apiproxy-termux-open-opener.patch`](patches/04-host-apiproxy-termux-open-opener.patch) | `dsh-host-apiproxy` | `lib/types/native-path-opener.js` 中的同类修复 |
| [`05-host-directory-picker-native-android.patch`](patches/05-host-directory-picker-native-android.patch) | `dsh-host-directory-picker-native` | Android 下目录选择走 Linux(zenity)路径 |
| [`koffi-statx.patch`](patches/koffi-statx.patch) | `koffi` | 在 Android 上有条件地编译掉 `statx()` 系统调用 |

## 兼容性说明

- **平台判定**:Termux 上 `process.platform` 为 `"android"`,上游 `platform === "linux"` 分支统一扩展为 `platform === "linux" || platform === "android"`。
- **Bash 沙箱**:`bubblewrap` 需要 `user_namespaces` 及特定 `/proc` 访问权限,Android sepolicy 会拒绝。框架在运行时检测到这一情况并安全降级为 `SandboxUnavailableError`,而不是崩溃 —— 子进程执行本身仍通过 `node-pty` 正常工作。
- **Termux 路径**:`termux-open` 会唤起 Android 的 VIEW intent(浏览器、文件查看器等)。

## 项目结构

```
deepseek-harness-termux/
├── README.md                  # 本文件(英文)
├── README.zh-CN.md            # 简体中文 README
├── LICENSE                    # MIT 许可证
├── install.sh                 # 自动化安装脚本(幂等)
└── patches/                   # 源码补丁(在各包目录内 patch -p1 应用)
    ├── 01-terminal-bash-android-shell.patch
    ├── 02-session-persistence-link-rename.patch
    ├── 03-subprocess-local-android.patch
    ├── 04-host-apiproxy-termux-open-index.patch
    ├── 04-host-apiproxy-termux-open-opener.patch
    ├── 05-host-directory-picker-native-android.patch
    └── koffi-statx.patch
```

## 致谢

- **[DeepSeek AI](https://github.com/deepseek-ai)** — 优秀的 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 智能体框架。
- **Termux 社区** — Android 终端环境。
- **koffi**、**node-pty**、**sharp** 的维护者。

## 许可证

MIT — 与官方 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 相同。参见 [LICENSE](LICENSE)。

---

*由 [Vengisk](https://github.com/Vengisk) 维护 — 非 DeepSeek 官方产品。*