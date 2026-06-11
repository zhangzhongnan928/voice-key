# VoiceKey manual QA checklist

Run on a real Mac before each release. Automated tests cover the state
machine, retry policy, cost math, settings, insertion planning, and the API
client; everything below needs a human, a microphone, and real apps.

## Setup

- [ ] Fresh build via `scripts/sign.sh` (dev) or `scripts/release.sh` zip.
- [ ] First launch prompts for Microphone; grant it.
- [ ] First launch prompts for Accessibility (System Settings opens); grant it.
- [ ] Settings > API: paste key, **Test** shows "✓ Key works."
- [ ] Quit and relaunch: no permission prompts again (stable signing identity).

## Recording basics

- [ ] Option+Space starts recording: menu bar icon turns to record state, HUD
      appears near top of screen with moving level meter and timer.
- [ ] Speaking moves the level meter; silence drops it.
- [ ] Option+Space again stops; transcript appears in the focused field.
- [ ] Esc during recording cancels: no transcript, no history row, audio file
      removed.
- [ ] (Push-to-talk is deferred per CR-8 — verify the mode setting is hidden.)
- [ ] Start sound and stop sound play (Settings > Sounds on); disable and
      verify silence.
- [ ] Mixed Chinese/English sentence transcribes correctly with language blank
      (auto).
- [ ] Custom vocabulary: add an unusual product name in Settings, dictate it,
      verify the spelling improves.

## Insertion matrix (acceptance gate)

With strategy **Paste**:

- [ ] TextEdit: transcript inserted at the cursor.
- [ ] Chrome address bar: inserted.
- [ ] Slack message box: inserted.
- [ ] Cursor editor: inserted.
- [ ] Clipboard contents from before dictation are restored ~0.5 s after
      insertion.
- [ ] **Clipboard safety (CR-3)**: trigger insert, immediately copy something
      else during the restore delay — your new copy survives, no overwrite.
- [ ] Safari password field: NOT typed/pasted; notification says transcript is
      in the clipboard; clipboard contains the transcript.
- [ ] **Focus safety (CR-2)**: start dictation in TextEdit, switch to Safari
      before completion — transcript is copied, NOT pasted into Safari;
      notification names both apps ("Focus changed from TextEdit to Safari").
- [ ] Focus guard window: with the window set to e.g. 30 s, stay in the same
      app but let the transcript arrive later than 30 s (airplane mode trick)
      — clipboard only, no paste.

With strategy **Type**:

- [ ] TextEdit: transcript typed in, including Chinese characters and emoji.

## Reliability (acceptance gates)

- [ ] **Kill -9 mid-upload**: start a long dictation, stop it, immediately
      `kill -9` the VoiceKey process (Activity Monitor), relaunch. The item
      resumes and completes (or fails cleanly with an error in History).
- [ ] **Kill -9 mid-recording (CR-1)**: kill while recording, relaunch. The
      partial CAF capture appears in the queue, is transcoded, and
      transcribes (item shows partial text — never lost).
- [ ] **Airplane mode**: disable Wi-Fi, record. Item sits in queued state,
      icon shows uploading/error-free wait. Re-enable Wi-Fi: completes without
      any user action.
- [ ] **Bad API key (CR-4)**: wrong key → exactly one request (no retry
      loop), item failed with the error stored, notification says
      "Check API key in Settings." Retry works after fixing the key.
- [ ] **Rate limit (CR-4)**: mocked/unit-tested — 429 with `Retry-After: 7`
      waits about 7 s before the next attempt (covered by
      `UploadQueueRetryTests`).
- [ ] Failed item keeps both its CAF capture and upload artifact even with
      "keep audio" off; done items delete both (unless keep-audio is on).

## Limits

- [ ] Recording past 14:00 shows the warning notification.
- [ ] Recording hits 15:00: auto-stops and transcribes what was captured.
- [ ] Recording > 2 min uploads as m4a, ≤ 2 min as wav (check log category
      `net`), and transcript is still correct.
- [ ] 15-minute recording encodes to ≤ 24 MB and uploads, or fails with a
      clear "over the 24 MB upload limit" error — no silent loss.
- [ ] Mid-recording, unplug/disconnect the input device (e.g. take out
      AirPods): recording stops gracefully and what was captured is queued.
- [ ] Disk full (or simulate by revoking write access to the audio folder):
      recording fails with a notification, app does not crash.
- [ ] **Mic permission denied**: revoke Microphone in System Settings,
      attempt to record — clear prompt/notification directing to
      System Settings > Privacy & Security > Microphone; no crash.
- [ ] **Accessibility denied**: revoke Accessibility — recording and
      transcription still work; insertion falls back to clipboard +
      notification naming the missing permission.

## History

- [ ] Rows show timestamp, duration, first line, state icon, app name.
- [ ] Copy puts the full text in the clipboard.
- [ ] Insert re-inserts into the previously focused app.
- [ ] Retry appears only on failed rows and works.
- [ ] Delete removes row (and audio file if kept).
- [ ] Search filters by text.
- [ ] History size N: oldest rows pruned beyond N. N=0: new transcripts do
      not store text.

## Cost meter

- [ ] Menu shows "This month: $X.XX" and it increases after a dictation by
      ceil(seconds)/60 × rate.
- [ ] Edit a model rate in Settings; next dictation uses the new rate.
- [ ] Set the monthly threshold just below the current total + next item:
      crossing it fires exactly one notification (not repeated).
- [ ] CR-6 label present in Settings > Cost and as menu tooltip:
      "This device only (estimate). Authoritative usage: OpenAI dashboard."

## Misc

- [ ] Launch at login toggle survives reboot.
- [ ] Menu "last transcript" click copies it.
- [ ] No transcript text in `log stream --predicate 'subsystem == "com.victor.voicekey"' --level info`.
- [ ] Quit from the menu works while idle and while uploading (item resumes on
      next launch).
