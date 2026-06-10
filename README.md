# VoiceKey

Personal macOS menu bar dictation app. Press a global hotkey in any app,
speak, and the transcript is inserted into the focused text field. Built for
two users (Victor and Cindy), two Apple Silicon Macs. macOS 14+.

Reliability rule #1: **never lose audio.** Every recording is written to disk
while capturing and tracked in a durable SQLite queue until transcription
succeeds — offline, crashes, and `kill -9` included.

## Features

- Global hotkey (default **Option+Space**), toggle or push-to-talk mode,
  **Esc** cancels. Configurable in Settings.
- Floating HUD with level meter, elapsed time, and cancel hint.
- OpenAI transcription (`gpt-4o-mini-transcribe` default, `gpt-4o-transcribe`,
  `whisper-1`), automatic language detection (handles mixed Chinese/English),
  custom-vocabulary prompt.
- Insertion: clipboard + synthetic ⌘V with clipboard restore (default), or
  typing simulation for paste-blocking apps. Password fields are detected and
  fall back to clipboard + notification.
- Durable queue: offline pause/resume, 2/4/8/16/30 s retry backoff (max 5),
  crash recovery on launch, manual retry from History.
- History popover with search and per-row copy / insert / retry / delete.
- Cost meter with user-editable per-model rates and a monthly alert.
- Limits: warn at 14:00, auto-stop at 15:00 (configurable); recordings over
  2 min upload as ~32 kbps m4a; 24 MB upload cap.

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
   (one shared project key; set a hard monthly budget cap on the project in
   the OpenAI dashboard as the backstop). The key is stored only in the macOS
   Keychain — never in files, UserDefaults, logs, or git. Click **Test** to
   verify.

## Usage

Press **Option+Space**, speak, press it again (or release, in push-to-talk
mode). The transcript is inserted where your cursor is. **Esc** while
recording cancels. The menu bar icon shows idle / recording / uploading /
error; the menu has the last transcript (click to copy), this month's cost,
History, and Settings.

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

Audio sent to the OpenAI API is subject to OpenAI's retention policy
(typically up to 30 days for abuse monitoring; API data is not used for
training). For stricter privacy a local model backend (whisper.cpp / MLX) is
the v2 path. Locally, transcript text is never logged at info level, and
history can be disabled entirely (history size 0).

## Architecture

| Module | Responsibility |
| --- | --- |
| `HotkeyManager` | global shortcut, toggle/push-to-talk, Esc cancel |
| `Recorder` | AVAudioEngine tap → incremental 16 kHz mono WAV on disk |
| `AudioTranscoder` | >2 min WAV → ~32 kbps m4a before upload |
| `TranscriptStore` | GRDB SQLite; state machine `recording → queued → uploading → done/failed`; launch recovery |
| `UploadQueue` | drains queue, NWPathMonitor offline pause, retry backoff |
| `TranscriberClient` | OpenAI multipart client, 60 s timeout, error classification |
| `Inserter` | paste / type strategies, secure-input fallback, clipboard guarantee |
| `CostMeter` | `ceil(seconds)/60 × rate`; monthly totals + alert |
| `SettingsStore` / `KeychainStore` | preferences (UserDefaults) / API key (Keychain) |
| `UI` | status item, recording HUD, history popover, settings window |

Manual test plan: [docs/QA.md](docs/QA.md).

## Non-goals (v1)

Streaming partial results, local models, voice-activity auto-stop, LLM
post-processing, chunked recordings over 15 min, App Store distribution.
