# 开发与贡献说明

感谢关注拾音 (AudiGo)！本文档面向开发者和贡献者，介绍本地开发环境配置、敏感信息规范与发布流程。后端部署与基础构建步骤请先阅读 [README](README.md)。

## 开发环境

- Flutter SDK 3.x（含对应平台的桌面/移动构建支持）
- Node.js 16+（用于本地运行 KuGouMusicApi 后端）
- 平台额外要求：
  - Windows：Visual Studio 2022（含 C++ 桌面开发工作负载）
  - macOS：Xcode
  - Linux：`clang`、`cmake`、`gtk`、`libmpv` 等开发库

## 本地开发配置

客户端的后端地址与鉴权 token 通过**编译期常量**注入，不要写入源码：

```bash
# 指向本地后端（无鉴权）
flutter run -d windows --dart-define=AUDIGO_API=http://localhost:40000

# 指向私有服务器（启用 token 校验）
flutter run -d windows \
  --dart-define=AUDIGO_API=https://your-server.com \
  --dart-define=AUDIGO_API_TOKEN=your_token
```

| 参数 | 默认值 | 说明 |
|---|---|---|
| `AUDIGO_API` | `http://localhost:40000` | KuGouMusicApi 后端地址 |
| `AUDIGO_API_TOKEN` | 空 | 网关鉴权 token，留空则不附加 `Authorization` 头 |

**推荐做法**：把带真实参数的启动命令保存为本地脚本（如 `run_local.bat` / `run_local.sh`），并在其中加入敏感参数。此类文件**不得提交**到仓库。

## 敏感信息规范

提交代码前请确保：

1. **不硬编码任何凭证**：token、密码、Cookie、API Key 一律通过 `--dart-define` 或运行时配置注入。
2. **不提交私有服务器地址**：示例统一使用 `your-server.com` 或 `localhost`。
3. **不提交本机运行产物**：`.window_pos.txt`、`.task/`、`build/` 等已在 [.gitignore](.gitignore) 中忽略。
4. **截图/演示素材脱敏**：不包含真实账号昵称、头像、收藏与播放记录。

### 发布前检查清单

- [ ] `git status` 无意外文件
- [ ] 全局搜索确认无 token / 私有域名残留
- [ ] `flutter analyze` 无错误
- [ ] 新增依赖已同步更新 `pubspec.yaml` 与 `pubspec.lock`（应用类项目提交 lock 文件）
- [ ] 新增第三方代码需附带其原始 LICENSE

## 目录结构

```
lib/
├── main.dart              # 应用入口与窗口初始化
├── models/                # 数据模型（歌曲、播放历史、歌单）
├── pages/                 # 页面（首页、搜索、收藏、下载等）
├── services/              # 核心服务
│   ├── music_api_service.dart    # 后端 API 封装
│   ├── audio_player_manager.dart # 播放器核心与看门狗
│   ├── media_cache_service.dart  # 音频/歌词缓存
│   ├── webdav_service.dart       # WebDAV 云盘同步
│   ├── desktop_lyrics_manager.dart # 桌面逐字歌词
│   └── ...
├── theme/                 # 主题与配色
└── widgets/               # 通用组件（歌词视图、播放栏等）
third_party/
└── just_audio_windows/    # 内置修改版 Windows 播放插件（保留原 LICENSE）
```

## 提交规范

- 使用清晰的 commit message，建议格式：`类型: 简述`（如 `fix: 修复歌词 429 重试`、`feat: 支持 MV 播放`）
- 一个 commit 聚焦一件事
- 涉及播放核心逻辑（`audio_player_manager.dart`）的改动请附上验证说明

## 许可证

提交即表示同意代码以 [MIT License](LICENSE) 发布。
