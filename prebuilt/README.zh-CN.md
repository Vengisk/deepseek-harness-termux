# dsh-termux — 预编译 Termux 部署方案(方案二)

[English](README.md) | 简体中文

---

将打过补丁的 [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness)
全局安装到 Termux,**完全无需编译**:原生模块(`node-pty`、`koffi`)已为
**android-arm64** 预编译(N-API,跨 Node 版本 ABI 稳定),不需要 `clang`、
`cmake`、NDK,也不用等待数分钟的编译。

## 安装 — 两种模式

### 全量模式(完全自包含,约 57MB)— 推荐

```bash
npm i -g https://github.com/Vengisk/deepseek-harness-termux/releases/latest/download/dsh-termux-full.tgz
dsh web
```

把**整个打过补丁的 dsh + node_modules**(含原生模块与 sharp wasm)打包成一个
自包含产物,普通 `npm i -g` 即可,无需 postinstall。与参考的 `dsh-termux` 包
行为一致:冷 npm 缓存时 npm 仍可能联网校验依赖;热缓存(或曾装过)时直接从包内
安装,很快。

### 精简模式(小,约 360KB)

```bash
npm i -g https://github.com/Vengisk/deepseek-harness-termux/releases/latest/download/dsh-termux.tgz
dsh web
```

postinstall 从 npm registry 拉取 `@deepseek-ai/dsh`(npmjs→npmmirror 自动回退)、
应用内置补丁、放入预编译原生模块。产物小;安装时需要联网。仅当在意 ~57MB
下载体积时选择此模式。

## postinstall 做的事(精简模式)

1. `npm install -g --ignore-scripts @deepseek-ai/dsh@<固定版本>`(只下载,不编译;registry 失败会自动回退 npmjs → npmmirror)
2. 应用 `patches/` 里的 Android 源码补丁
3. 放入预编译原生模块:
   - `node-pty/build/Release/pty.node`
   - `koffi/build/koffi/android_arm64/koffi.node`
4. 安装 `@img/sharp-wasm32`(sharp 的 WebAssembly 回退——attachment 插件在 android-arm64 上启动必需)
5. 修改 `dsh/lib/bin.js` 的 shebang,让 `dsh` 命令自动带上 `--expose-internals`(HMR 插件需要)

整个流程幂等——重复安装会重新应用补丁并重新放置原生模块(npm 会先重新解包 `dsh`)。

## 环境要求

- **arm64(aarch64)** 的 Termux——本包只提供 android-arm64 二进制
- Node.js `>= 22.19`(与 `@deepseek-ai/dsh` 要求一致)
- `patch`(`pkg install patch`)——精简模式应用源码补丁时需要

## 维护者:重建预编译包

在一台 arm64 Termux 设备上执行:

```bash
# 1. 先得到一份可用的打补丁安装(顺便把原生模块编译出来)
bash install.sh
# 2. 打包(默认两种模式都打)
DSH_DIR="$(npm root -g)/@deepseek-ai/dsh" bash scripts/build-prebuilt.sh
#    MODES=layered 或 MODES=full 只打其中一种
# 3. 把 dsh-termux.tgz 和 dsh-termux-full.tgz 上传到 GitHub Release,
#    用户即可从上面的 releases/latest/download 地址安装
```

原生模块是 N-API,因此 `dsh` 升级后仍可继续使用;只有当 `install.sh` 的补丁
针对新版本 dsh 更新时,才需要同步提升 `install.js` 里的 `DSH_VERSION` 并重建。

## 说明

- `dsh` 命令(由 `@deepseek-ai/dsh` 自身安装,或由全量包内置)通过修改后的
  shebang 自动带上 `--expose-internals`。
- 移动端 UI / 搜索等插件**不会**随本包安装;首次启动后可用
  `dsh plugin --profile web add ...` 自行添加。
