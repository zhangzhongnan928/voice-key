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
- [ ] Push-to-talk mode: hold hotkey records, release stops.
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
- [ ] Safari password field: NOT typed/pasted; notification says transcript is
      in the clipboard; clipboard contains the transcript.

With strategy **Type**:

- [ ] TextEdit: transcript typed in, including Chinese characters and emoji.

## Reliability (acceptance gates)

- [ ] **Kill -9 mid-upload**: start a long dictation, stop it, immediately
      `kill -9` the VoiceKey process (Activity Monitor), relaunch. The item
      resumes and completes; transcript visible in History.
- [ ] **Kill -9 mid-recording**: kill while recording, relaunch. Partial audio
      is queued and transcribed (item shows partial text, not lost).
- [ ] **Airplane mode**: disable Wi-Fi, record. Item sits in queued state,
      icon shows uploading/error-free wait. Re-enable Wi-Fi: completes without
      any user action.
- [ ] Wrong API key: item fails after retries with a clear error in History;
      Retry works after fixing the key.
- [ ] Failed item keeps its audio file even with "keep audio" off.

## Limits

- [ ] Recording past 14:00 shows the warning notification.
- [ ] Recording hits 15:00: auto-stops and transcribes what was captured.
- [ ] Recording > 2 min uploads as m4a (check log category `net`), and
      transcript is still correct.
- [ ] Mid-recording, unplug/disconnect the input device (e.g. take out
      AirPods): recording stops gracefully and what was captured is queued.

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

## Misc

- [ ] Launch at login toggle survives reboot.
- [ ] Menu "last transcript" click copies it.
- [ ] No transcript text in `log stream --predicate 'subsystem == "com.victor.voicekey"' --level info`.
- [ ] Quit from the menu works while idle and while uploading (item resumes on
      next launch).
