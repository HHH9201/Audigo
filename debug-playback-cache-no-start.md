# [OPEN] 播放地址成功但未开始播放调试记录

## 会话
- sessionId: playback-cache-no-start
- symptom: 日志显示成功获取缓存播放地址、成功获取歌词，但歌曲没有播放

## 可证伪假设
1. 缓存播放地址返回后没有传入播放器，或地址数组为空。
2. `audio.play()` 被拒绝或触发了音频错误。
3. 播放流程在设置歌曲信息、获取歌词后提前返回。
4. 任务栏歌词事件或播放器回调链导致初始化异常。
5. 缓存地址本身已失效，WebView2 无法加载。

## 观测点
- `playCurrentSong` 获取到的播放地址数量和实际调用播放器参数。
- `HTML5AudioPlayer.play` 的入口、`audio.src`、`audio.play` 成功/失败。
- 原生 audio 的 `play`、`error`、`pause`、`ended` 事件。
- 任务栏歌词事件是否在播放器初始化前后异常。

## 状态
等待用户复现并提供新增调试日志。
