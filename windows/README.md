# MsgDots Windows 原生版

Windows 版已改为 C++ / Win32 实现，不再依赖 C#、.NET、WPF 或 WinForms。目标是把这个小工具恢复到它应该有的体积：一个轻量托盘程序，而不是几十 MB 到上百 MB 的运行时包。

企业微信支持当前仅在 macOS 端开放；Windows 端仍保持现有微信支持范围。

## 功能

- 系统托盘常驻
- 默认全局快捷键：`Ctrl+Shift+D`
- 识别微信 / WeChat 窗口中的近期消息气泡
- 在全屏透明覆盖层上显示 `A-Z` 红色圆点
- 按字母选择消息后，模拟右键并点击微信菜单中的“引用”
- 按 `Esc` 取消覆盖层

托盘菜单目前提供三组轻量快捷键预设：

- `Ctrl+Shift+D`
- `Ctrl+Alt+D`

快捷键配置保存在 `%APPDATA%\MsgDots\settings.ini`。日志写入 `%APPDATA%\MsgDots\msgdots.log`。

## 构建

需要安装 Visual Studio 2022 Build Tools，并勾选 **Desktop development with C++**。

```powershell
cd windows
.\build-release.ps1 -Runtime win-x64
```

输出只有发布文件：

- `windows\release\MsgDots-0.3.0-win-x64-native.zip`

如果已安装 Inno Setup 6，可以同时生成安装包：

```powershell
cd windows
.\build-release.ps1 -Runtime win-x64 -Installer
```

安装器不再检测或安装 .NET Runtime，因为原生版没有 .NET 依赖。

## 哪个文件有用？

给用户发布时只需要二选一：

- 推荐：`windows\release\MsgDots-0.3.0-win-x64-setup.exe`
- 免安装绿色版：`windows\release\MsgDots-0.3.0-win-x64-native.zip`

构建过程中产生的 `.build` 目录只是临时目录，可以随时删除，不需要发布。

## 体积策略

当前实现只使用 Win32 API：

- 托盘：`Shell_NotifyIcon`
- 全局快捷键：`RegisterHotKey`
- 按键拦截：`WH_KEYBOARD_LL`
- 窗口截图：GDI `PrintWindow` / `BitBlt`
- 透明覆盖层：分层窗口 + color key
- 鼠标模拟：`SendInput`
- 设置：INI 文件

构建脚本使用 `/O1 /GL /OPT:REF /OPT:ICF /LTCG` 优先减小体积。最终大小取决于 MSVC 工具链、CRT 链接方式和图标资源大小；Release 目标应落在 KB 级，而不是 .NET 版本的几十 MB。

## 迁移备注

旧的 C# / WPF 源码暂时保留在 `windows\MsgDots` 作为行为参考。当前发布入口是 `windows\build-release.ps1` 编译 `windows\native\main.cpp`。
