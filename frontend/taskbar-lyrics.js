import { Events, Window } from "@wailsio/runtime";

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
let lastPlayedCount = -1;

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
    }
}

function animateLyrics(timestamp) {
    if (lyricWords.length && lyricClockStart) {
        const currentTime = lyricStartTime + (timestamp - lyricClockStart) / 1000;
        renderWordProgress(currentTime);
    }
    animationFrame = requestAnimationFrame(animateLyrics);
}

function updateLyrics(data) {
    const songName = String(data.songName || "").trim();
    const artist = String(data.artist || "").trim();
    const rawLyricsText = String(data.lyricsText || '');
    const text = rawLyricsText
        .replace(/^\[\d+,\d+\]/, '')
        .replace(/<\d+,\d+,\d+>/g, '')
        .trim() || placeholder;
    const eventWords = Array.isArray(data.words) && data.words.length
        ? data.words
        : parseKRCWords(rawLyricsText);

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
    updateLyrics(getData(event));
});

animationFrame = requestAnimationFrame(animateLyrics);

Events.On("taskbar-lyrics:show", (event) => {
    Window.Show();
    updateLyrics(getData(event));
});

Events.On("taskbar-lyrics:hide", () => {
    Window.Hide();
});

Events.On("taskbar-lyrics:reset", () => {
    lyricWords = [];
    lyricWordText = [];
    lyricStartTimes = [];
    activeWordIndex = -1;
    lastPlayedCount = -1;
    lyricKey = '';
    lyricClockStart = 0;
    lastRenderedTime = 0;
    lyricsText.textContent = placeholder;
});
