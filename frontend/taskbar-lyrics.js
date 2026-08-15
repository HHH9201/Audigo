import { Events, Window } from "@wailsio/runtime";

const songInfo = document.getElementById("songInfo");
const lyricsText = document.getElementById("lyricsText");
const playedText = document.getElementById("playedText");
const remainingText = document.getElementById("remainingText");
const placeholder = "♪ ♫ ♪ ♫";

function getData(event) {
    return event?.data ?? event ?? {};
}

function updateLyrics(data) {
    const songName = String(data.songName || "").trim();
    const artist = String(data.artist || "").trim();
    const text = String(data.lyricsText || placeholder)
        .replace(/^\[\d+,\d+\]/, '')
        .replace(/<\d+,\d+,\d+>/g, '')
        .trim() || placeholder;

    songInfo.textContent = songName && artist ? `${songName} · ${artist}` : songName || artist;
    if (playedText && remainingText && data.playedText !== undefined) {
        playedText.textContent = String(data.playedText || '');
        remainingText.textContent = String(data.remainingText || '');
    } else {
        lyricsText.textContent = text;
    }
}

Events.On("taskbar-lyrics:update", (event) => {
    updateLyrics(getData(event));
});

Events.On("taskbar-lyrics:show", (event) => {
    updateLyrics(getData(event));
    Window.Show();
});

Events.On("taskbar-lyrics:hide", () => {
    Window.Hide();
});

Events.On("taskbar-lyrics:reset", () => {
    songInfo.textContent = "";
    if (playedText && remainingText) {
        playedText.textContent = "";
        remainingText.textContent = placeholder;
    } else {
        lyricsText.textContent = placeholder;
    }
});
