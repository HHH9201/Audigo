import { Events, Window } from "@wailsio/runtime";

console.log('[TaskbarLyrics] 页面脚本开始执行');

const songInfo = document.getElementById("songInfo");
const lyricsText = document.getElementById("lyricsText");
const playedText = document.getElementById("playedText");
const remainingText = document.getElementById("remainingText");
const placeholder = "♪ ♫ ♪ ♫";
let animationFrame = 0;
let lyricWords = [];
let lyricStartTime = 0;
let lyricClockStart = 0;
let lyricKey = '';
let lastRenderedTime = 0;
let animationTickCount = 0;
let lastAnimationLogAt = 0;
let lastRenderedProgress = '';

function debugLog(message, data = undefined) {
    if (data === undefined) {
        console.log(`[TaskbarLyrics] ${message}`);
    } else {
        console.log(`[TaskbarLyrics] ${message}`, data);
    }
}

function getData(event) {
    return event?.data ?? event ?? {};
}

function parseKRCWords(rawText) {
    const match = String(rawText || '').match(/^\[(\d+),(\d+)\]([\s\S]*)$/);
    if (!match) return [];

    const content = match[3];
    const words = [];
    const pattern = /<([^>]+)>([^<]*)/g;
    let item;
    while ((item = pattern.exec(content)) !== null) {
        const parts = item[1].split(',').map(Number);
        if (parts.length < 2 || !Number.isFinite(parts[0]) || !Number.isFinite(parts[1])) continue;
        words.push({
            text: item[2],
            startTime: parts[0] / 1000,
            endTime: (parts[0] + parts[1]) / 1000
        });
    }
    return words;
}

function renderWordProgress(currentTime) {
    if (!lyricWords.length) {
        debugLog('跳过渲染：没有歌词字数据');
        return;
    }
    if (!playedText || !remainingText) {
        debugLog('跳过渲染：找不到 playedText/remainingText DOM', {
            playedText: !!playedText,
            remainingText: !!remainingText,
            lyricsText: !!lyricsText
        });
        return;
    }

    const played = lyricWords.filter((word) => currentTime >= Number(word.endTime || word.startTime || 0)).map((word) => word.text || '').join('');
    const remaining = lyricWords.filter((word) => currentTime < Number(word.endTime || word.startTime || 0)).map((word) => word.text || '').join('');
    const progress = `${played}|${remaining}`;
    playedText.textContent = played;
    remainingText.textContent = remaining;

    if (progress !== lastRenderedProgress) {
        lastRenderedProgress = progress;
        debugLog('DOM 已更新', {
            currentTime: Number(currentTime.toFixed(3)),
            played,
            remaining
        });
    }
}

function animateLyrics(timestamp) {
    animationTickCount += 1;
    if (lyricWords.length && lyricClockStart) {
        const currentTime = lyricStartTime + (timestamp - lyricClockStart) / 1000;
        if (timestamp - lastAnimationLogAt >= 1000) {
            lastAnimationLogAt = timestamp;
            debugLog('动画帧运行中', {
                animationTickCount,
                currentTime: Number(currentTime.toFixed(3)),
                wordCount: lyricWords.length
            });
        }
        renderWordProgress(currentTime);
    } else if (timestamp - lastAnimationLogAt >= 1000) {
        lastAnimationLogAt = timestamp;
        debugLog('动画帧运行中但未进入歌词计时', {
            animationTickCount,
            wordCount: lyricWords.length,
            lyricClockStart
        });
    }
    animationFrame = requestAnimationFrame(animateLyrics);
}

function updateLyrics(data) {
    const songName = String(data.songName || "").trim();
    debugLog('收到歌词更新事件', {
        songName,
        artist: String(data.artist || '').trim(),
        currentTime: data.currentTime,
        wordCount: Array.isArray(data.words) ? data.words.length : 0,
        hasPlayedText: data.playedText !== undefined
    });
    const artist = String(data.artist || "").trim();
    const rawLyricsText = String(data.lyricsText || '');
    const text = rawLyricsText
        .replace(/^\[\d+,\d+\]/, '')
        .replace(/<\d+,\d+,\d+>/g, '')
        .trim() || placeholder;
    const eventWords = Array.isArray(data.words) && data.words.length
        ? data.words
        : parseKRCWords(rawLyricsText);

    songInfo.textContent = songName && artist ? `${songName} · ${artist}` : songName || artist;
    if (eventWords.length) {
        const nextWords = eventWords;
        const nextKey = `${songName}|${artist}|${nextWords.map((word) => `${word.startTime}:${word.endTime}:${word.text}`).join('|')}`;
        const nextTime = Number(data.currentTime || 0);
        const isNewLine = nextKey !== lyricKey;
        const isSeek = Math.abs(nextTime - lastRenderedTime) > 0.8;

        lyricWords = nextWords;
        if (isNewLine || isSeek || !lyricClockStart) {
            lyricStartTime = nextTime;
            lyricClockStart = performance.now();
            debugLog('重置歌词动画时钟', {
                reason: isNewLine ? 'new-line' : isSeek ? 'seek' : 'initial',
                lyricStartTime: nextTime,
                wordCount: nextWords.length,
                firstWord: nextWords[0]
            });
        }
        lyricKey = nextKey;
        lastRenderedTime = nextTime;
        const hasProgressData = data.currentTime !== undefined || (Array.isArray(data.words) && data.words.length > 0);
        if (hasProgressData || isNewLine) {
            renderWordProgress(nextTime);
        }
    }
    if (playedText && remainingText) {
        if (data.playedText !== undefined || data.remainingText !== undefined) {
            playedText.textContent = String(data.playedText || '');
            remainingText.textContent = String(data.remainingText || '');
        } else if (!lyricWords.length) {
            remainingText.textContent = text;
        }
        return;
    }

    lyricsText.textContent = text;
}

Events.On("taskbar-lyrics:update", (event) => {
    debugLog('收到 taskbar-lyrics:update 事件');
    updateLyrics(getData(event));
});
debugLog('taskbar-lyrics:update 监听器已注册');

animationFrame = requestAnimationFrame(animateLyrics);
debugLog('requestAnimationFrame 已启动', { animationFrame });
debugLog('DOM 初始化状态', {
    songInfo: !!songInfo,
    lyricsText: !!lyricsText,
    playedText: !!playedText,
    remainingText: !!remainingText
});

Events.On("taskbar-lyrics:show", (event) => {
    debugLog('收到显示事件');
    updateLyrics(getData(event));
    Window.Show();
});
debugLog('taskbar-lyrics:show 监听器已注册');

Events.On("taskbar-lyrics:hide", () => {
    debugLog('收到隐藏事件');
    Window.Hide();
});

Events.On("taskbar-lyrics:reset", () => {
    debugLog('收到重置事件');
    lyricWords = [];
    lyricKey = '';
    lyricClockStart = 0;
    lastRenderedTime = 0;
    songInfo.textContent = "";
    if (playedText && remainingText) {
        playedText.textContent = "";
        remainingText.textContent = placeholder;
    } else {
        lyricsText.textContent = placeholder;
    }
});
