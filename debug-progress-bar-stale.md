# Debug Session: progress-bar-stale

Status: [OPEN]

## Symptom
Windows Flutter playback starts or falls back to remote playback, but the song progress bar does not update promptly.

## Hypotheses

1. The Windows audio plugin does not emit position events continuously.
2. AudioPlayerManager receives position updates but throttled notifications do not reach the progress UI.
3. A stale playback request pauses the player after the remote fallback starts.
4. The duration or position is repeatedly reset during source initialization.

## Instrumentation Plan

Add runtime-only observations around the player position/state streams and the progress-bar consumer. Reproduce one song from start and capture the ordered events.

## Evidence

Pending runtime reproduction.

## Fix

Pending evidence.
