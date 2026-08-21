# Debug Session: taskbar-lyrics-embed
- **Status**: [OPEN]
- **Issue**: 将 Go/Wails 的 Windows 任务栏内嵌歌词迁移到 Flutter 多窗口实现
- **Debug Server**: Pending
- **Log File**: `.dbg/trae-debug-log-taskbar-lyrics-embed.ndjson`

## Reproduction Steps
1. 启动 Flutter Windows 客户端。
2. 在设置或托盘中开启桌面歌词。
3. 检查歌词窗口是否成为 Windows 任务栏子窗口，而非任务栏上方浮窗。

## Hypotheses
| ID | Hypothesis | Observation |
|---|---|---|
| A | Go 使用 `Shell_TrayWnd` 与 `SetParent` 实现真实挂载 | 原版原生调用与窗口样式 |
| B | Flutter 子 Engine 当前窗口 HWND 可作为挂载子窗口 | MethodChannel 返回的窗口句柄与 PID |
| C | 挂载前必须切换为 `WS_CHILD` 并移除顶层样式 | `GetWindowLongPtr` 前后值及 `SetParent` 结果 |
| D | Explorer/任务栏重建后必须重新挂载 | 父窗口句柄变化及重挂载结果 |
| E | 任务栏实际矩形决定歌词区域 | `GetWindowRect(Shell_TrayWnd)` 与最终位置 |

## Evidence
- 2026-08-20 pre-fix probe reached `taskbar_lyrics_plugin.cpp:ReportProbe` from the desktop lyrics child Engine.
- `flutterView=4131920`, `topLevel=50597394`, `parent=0`, confirming the lyrics window is still a top-level window.
- `taskbar=65844`, `taskbarRect=[0,1392,2560,1440]`, `taskbarClient=[0,0,2560,48]`.
- `style=348848128`, `exStyle=264`; no attach or style mutation was performed.

## Verification
- `flutter analyze lib/widgets/desktop_lyrics_window.dart`: passed.
- `flutter run -d windows --debug`: built and launched successfully from the ASCII drive mapping `X:\flutter_client`.
- Debug server received 1 `pre-fix` event for hypotheses B, C, and E.
