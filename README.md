# VoiceKey

Personal macOS menu bar dictation app. Press a global hotkey in any app, speak,
and the transcript is inserted into the focused text field. Built for two users
(Victor and Cindy), two Apple Silicon Macs.

Reliability rule #1: **never lose audio.** Every recording is written to disk
while capturing and tracked in a durable queue until transcription succeeds.

## M1: CLI spike

Quick end-to-end proof: record 3 seconds, transcribe, print.

```sh
cd voicekey-cli
export OPENAI_API_KEY=sk-...
swift run voicekey-cli
```

First run: macOS will prompt for microphone access for your terminal app.
Speak during the 3-second window (mixed Chinese/English is fine — language
detection is automatic). The transcript prints between `---` markers.

Options: `--seconds N`, `--model gpt-4o-mini-transcribe|gpt-4o-transcribe|whisper-1`,
`--keep` (keep the WAV), `--selftest` (3 s round trip, exit 0 on success).

The CLI reads the API key from the environment only — nothing is written to
disk or logged.

*(Full app documentation lands with M5.)*
