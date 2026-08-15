import { Events, Window } from "@wailsio/runtime";

console.log('[TaskbarLyrics] 页面脚本开始执行');

const songInfo = document.getElementById("songInfo");
const lyricsText = document.getElementById("lyricsText");
const placeholder = "♪ ♫ ♪ ♫";
let animationFrame = 0;
let lyricWords = [];
let lyricWordText = [];
let lyricStartTimes = [];
let activeWordIndex = -1;
let lyricStartTime = 0;
let lyricClockStart = 0;
let lyricKey = '';
let lastRenderedTime = 0;
let animationTickCount = 0;
let lastAnimationLogAt = 0;
let lastPlayedCount = -1;

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
    if (!lyricWords.length || !lyricsText) return;

    let nextIndex = activeWordIndex;
    while (nextIndex + 1 < lyricStartTimes.length && currentTime >= lyricStartTimes[nextIndex + 1]) {
        nextIndex += 1;
    }

    if (nextIndex !== activeWordIndex) {
        for (let index = activeWordIndex + 1; index < nextIndex; index += 1) {
            lyricsText.children[index]?.style.setProperty('--word-progress', '1');
        }
        activeWordIndex = nextIndex;
    }

    const span = lyricsText.children[activeWordIndex];
    if (span && activeWordIndex >= 0) {
        const word = lyricWords[activeWordIndex];
        const start = Number(word.startTime || 0);
        const end = Math.max(start, Number(word.endTime || start));
        const progress = currentTime <= start ? 0 : Math.min(1, (currentTime - start) / (end - start || 1));
        span.style.setProperty('--word-progress', `${progress}`);
    }

    if (activeWordIndex !== lastPlayedCount) {
        lastPlayedCount = activeWordIndex;
        debugLog('DOM 已更新', { currentTime: Number(currentTime.toFixed(3)), activeIndex: activeWordIndex });
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
        wordCount: Array.isArray(data.words) ? data.words.length : 0
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
        if (isNewLine) {
            lyricsText.replaceChildren(...nextWords.map((word) => {
                const span = document.createElement('span');
                span.className = 'lyric-word';
                span.textContent = word.text || '';
                return span;
            }));
        }
        const isSeek = Math.abs(nextTime - lastRenderedTime) > 0.8;

        lyricWords = nextWords;
        lyricWordText = nextWords.map((word) => word.text || '');
        lastPlayedCount = -1;
        activeWordIndex = -1;
        lyricStartTimes = nextWords.map((word) => Number(word.startTime || 0));
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
    if (!eventWords.length) {
        lyricsText.textContent = text;
    }
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
        lyricsText: !!lyricsText
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
    lyricWordText = [];
    lyricStartTimes = [];
    activeWordIndex = -1;
    lastPlayedCount = -1;
    lyricKey = '';
    lyricClockStart = 0;
    lastRenderedTime = 0;
    songInfo.textContent = "";
    lyricsText.textContent = placeholder;
});
