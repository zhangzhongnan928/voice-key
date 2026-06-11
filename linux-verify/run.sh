#!/bin/bash
# Runs the platform-independent decision-logic tests on any host with a
# Swift toolchain (no Xcode needed). Sources are copied from the canonical
# app locations so this never drifts from what ships.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Sources/PureLogic
cp ../VoiceKey/Sources/Insert/FocusGuard.swift \
   ../VoiceKey/Sources/Transcribe/RetryPolicy.swift \
   ../VoiceKey/Sources/Cost/CostMeter.swift \
   ../VoiceKey/Sources/Store/ItemState.swift \
   Sources/PureLogic/
swift test "$@"
