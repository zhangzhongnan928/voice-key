# VoiceKey iOS manual on-device QA

Keyboard extensions cannot be meaningfully tested in CI or the simulator
alone — run this on a real iPhone and iPad before each TestFlight upload.

## Install & permissions

- [ ] Install via TestFlight (or Ad Hoc). App launches with the Record tab.
- [ ] First record tap prompts for Microphone; grant it.
- [ ] Settings > API key: paste, **Test** shows "✓ Key works."
- [ ] Add the keyboard: iOS Settings → General → Keyboard → Keyboards →
      Add New Keyboard → VoiceKey Board.
- [ ] **Full Access toggle**: with Full Access OFF, the keyboard shows
      "Enable Full Access in Settings…" and Insert latest does nothing.
      Turn it ON → status changes to the normal hint.
- [ ] Verify the keyboard never asks for the API key — it has none by design
      (no network calls from the extension).

## Container app basics

- [ ] Record a short mixed Chinese/English sentence → transcript appears in
      History and as "last transcript" on the Record tab.
- [ ] Cancel during recording → no history row.
- [ ] Cost line increases after a dictation (per-device estimate label shown).
- [ ] History swipe actions: copy, retry (only on failed), delete.
- [ ] History size 0: new transcripts store no text.

## Keyboard: insert-latest (M2)

- [ ] In Notes, switch to VoiceKey Board, tap **Insert latest** → newest done
      transcript is inserted at the cursor.
- [ ] With no transcripts: status says "No transcript yet…", nothing inserted.

## Keyboard: mic handoff (M3)

- [ ] In Notes with VoiceKey Board active, tap **Dictate** → VoiceKey opens
      and recording starts automatically.
- [ ] Stop → "Transcript ready / swipe back" banner appears.
- [ ] Swipe back to Notes → the transcript inserts automatically, exactly
      once (switch away and back again: it must NOT insert a second time).
- [ ] **TTL expiry**: dictate via handoff, wait > 10 minutes, then return to
      Notes → nothing auto-inserts; Insert latest still works manually.
- [ ] Globe key switches keyboards.

## Secure & special fields (platform behavior, not bugs)

- [ ] Password fields: iOS forces the system keyboard — VoiceKey Board cannot
      appear. Expected by design.
- [ ] Phone-number fields: iOS falls back to the system keypad. Expected by
      design.

## Reliability

- [ ] **Airplane-mode retry**: enable airplane mode, record in the app →
      item stays queued. Disable airplane mode → completes without user
      action.
- [ ] Kill the app mid-upload (app switcher swipe-up), relaunch → item
      completes or fails cleanly with an error in History.
- [ ] Kill the app mid-recording, relaunch → partial audio is queued and
      transcribed.
- [ ] Wrong API key → single attempt, failed state, "Check API key in
      Settings." status.

## iPad

- [ ] Repeat: record, Insert latest, mic handoff, globe key. Layout sane in
      both orientations and Split View.
