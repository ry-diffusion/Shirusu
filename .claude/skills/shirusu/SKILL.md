---
name: shirusu
description: Transcribe, speak and dub audio locally with Shirusu's `shirusu` CLI (Parakeet speech-to-text, Supertonic / Chatterbox / VoxCPM2 voices, all on this Mac). Use when the user wants to dub a video or app demo into another language, make localized voice-over for an app preview or tutorial, generate subtitles (SRT/VTT) or a transcript from audio or video, turn text into speech with a ready, cloned or described voice, or mentions Shirusu / 記す. Also for "dublar", "legendar", "transcrever", "narrar".
---

# Shirusu from the command line

`shirusu` runs Shirusu.app's own engines headlessly. It is sandboxed: always
go through the `shirusu` script (it turns paths into stdin/stdout), never call
the app binary with paths yourself.

```bash
shirusu transcribe <audio-or-video> [--format text|json|srt|vtt] [--language pt,en | --only ja] [-o out]
shirusu speak "text" -o out.wav [--language en] [--voice F1 | --profile NAME | --describe TEXT]
shirusu dub script.json -o dub.wav [--max-speed 1.25] [--sample-rate 48000] [--report]
shirusu voices          # JSON: ready voices, saved profiles, enabled engines, languages
shirusu languages [pt en ...] [--release-models]   # dictation languages; Apple models held
```

If `shirusu` is not on PATH, it lives in the Shirusu repo at `CLI/shirusu`
(`CLI/install.sh` links it into `~/.local/bin`). It needs Shirusu.app installed
(or `SHIRUSU_APP=/path/to/Shirusu.app`). Progress and warnings go to stderr;
results go to stdout or `-o`.

## Before anything: look at what is available

Run `shirusu voices` first and read it:

- `engines` — which voice models the user has switched on in Shirusu →
  Settings. A switched-off engine fails with exit code 69. **Do not work
  around it**; tell the user which switch to turn on.
- `profiles` — voices the user saved in the app (`--profile NAME`), copied
  with Chatterbox (`--engine quick`) or VoxCPM2 (`--engine detailed`).
  `checked: true` means the recording passed the app's quality check.
- `speechLanguages` — what ready voices and VoxCPM2 speak (pt en es fr de it ja ko).
- `quickCloneLanguages` — what Chatterbox can copy a voice into.
- `listeningLanguages` — what the transcriber hears (25 European languages).

First use of a voice model downloads it: Supertonic ≈ 160 MB, Chatterbox ≈
1.7 GB, VoxCPM2 ≈ 3.2 GB. **Ask the user before a run that would download
Chatterbox or VoxCPM2** if they have not used it before.

Choosing a voice, when the user has not said:
- Their own or a specific person's voice → `--profile` (only with that
  person's consent; saved profiles were recorded in the app for this).
- A neutral narrator → a ready voice, `F1`–`F5` / `M1`–`M5` (fast, small).
- A described character ("older man, hoarse, slow") → `--describe` (VoxCPM2).

## Dubbing workflow

Work in a folder next to the source, e.g. `dub/`.

**1. Transcribe with timings.** Video files are fine as input.

```bash
shirusu transcribe demo.mp4 --format json -o dub/source.json
```

`source.json` has `language`, `duration` and `segments` (`id`, `start`,
`end`, `text`), cut at sentences and pauses. Read it; fix obvious
mis-hearings of product names before translating.

The default engine (Parakeet) hears 25 European languages and works the
language out itself. When the source is in **Japanese, Chinese or Korean**, or
Parakeet comes back in the wrong language, use `--only <lang>` (e.g. `--only
ja`, `--only pt-BR`): Apple's on-device transcriber, held to that one
language. It downloads Apple's model for it the first time. The app may hold
only 5 such models; `shirusu languages` shows them and `--release-models`
frees all but the one dictation uses.

**2. Write the script for each target language** (`dub/script.<lang>.json`).
Keep every segment's `id`, `start` and `end`; replace `text` with the
translation. Add the voice once at the top level:

```json
{
  "language": "en",
  "voice": "F2",
  "duration": 61.52,
  "segments": [
    { "id": 1, "start": 0.08, "end": 1.04, "text": "Good afternoon." },
    { "id": 2, "start": 1.04, "end": 8.56, "text": "This is …" }
  ]
}
```

Voice fields (`voice`, `profile`, `describe`, `engine`, `direction`, `tone`,
`pace`, `language`) work at the top level and per segment; a segment's value
wins. `tone` (calm/natural/lively/dramatic) and `pace` (slow/normal/quick)
affect copied voices (Chatterbox); `direction` is a delivery note for
`--engine detailed`.

Translating for time, not just meaning:
- The room for a line is from its `start` to the next segment's `start`.
  Budget roughly **14–16 characters per second** for en/pt/es/fr/it/de and
  **7–9 per second** for ja/ko. Translations into Romance languages and
  German run 15–30 % longer than English: write tighter, not literal.
- Keep proper nouns, brand names and code identifiers unchanged.
- **Dubbing an app demo:** the narration should say UI labels exactly as the
  localized app shows them. Look for the app's string catalogs
  (`*.xcstrings`, `Localizable.strings`, `strings.xml`, i18n JSON) and use the
  target-language value for every button, tab or screen name mentioned.
- Numbers, dates and units in the target language's conventions.

**3. Render, then fix what did not fit.**

```bash
shirusu dub dub/script.en.json -o dub/voice.en.wav --report
```

Each line starts at its segment's `start`. A line longer than its room is
sped up (pitch kept) up to `--max-speed` (default 1.25×). stderr ends with a
summary and, with `--report`, a JSON line:
`{"fits":[{"id":3,"room":6.15,"spoken":12.28,"speed":1.25,"overflow":3.67,…}]}`.
For every line with `overflow > 0`: rewrite it shorter (aim for
`room × max-speed` seconds of speech) and render again. Two passes usually
settle it. Raising `--max-speed` past 1.3 starts to sound rushed — prefer
rewriting.

**4. Check what was actually said.** Transcribe the dub back and compare it
to the script; a voice model occasionally skips or garbles a word.

```bash
shirusu transcribe dub/voice.en.wav --language en --format srt
```

Re-render only if a line is wrong (for a single line, a script with just
that segment is quickest to test, then render the full script).

**5. Put it back on the video** (ffmpeg; ask before installing it if missing).

Replace the original voice entirely:
```bash
ffmpeg -y -i demo.mp4 -i dub/voice.en.wav -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k -shortest demo.en.mp4
```

Keep the original's music and effects quietly underneath (there is no voice
separation, so the original speech is audible too — use a low level):
```bash
ffmpeg -y -i demo.mp4 -i dub/voice.en.wav -filter_complex \
  "[0:a]volume=0.12[bed];[bed][1:a]amix=inputs=2:duration=first:normalize=0[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k demo.en.mp4
```

Subtitles for the same language come straight from the script: write an SRT
from its segments (`HH:MM:SS,mmm --> HH:MM:SS,mmm`), or add it as a track:
`ffmpeg -i demo.en.mp4 -i demo.en.srt -map 0 -map 1 -c copy -c:s mov_text -metadata:s:s:0 language=eng demo.en.subbed.mp4`.

For several languages, repeat steps 2–5 per language; step 1 is shared.

## Other jobs

- **Subtitles / transcript only:** `shirusu transcribe talk.m4a --format srt -o talk.srt`.
  `--language pt,en` overrides the saved priorities for that run. It keeps
  the output to the right alphabet; the model still detects the language.
- **Voice-over from a text script:** one line per segment in a dub script with
  `start` times spaced as you want, or `shirusu speak` per paragraph.
- **One-off speech:** `echo "Olá!" | shirusu speak -o ola.wav` (language is
  detected from the text when `--language` is omitted).

## Exit codes

0 ok · 1 engine error · 64 bad arguments · 65 bad input (script/audio) ·
66 missing input · 69 engine switched off or app not found.
