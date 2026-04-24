# MsgDots Windows 发布与瘦身方案

当前 Windows 版是 C# / .NET 8 / WPF + WinForms。功能代码很小，但如果发布成单文件，.NET Runtime、WPF、WinForms、CLR、JIT 和资源文件会显著影响 `MsgDots.exe` 体积；即使是 framework-dependent 单文件，也可能因为 WPF 原生依赖和单文件打包策略变得很大。

## 2026-04-25 实测体积

测试环境：Windows，`Release`，`win-x64`，脚本版本 `0.1.1`，Inno Setup 6.7.1。

| 发布方式 | 输出 | 实测体积 | 备注 |
|---|---|---:|---|
| framework-dependent + single-file | `windows\dist\publish-framework-win-x64\MsgDots.exe` | 139.52 MB | 需要 .NET 8 Desktop Runtime；当前脚本仍生成单文件 |
| framework-dependent + zip | `windows\release-assets\MsgDots-0.1.1-win-x64-framework.zip` | 58.19 MB | 可用于安装器输入 |
| framework-dependent + Inno Setup | `windows\release-assets\MsgDots-0.1.1-win-x64-setup.exe` | 44.63 MB | 安装时检测 .NET 8 Desktop Runtime |
| self-contained + compressed single-file | `windows\dist\publish-self-contained-win-x64\MsgDots.exe` | 63.38 MB | 用户无需预装 .NET |
| self-contained + zip | `windows\release-assets\MsgDots-0.1.1-win-x64-self-contained.zip` | 58.07 MB | 与 framework zip 基本相同 |

基于 2026-04-25 的实测，推荐主发布 `framework-dependent` 安装包，同时提供 `self-contained` 压缩 zip 作为免运行时备用。安装包体积最小，为 44.63 MB，并能在安装时检测 .NET 8 Desktop Runtime；self-contained zip 为 58.07 MB，适合不想让用户单独安装运行时的场景。

## 方案一：小体积安装版

framework-dependent 版本安装时检测用户电脑是否有 .NET 8 Desktop Runtime；没有则提示去微软官方下载。按当前脚本实测，Inno Setup 安装包是最小下载方案。

在 Windows 机器上安装 .NET 8 SDK 后执行：

```powershell
cd windows
.\build-release.ps1 -Mode framework -Runtime win-x64 -Installer
```

输出：

- `windows\dist\publish-framework-win-x64\MsgDots.exe`
- `windows\release-assets\MsgDots-0.1.1-win-x64-framework.zip`
- 如果已安装 Inno Setup 6 且 `ISCC.exe` 在 `PATH` 中，还会生成安装包：
  `windows\release-assets\MsgDots-0.1.1-win-x64-setup.exe`

安装器逻辑在 `installer\MsgDots.iss`：

- 检测 `Microsoft.WindowsDesktop.App` 8.x x64 是否已安装
- 未安装时提示用户安装 `.NET 8 Desktop Runtime x64`
- 打开微软官方下载页并中止安装

这种发布形态现阶段最适合推广：安装包最小，用户只在缺运行时时才需要额外安装。

## 方案一备用：自包含但压缩

如果必须做到“下载后无需安装 .NET”，可以发布自包含压缩单文件：

```powershell
cd windows
.\build-release.ps1 -Mode self-contained -Runtime win-x64
```

该模式会启用：

- `PublishSingleFile=true`
- `EnableCompressionInSingleFile=true`
- `SatelliteResourceLanguages=zh-Hans`
- `DebugType=none`
- `DebugSymbols=false`

它会比未压缩的自包含单文件小，但 WPF 自包含很难稳定压到 macOS Swift 版那种几百 KB 级别。当前实测 `MsgDots.exe` 为 63.38 MB，zip 为 58.07 MB，适合作为免运行时备用发布。

## 方案二：不用 .NET 重写

“直接使用 C# 原生语言”这条路需要澄清：C# 不是像 Swift/AppKit 那样的系统原生 GUI 栈。C# 程序通常仍依赖 .NET Runtime。

可选项：

| 路线 | 体积 | 可行性 | 备注 |
|---|---:|---|---|
| C# + WPF framework-dependent | 中 | 高 | 安装包实测 44.63 MB，当前主推荐；缺点是可能需要用户安装 .NET Desktop Runtime |
| C# + WPF self-contained | 中 | 高 | 单文件方便；当前压缩实测 exe 63.38 MB、zip 58.07 MB，适合作为免运行时备用 |
| C# + NativeAOT | 小 | 低 | WPF 不支持 NativeAOT，不适合当前 UI |
| C++ + Win32 API | 很小 | 高 | 最接近 macOS Swift 原生版，适合托盘、全局键盘 hook、截图、透明 overlay、右键菜单点击 |
| Rust + Win32 API | 小 | 高 | 体积可控，但 Win32 调用和 UI 开发比 C++ 更绕 |
| Rust/C++ + Tauri/WebView | 中等 | 中 | WebView2 运行时问题类似 .NET Runtime，不适合极小体积目标 |

如果目标是“Windows 安装包尽可能小、无需 .NET”，建议第二阶段重写为 C++ / Win32：

- 托盘：`Shell_NotifyIcon`
- 全局快捷键：`RegisterHotKey` 或低级键盘 hook
- 截图：GDI / Windows Graphics Capture
- 透明覆盖层：分层窗口 `WS_EX_LAYERED`
- 模拟右键和点击：`SendInput`
- 设置存储：注册表或 `%APPDATA%\MsgDots\config.json`

Rust 也能做，但对这个项目而言核心都是 Win32 API，C++ 的工具链和示例资料更直接。
