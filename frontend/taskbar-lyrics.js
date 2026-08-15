import { Events, Window } from "@wailsio/runtime";

const songInfo = document.getElementById("songInfo");
const lyricsText = document.getElementById("lyricsText");
const placeholder = "♪ ♫ ♪ ♫";

function getData(event) {
    return event?.data ?? event ?? {};
}

function updateLyrics(data) {
    const songName = String(data.songName || "").trim();
    const artist = String(data.artist || "").trim();
    const text = String(data.lyricsText || placeholder).trim() || placeholder;

    songInfo.textContent = songName && artist ? `${songName} · ${artist}` : songName || artist;
    lyricsText.textContent = text;
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
    lyricsText.textContent = placeholder;
});
