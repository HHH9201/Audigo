# Debug Session: cache-success-no-play

Status: [OPEN]

## Symptom
The audio cache download succeeds, but the song does not start playing.

## Evidence Provided
- Cache download succeeds for `毛不易 - 无名的人 - 毛不易.flac`.
- Cache service returns a local cache URL.
- No corresponding playback success log was provided.

## Hypotheses
1. The remote proxy URL returns an HTTP or range error during playback.
2. WebView2 cannot decode the selected FLAC stream.
3. Playback continues using the remote proxy URL and does not switch to the newly cached local URL.
4. `audio.play()` is rejected by autoplay policy.

## Plan
Collect the exact playback URL, media error code, and play() rejection before changing playback logic.
