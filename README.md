# QuoteMessage — IM 消息快速引用

一个给 macOS 微信用的小工具：**按下快捷键 → 屏幕上给最近几条消息标上字母 → 按对应字母键 → 自动完成"引用"动作**。

不用鼠标、不用切换窗口、不用进右键菜单翻找，适合在群里快速接话。

![demo](docs/demo.gif)

---

## 为什么写这个

微信 Mac 版引用一条消息的标准操作是：把鼠标移到气泡上 → 右键 → 在弹出菜单里找"引用"→ 再点一下。消息一多、或者用外接键盘时，来回操作鼠标很打断节奏。

QuoteMessage 把这一连串动作压缩成两次按键：

1. `Ctrl+Q`（可改）触发
2. `A / B / C / …` 选中要引用的那一条

全程键盘完成，引用完成后微信输入框直接可以继续输入中文，没有焦点抖动。

---

## 功能概览

- **键盘优先**：默认快捷键 `⌃Q`，菜单里"更改快捷键…"一键录制任意组合（至少一个 ⌃/⌥/⇧/⌘ 修饰键）
- **自动识别消息气泡**：截图 + 像素分析定位聊天窗口里每条气泡的位置，不读取聊天内容，不依赖微信版本内部 API
- **字母叠层**：全屏透明 overlay 在每条消息旁画红色圆圈 + 字母（A–H），点击穿透不打扰任何操作
- **权限自查面板**：启动时如果缺权限自动弹窗，点对应按钮直接跳转系统设置
- **Universal Binary**：一个 `.app` 同时支持 Apple Silicon 和 Intel，体积约 650 KB

---

## 安装

### 方式一：下载 DMG（推荐）

1. 到 [Releases](../../releases) 下载最新的 `QuoteMessage-x.y.z.dmg`
2. 双击打开 → 把 `QuoteMessage.app` 拖到 `Applications`
3. 首次启动如果 Gatekeeper 挡住，右键 `QuoteMessage.app` → 打开 → 允许
4. 按照弹出的权限面板逐项授权（见下文"权限"段）

DMG 大约 **200 KB**，.app 本体 **650 KB**。

### 方式二：从源码构建

需要 Xcode 15+（或命令行工具里的 Swift 5.9+）：

```bash
git clone https://github.com/boblau8686/quote-message.git
cd quote-message/macos

# Universal (arm64 + x86_64) — 默认，产出一个通吃 Intel 和 Apple Silicon 的 .app
./build.sh

# 仅 arm64，编译快一点（本地迭代）
./build.sh --arm64

# 打成 DMG（会先调 build.sh --universal）
./build-dmg.sh --build
```

产物：
- `macos/dist/QuoteMessage.app`
- `macos/dist/QuoteMessage-<版本>.dmg`

不需要 Intel Mac 也能打 x86_64 版本 —— Apple Silicon 上的 Swift 工具链自带两个架构的编译目标。

---

## 权限

首次启动或打包后第一次运行会自动弹出"权限检查"面板，必须三项都绿勾才能正常使用：

| 权限 | 用途 | 不授权的症状 |
|---|---|---|
| **输入监控** | 监听全局快捷键（NSEvent global monitor） | 按快捷键完全没反应 |
| **辅助功能** | 点击右键菜单里的"引用"、合成鼠标事件 | 触发后看不到字母圈 / 引用没执行 |
| **屏幕录制** | 截图做气泡识别 | 出现"无法捕获微信窗口"错误 |

> **未签名 app 的小坑**：自己 `./build.sh` 重新编译后，macOS 认为这是"不同的 app"，之前授权的三项都会失效。在系统设置里删了重加有时也不管用——最可靠的方法是用命令行彻底重置：
> ```bash
> tccutil reset All com.quotemessage.app
> ```
> 执行后重新启动 QuoteMessage，权限面板会再次弹出，逐项授权即可。官方 Release 版以后会走 Apple Developer ID 签名，就没这个问题了。

---

## 日常用法

1. 光标在微信输入框里
2. 按 `⌃Q`（或你自己设的快捷键）
3. 屏幕上每条消息旁出现红色字母圈（A = 最新，往上 B、C、D…）
4. 按对应字母键 → 自动触发"引用"
5. 按 `Esc` 随时取消

想改快捷键：菜单栏红色 `Q` 图标 → "更改快捷键…"→"录制"→按下你想用的组合 → 保存。

---

## 技术栈

完全原生 Swift / AppKit / SwiftUI，无外部依赖：

- **键盘监听**：`NSEvent.addGlobalMonitorForEvents` 长期监听，`CGEventTap` 在 overlay 期间临时插入（以便吞掉按键）
- **截图 + 识别**：`CGWindowListCreateImage` → `CGContext` 重绘为 RGBA8 → 手写像素分析（直方图 mode 估背景、逐行检测气泡带、判断左右对齐）
- **覆盖层**：`NSPanel` + `nonactivatingPanel` + `statusBar` 级别，全屏跨所有 Space
- **右键 + 菜单点击**：`CGEvent.post(tap: .cgSessionEventTap)`（Session tap 而不是 HID tap — 前者在 IMS 之上，不会打断中文输入法状态）
- **菜单坐标定位**：通过 `CGWindowListCopyWindowInfo` 轮询新弹出的小窗口，用几何位置点击倒数第二项（"引用"）
- **权限探测**：`IOHIDCheckAccess` / `AXIsProcessTrusted` / `CGPreflightScreenCaptureAccess`，全部非打扰式（不会弹授权框）
- **日志**：`os.Logger`（统一日志）+ `/tmp/quotemessage.log`（兜底文件），打包版也能查
- **持久化**：`UserDefaults` 存自定义快捷键

### 目录结构

```
quote-message/
├── macos/                              ← macOS 原生版（Swift）
│   ├── Package.swift
│   ├── Sources/QuoteMessage/
│   │   ├── main.swift                  # NSApplication 入口
│   │   ├── AppDelegate.swift           # 状态栏 + 快捷键监听 + 管线调度
│   │   ├── Config.swift                # 全局常量（bundle id、阈值、颜色）
│   │   ├── Message.swift               # 检测结果数据类型
│   │   ├── BubbleDetector.swift        # 截图 + 像素分析
│   │   ├── LabelOverlay.swift          # 透明叠层 + CGEventTap 按键吞噬
│   │   ├── KeyCaptureTap.swift         # CGEventTap 封装（overlay 专用）
│   │   ├── QuoteAction.swift           # 右键 → 找弹窗 → 点"引用"
│   │   ├── HotkeyConfig.swift          # 快捷键持久化
│   │   ├── HotkeyRecorderWindow.swift  # "录制新快捷键"窗口
│   │   ├── Permissions.swift           # TCC 静默探测
│   │   └── PermissionsWindow.swift     # 权限自查面板
│   ├── Resources/Info.plist
│   ├── scripts/                        # 图标生成脚本
│   ├── build.sh                        # swift build → .app
│   └── build-dmg.sh                    # .app → DMG
├── windows/                            ← Windows 版（计划中）
└── docs/
    └── demo.gif
```

---

## 平台支持

- ✅ **macOS 12+**（在 macOS 15 / Apple Silicon 上开发验证）
- ✅ **Intel Mac**（通过 universal binary，同一个 DMG）
- 🚧 **Windows**：开发中
- 📋 **Linux**：计划中

---

## 常见问题

**按快捷键完全没反应？**
看 `/tmp/quotemessage.log`：
- 没有 `hotkey fired` → 输入监控没授权；到系统设置 → 隐私与安全性 → 输入监控里删掉旧 QuoteMessage 条目再重新加
- 有 `hotkey fired` 但没 `detected N messages` → 辅助功能 / 屏幕录制权限的问题
- 启动时 `perm: xxx = denied` 会列出哪些没授权

**识别不到消息气泡？**
`BubbleDetector` 的阈值在 `Config.swift` 里：
- 深色模式 / 浅色模式都支持（背景色是动态估计的，不是硬编码）
- 如果你魔改了微信主题，可能要调 `bubbleBGThreshold`、`sentGreenDelta`
- 日志里会打 `bg estimate rgb=(...)` 和 `found N vertical bands` / `after filtering: N bubbles`

**引用了下一条消息 / 上一条消息？**
右键菜单的坐标偏了，调 `Config.swift` 里的 `popupBottomPadPt`：
- 点到了"删除" → 调大
- 点到了"引用"上一项 → 调小

**快捷键和系统或 Terminal 冲突（比如 `⌃Q` 在 iTerm 里是关闭 tab）？**
菜单栏 → 更改快捷键…→ 换成任意组合，比如 `⌥⇧Q` 或 `⌘⌥Q`。

---

## 开发

```bash
cd macos

# 开发快速构建
./build.sh --arm64 --debug

# 运行（日志同时出到 stderr 和 /tmp/quotemessage.log）
./dist/QuoteMessage.app/Contents/MacOS/QuoteMessage

# 打 release universal
./build.sh

# 出 DMG
./build-dmg.sh --build
```

查日志：
```bash
tail -F /tmp/quotemessage.log
```

---

## License

MIT

---

## Credits

**macOS**
- Swift / AppKit / SwiftUI / CoreGraphics / ApplicationServices（Apple 一方库）

**Windows**（开发中）
- C# / .NET / Windows App SDK

**通用**
- 微信、企业微信、QQ —— 本项目是面向 IM 应用的**本地**辅助工具，不联网、不读聊天记录、不改客户端行为
