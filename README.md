<div align="center">

<img src="Docs/AppIcon.png" width="160" alt="Shirusu app icon">

# Shirusu

**Speech and text, both ways, on your own Mac.**

Transcribe a recording, caption what the Mac is playing, dictate into any app,
or have written text spoken back — with the models running locally.

</div>

---

## What it does

One recogniser behind four screens, because the jobs want opposite things from
the same machinery.

| | |
|---|---|
| **Transcribe** | Drop in a recording and read it back as text. The one mode with a document, a result, and something worth copying. |
| **Live Captions** | Hold the Globe key and a caption bar follows what is being said — the microphone, or whatever the Mac is playing. |
| **Dictation** | Hold the Globe key, speak, and the words are typed where your cursor already is, in whatever app you were in. |
| **Text to Speech** | Write something and hear it in a local voice: a ready one, your own copied from a recording, or one built from a description. |

Transcribe works before any permission has been granted, which is why a first
launch opens there.

## How it works

**Recognition** is Parakeet TDT v3 through [FluidAudio](https://github.com/FluidInference/FluidAudio)
— 25 languages, and unlike the streaming models it keeps punctuation and
capitalisation in Portuguese, including English terms dropped mid-sentence. The
decoder is pinned to the Latin script, which filters by writing system rather
than by language, so "commit" and "BMW" survive while the decoder stops drifting
into Cyrillic on unclear audio.

The same engine runs two windows. Captions take the proven long layout, where
confirmations are slower but the text settles correctly. Push-to-talk takes the
floor — 1 s chunks, 0.5 s of right context — because an utterance lasting
seconds would never confirm if it had to wait ten seconds for context. What you
keep from a dictation comes from a release pass over the whole utterance, so the
live stream is a progress indicator and nothing else.

**Rambler** cleans dictation up the way people actually speak it: the false
starts, the "no, wait, make that". Apple's on-device model does the work, so the
words never leave the Mac. Nothing it returns is trusted — every result is
checked against what was actually said (same language, same figures,
recognisably the same utterance) before it is typed anywhere, because a rewrite
that says something slightly different is worse than a stray "um": it is fluent,
and therefore invisible.

Seven built-in profiles ship — Faithful, Balanced, Aggressive, Formal, Formal
for a client, Casual, Shorter — and you can write your own. A profile marked as
a *transform* turns the resemblance checks off, for the case where a spoken
request is meant to become a page of prose.

**Text insertion** goes through the pasteboard and a synthesised ⌘V rather than
typing character by character: one event whatever the keyboard layout is, no
dead keys to map, instant instead of a visible crawl, and it survives
autocomplete. The whole pasteboard is saved and put back, not just the string.

**System audio** is captured with a Core Audio process tap, not ScreenCaptureKit.
A tap asks only for "System Audio Recording Only"; ScreenCaptureKit would demand
Screen Recording, put a capture indicator in the menu bar, and re-prompt
periodically — all to record audio it does not need the screen for.

**Speech** runs on Supertonic for ready voices (four compact Core ML stages, ten
voices, eight languages), Chatterbox for a quick voice copy (~1.7 GB, 24 kHz),
and VoxCPM2 for the higher-quality copy or a voice invented from a description
(~3.2 GB, 48 kHz, and the only one that will take a note on delivery).

**Models are let go of.** Each has an idle deadline sized to the cost of being
wrong — 2 minutes for the heavy voices, 10 for Supertonic, 30 for transcription
— and everything is handed back at once the moment the system reports memory
pressure. Both sides reload on next use, so that costs latency rather than
function.

## Requirements

- macOS 27 or later, Apple Silicon
- Xcode 27 (Swift 6)
- Disk for the models, fetched on demand: Parakeet on first launch, and a voice
  model only when you first ask Shirusu to speak in a way that needs one
  (Chatterbox ~1.7 GB, VoxCPM2 ~3.2 GB)

## Building

```sh
open Shirusu.xcodeproj
```

Build and run the **Shirusu** scheme. Swift Package Manager resolves the
dependencies on first open; the transcription model downloads on first launch,
with the window usable while it does — Text to Speech has nothing to do with the
recogniser and works throughout.

```sh
xcodebuild -scheme Shirusu -destination 'platform=macOS' build
xcodebuild -scheme Shirusu -destination 'platform=macOS' test
```

## Setting up the Globe key

Two things gate push-to-talk, and neither is in the app's gift:

1. **System Settings → Keyboard → "Press 🌐 to" → Do Nothing.** Otherwise macOS
   routes the key to the emoji picker or the input-source switcher.
2. **Accessibility permission**, for the event tap that reads the key while
   another app is frontmost. The tap is listen-only: it observes the press
   without swallowing it.

Dictation also needs Accessibility to paste into the focused app, the microphone
for what it hears, and — for captions off system audio — System Audio Recording.
Shirusu asks for each when the feature that needs it is first used.

## Layout

```
Shirusu/
  App/          AppModel, the activity state machine, design tokens, model residency
  ASR/          Model download and compile, batch transcription, vocabulary fixes
  Audio/        Microphone, system-audio tap, file replay, decoding, WAV/M4A export
  Dictation/    Rambler, rewrite profiles, provider config, text insertion
  Hotkey/       Globe key event tap
  Pipeline/     Transcript and the session that drives the engine
  TTS/          Local speech: Supertonic, Chatterbox, VoxCPM2
  Views/        SwiftUI screens, caption panel, activity strip
  Voice/        Saved voice profiles and enrolment
ShirusuTests/   51 tests, including runs against real recorded speech
```

Custom vocabulary corrects only whole words the recogniser is known to produce
— it cannot invent, paraphrase, or touch a word that is not listed. Every
built-in entry came from a transcript that was measured, not guessed.

## Privacy

Everything above runs on this Mac. The one exception is opt-in: Gemini may be
chosen instead of Apple Intelligence for rewriting dictation, for profiles that
deliberately turn a short utterance into a much longer document. Its API key
lives in the login Keychain, never in `UserDefaults`, and the default provider
is the on-device one.

## Localisation

English and Brazilian Portuguese, as string catalogs (298 strings).
