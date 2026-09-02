# 拾音 (AudiGo)

让声音随行。基于**酷狗概念版**的第三方桌面端音乐播放器，使用 Flutter 构建，支持 Windows / macOS / Linux / Android。

> **声明**：本项目仅为学习研究用途的个人音乐播放器客户端，不存储任何音乐资源，所有歌曲数据均来自公开接口。请支持正版音乐。如有侵权请联系删除。

## 功能特性

- 在线播放：发现页推荐、私人FM、每日推荐、榜单/新歌/新碟
- 搜索：歌曲 / 歌手 / 专辑 / 歌单 / MV 综合搜索
- 逐字歌词：桌面歌词卡拉OK式逐字高亮显示（KRC 支持）
- 本地音乐：本地曲库扫描索引与播放
- WebDAV 云盘同步：音频文件上传至 `音乐文件/`、歌词上传至 `歌词文件/` 子目录
- MV 播放：获取 MV 直链并调起系统默认播放器
- 账号登录：手机验证码 / 二维码扫码登录
- 其他：播放历史、收藏夹管理、深色/浅色/磨砂主题切换、系统媒体键控制（SMTC / MPRIS）

## 后端说明

本项目依赖 [KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi) 提供的后端接口，你有两种部署方式：

### 方式一：本地部署自用

```bash
git clone https://github.com/MakcRe/KuGouMusicApi.git
cd KuGouMusicApi
npm install
node app.js   # 默认监听 http://localhost:40000
```

详细启动参数与配置请参考该仓库的 README 教程。

### 方式二：部署到自己的服务器 / 免费托管服务

可按照 [KuGouMusicApi](https://github.com/MakcRe/KuGouMusicApi) 仓库中提供的部署教程，将其部署到自己的云服务器，或使用 Vercel 等免费托管平台搭建私有服务。

## 客户端配置

客户端通过编译期常量注入后端地址与鉴权 token：

| 参数 | 说明 |
|---|---|
| `AUDIGO_API` | KuGouMusicApi 后端地址，默认 `http://localhost:40000` |
| `AUDIGO_API_TOKEN` | 后端鉴权 token（可选），后端启用了 token 校验时提供 |

示例 —— 指向本地后端调试：

```bash
flutter run -d windows --dart-define=AUDIGO_API=http://localhost:40000
```

示例 —— 指向自己的服务器（含 token 校验）：

```bash
flutter build windows \
  --dart-define=AUDIGO_API=https://your-server.com \
  --dart-define=AUDIGO_API_TOKEN=your_token
```

## 构建运行

环境要求：Flutter SDK 3.x

```bash
git clone https://github.com/HHH9201/AudiGo.git
cd AudiGo
flutter pub get
flutter run -d windows --dart-define=AUDIGO_API=http://localhost:40000
```

打包发布版：

```bash
flutter build windows --release --dart-define=AUDIGO_API=...
```

## 技术栈

- Flutter / Dart
- just_audio + just_audio_media_kit（libmpv 播放内核）
- audio_service（系统级后台播控）
- dio（网络请求）
- WebDAV（云盘同步）

## 参与贡献

开发环境配置、敏感信息规范与发布流程请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

见 [LICENSE](LICENSE)。
