# VoiceKey

Personal macOS menu bar dictation app. Press a global hotkey in any app,
speak, and the transcript is inserted into the focused text field. Built for
two users (Victor and Cindy), two Apple Silicon Macs. macOS 14+.

Reliability rule #1: **never lose audio.** Every recording is written to disk
while capturing and tracked in a durable SQLite queue until transcription
succeeds — offline, crashes, and `kill -9` included.

## Features

- Global hotkey (default **Option+Space**), toggle mode (push-to-talk is
  deferred until toggle is stable in daily use), **Esc** cancels.
- Floating HUD with level meter, elapsed time, and cancel hint.
- Crash-safe capture: audio is written incrementally to a truncation-tolerant
  CAF file; even a kill -9 mid-recording leaves transcribable audio.
- OpenAI transcription (`gpt-4o-mini-transcribe` default, `gpt-4o-transcribe`,
  `whisper-1`), automatic language detection (handles mixed Chinese/English),
  custom-vocabulary prompt.
- Insertion: clipboard + synthetic ⌘V (default), or typing simulation for
  paste-blocking apps. A focus guard skips pasting if you switched apps (or
  more than 120 s passed) — the transcript is copied instead. The previous
  clipboard is restored only if you didn't copy anything in between. Password
  fields always fall back to clipboard + notification.
- Durable queue: offline pause/resume, 2/4/8/16/30 s retry backoff (max 5,
  429 honors Retry-After), crash recovery on launch, manual retry from
  History. 401/403 fail immediately with a "check API key" notification.
- History popover with search and per-row copy / insert / retry / delete.
- Cost meter with user-editable per-model rates and a monthly alert —
  this device only (estimate); authoritative usage: OpenAI dashboard.
- Limits: warn at 14:00, auto-stop at 15:00 (configurable); recordings over
  2 min upload as ~32 kbps m4a, shorter ones as WAV; 24 MB upload cap.

## Building

Requirements: Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), an Apple Developer account.

```sh
xcodegen generate
DEVELOPMENT_TEAM=XXXXXXXXXX scripts/sign.sh     # dev build
xcodebuild test -project VoiceKey.xcodeproj -scheme VoiceKey \
    -destination 'platform=macOS,arch=arm64'    # unit tests
```

Dev builds are signed with your **Apple Development** certificate. The stable
signing identity matters: macOS ties privacy (TCC) grants to it, so
Microphone/Accessibility permissions persist across rebuilds.

### Release for both Macs

```sh
# one-time: store notary credentials
xcrun notarytool store-credentials voicekey-notary \
    --apple-id you@example.com --team-id XXXXXXXXXX

DEVELOPMENT_TEAM=XXXXXXXXXX scripts/release.sh
```

This archives (Release, arm64, hardened runtime), signs with **Developer ID
Application**, notarizes via `notarytool`, staples the ticket, and produces
`dist/VoiceKey-<version>.zip`. Unzip into `/Applications` on each Mac.

## First-run permission flow

1. **Launch VoiceKey** (menu bar mic icon appears; there is no Dock icon).
2. **Microphone** — macOS prompts on first launch (or first recording).
   Click Allow. If missed: System Settings → Privacy & Security → Microphone
   → enable VoiceKey.
3. **Accessibility** — needed to synthesize ⌘V / typing into other apps.
   VoiceKey triggers the prompt on first launch; enable VoiceKey in
   System Settings → Privacy & Security → Accessibility. Until granted,
   transcripts land in the clipboard with a notification instead.
4. **Notifications** — allow, so you see failures, password-field fallbacks,
   and the cost alert.
5. Open **Settings…** from the menu bar icon and paste the OpenAI API key
   (one shared project key). Set an OpenAI project monthly budget as the
   primary backstop. Enforcement may lag, so the in-app cost meter is
   advisory only. The key is stored only in the macOS Keychain — never in
   files, UserDefaults, logs, or git. Click **Test** to verify.

## Usage

Press **Option+Space**, speak, press it again to stop. The transcript is
inserted where your cursor is — provided you are still in the same app you
dictated into (focus guard); otherwise it is copied to the clipboard with a
notification. **Esc** while recording cancels. The menu bar icon shows
idle / recording / uploading / error; the menu has the last transcript
(click to copy), this month's cost, History, and Settings.

If you dictate into a password field, VoiceKey refuses to type there and puts
the text in the clipboard instead (you'll get a notification).

Recorded audio is deleted after successful transcription unless "Keep audio"
is on. Failed items always keep their audio so Retry can work.

## M1 CLI spike

A standalone end-to-end check lives in `voicekey-cli/`:

```sh
cd voicekey-cli
export OPENAI_API_KEY=sk-...
swift run voicekey-cli            # record 3 s, print transcript
swift run voicekey-cli --selftest # same, exits 0 on success
```

## Privacy

VoiceKey sends audio to OpenAI's /v1/audio/transcriptions endpoint. Per
OpenAI's current API data-controls documentation, API data is not used for
training by default, and the transcription endpoint is currently listed with
no abuse-monitoring retention and no application-state retention. Policies
can change; check OpenAI's current data-controls page before dictating
sensitive material. Do not dictate third-party confidential, medical, legal,
or regulated information unless you are comfortable sending it to the
configured API provider.

Locally, transcript text is never logged at info level, and history can be
disabled entirely (history size 0). For stricter privacy a local model
backend (whisper.cpp / MLX) is the v2 path.

## Architecture

| Module | Responsibility |
| --- | --- |
| `HotkeyManager` | global shortcut, toggle/push-to-talk, Esc cancel |
| `Recorder` | AVAudioEngine tap → incremental 16 kHz mono CAF on disk (truncation-tolerant) |
| `AudioTranscoder` | CAF → WAV (≤2 min) or ~32 kbps m4a (>2 min) upload artifact |
| `TranscriptStore` | GRDB SQLite; state machine `recording → queued → uploading → done/failed`; launch recovery |
| `UploadQueue` | drains queue, NWPathMonitor offline pause, retry backoff, Retry-After |
| `TranscriberClient` | OpenAI multipart client (30 s request / 600 s resource timeout), error taxonomy |
| `FocusGuard` / `Inserter` | focus + clipboard guards, paste / type strategies, secure-input fallback, clipboard guarantee |
| `CostMeter` | `ceil(seconds)/60 × rate`; monthly totals + alert |
| `SettingsStore` / `KeychainStore` | preferences (UserDefaults) / API key (Keychain) |
| `UI` | status item, recording HUD, history popover, settings window |

Manual test plan: [docs/QA.md](docs/QA.md).

## Non-goals (v1)

Streaming partial results, local models, voice-activity auto-stop, LLM
post-processing, chunked recordings over 15 min, App Store distribution.
