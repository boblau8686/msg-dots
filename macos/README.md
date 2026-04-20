# EasyQuote — Swift 重写版（macOS）

把 Python + PyQt 版（仓库根目录 `../`）迁移到 Swift + AppKit，
目标是把打包体积从 ~100 MB 降到 ~3 MB，并用原生 API 替换所有 PyObjC 胶水层。

Python 版会作为 PoC 一直保留在 `master` 分支上，作参考实现用。

## 当前进度

| 模块 | 状态 |
|---|---|
| SPM 项目骨架 + `build.sh` 打 `.app` | ✅ |
| 菜单栏 Q 图标 + 菜单 | ✅ |
| `NSEvent` 全局快捷键监听（Ctrl+Q 打日志） | ✅ |
| 权限自查面板（输入监控/辅助功能/屏幕录制） | ⬜ |
| 修改快捷键 UI | ⬜ |
| 气泡识别（`CGWindowListCreateImage` + 像素分析） | ⬜ |
| 字母叠层（`NSPanel` 透明置顶） | ⬜ |
| 引用动作（`AXUIElement` + 合成右键点击） | ⬜ |
| 引用后输入法回焦（`NSAppleScript` 调用） | ⬜ |

## 构建

```bash
cd swift-macos
./build.sh              # 通用二进制（arm64 + x86_64），release 配置
./build.sh --arm64      # 只为 Apple Silicon 编译，速度快
./build.sh --debug      # 调试版（带断言、符号）
```

产物在 `dist/EasyQuote.app`，直接双击即可运行（第一次可能要在"系统设置 →
安全性 → 输入监控"里手动加一下）。

## 直接跑源码（不打包）

```bash
swift run -c release
```

这样会在 terminal 里启动，stderr 日志直接可见，但**没有 Info.plist、没有 LSUIElement**，
所以 Dock 里会多一个无图标的进程、菜单栏图标会挤占常规 app 的位置——只适合看日志。

调试快捷键 / 菜单栏行为请用 `./build.sh` 生成 `.app` 再跑。

## 项目结构

```
swift-macos/
├── Package.swift              # SPM 配置，macOS 12+，单一可执行目标
├── Sources/EasyQuote/
│   ├── main.swift             # 入口：NSApplication.shared.run()
│   └── AppDelegate.swift      # 状态栏 + 全局键监视器（后续会拆分）
├── Resources/
│   └── Info.plist             # .app 的 Info.plist（含 LSUIElement / 隐私串）
├── build.sh                   # swift build → 组 .app 包
└── .gitignore
```

后续模块加进来时会拆分成子目录（`Overlay/`、`MessageReader/`、`Action/`、
`Permissions/` 等），跟 Python 版的布局对应。
