# MsgDots — macOS 原生版

MsgDots 的 Swift + AppKit 实现，用键盘在 IM 聊天窗口中操作消息气泡。

## 当前进度

| 模块 | 状态 |
|---|---|
| SPM 项目骨架 + `build.sh` 打 `.app` | ✅ |
| 菜单栏 M 图标 + 菜单 | ✅ |
| `NSEvent` 全局快捷键监听 | ✅ |
| 权限自查面板（输入监控/辅助功能/屏幕录制） | ✅ |
| 修改快捷键 UI | ✅ |
| 气泡识别（`CGWindowListCreateImage` + 像素分析） | ✅ |
| 红色字母点叠层（`NSPanel` 透明置顶） | ✅ |
| 引用动作（合成右键点击 → 点击菜单项） | ✅ |
| 企业微信支持（实验） | 🟡 |

## 构建

```bash
cd macos
./build.sh              # 通用二进制（arm64 + x86_64），release 配置
./build.sh --arm64      # 只为 Apple Silicon 编译，速度快
./build.sh --debug      # 调试版（带断言、符号）
```

产物在 `dist/MsgDots.app`，直接双击即可运行。首次运行需要授权输入监控、辅助功能和屏幕录制。

## 直接跑源码（不打包）

```bash
swift run -c release
```

这样会在 terminal 里启动，stderr 日志直接可见，但**没有 Info.plist、没有 LSUIElement**，
所以 Dock 里会多一个无图标的进程、菜单栏图标会挤占常规 app 的位置——只适合看日志。

调试快捷键 / 菜单栏行为请用 `./build.sh` 生成 `.app` 再跑。

## 项目结构

```
macos/
├── Package.swift              # SPM 配置，macOS 12+，单一可执行目标
├── Sources/MsgDots/
│   ├── main.swift             # 入口：NSApplication.shared.run()
│   └── AppDelegate.swift      # 状态栏 + 快捷键监听 + 管线调度
├── Resources/
│   └── Info.plist             # .app 的 Info.plist（含 LSUIElement / 隐私串）
├── build.sh                   # swift build → 组 .app 包
└── .gitignore
```
