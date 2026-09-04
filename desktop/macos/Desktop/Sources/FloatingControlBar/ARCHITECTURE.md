# Floating control bar architecture

This package owns the compact/notch presentation, Push-to-Talk coordination, and
the realtime voice transport. UI views render `FloatingControlBarState`; they do
not own a second chat provider or make semantic routing decisions.

## Push-to-talk entry points

`PushToTalkManager` owns the one microphone and turn lifecycle. Every ingress
enters that same state machine and none of them opens a second capture path or
transcript writer: the global shortcut monitor, the automation bridge, and the
composer mic button. `PushToTalkButtonTrigger` holds the click policy — which
existing transition a click resolves to, given the authoritative reducer phase —
and `PushToTalkMicButton` renders it for both the main-window composer and the
floating ask bar. A click carries no hold, so it takes the hands-free lane the
double-tap shortcut already drives: first click locks, next click finalizes.

## Voice typing ("type <text>")

A push-to-talk turn that opens with the spoken word "type" dictates into
whichever app owns the caret instead of asking Omi. `VoiceTypeSession` owns that
decision and nothing else does; `PushToTalkManager` asks it on every transcript
change and suppresses the chat dispatch (or the hub commit) only while it claims
the turn.

- The decision latches **one way**: once typing, always typing for that turn.
  Not-typing never latches, because the first on-device decode of a hold is a
  couple of characters of a half-spoken word — latching on that rejected every
  real turn before "Type" was fully said.
- `VoiceTypeCommandParser` is tri-state for the same reason: a transcript that is
  still a viable prefix of a wake word decides nothing.
- `VoiceTypeStabilizer` holds back the decoder's moving edge: text is typed once
  two consecutive decodes agree on it, and a word the newer decode is still
  spelling waits one probe. Whole words are released immediately (waiting there
  costs a word of latency and buys nothing) and an unchanged decode releases in
  full, so a pause catches up.
- `VoiceTypeStreamPlanner` turns each revised transcript into the smallest edit
  (backspaces + insertion), so recognizer revisions correct what is already on
  screen instead of appending a second wrong word.
- `CGEventKeystrokeSink` posts from a **private-state** event source. PTT is a
  modifier-only chord, so the user is physically holding Option while the events
  are posted; a `.hidSystemState` source would turn every dictated "n" into ⌥n.
- The realtime hub does not transcribe the user's own speech until after commit,
  which is far too late to type as they speak or to withhold the model's answer.
  So `PushToTalkManager` re-decodes the uncommitted window with the
  already-loaded Parakeet model (`PTTLanguageIdentifier.transcribe`, ~100 ms per
  probe) every 200 ms, on every route. `VoiceTypeAudioTrim` drops the quiet
  lead-in first: a hold begins at key-down, and handing seconds of room tone to
  the recognizer yields invented words, not silence.
- **Once the wake word is recognised the turn has its own pipeline**, whatever
  route the reducer chose at key-down: mic → on-device probes for the moving
  edge, the backend stream for the finished stretches, keystrokes out. The hub
  turn is released right then (`cancelTurn`), not at key-up — a hold can run for
  minutes, and streaming those minutes to a realtime model whose answer will be
  cancelled is spend for nothing, and would make that socket's lifetime the
  dictation's. Reducer route transitions under a long hold (the 1 s warm-wait
  deadline, a late hub-ready) are ignored for a claimed turn: the chunk handler
  checks the claim before any route branch, and `resolveRealtimeHubWarmWait` /
  `.fallbackToTranscription` return early. Key-up closes a claimed turn through
  one path (`finishVoiceTypingTurn`) on every route.
- `VoiceTypeDecodeWindow` is both the decode buffer and the turn's **timeline**.
  Every mic byte since key-down passes through it and `consumedBytes` counts what
  has been dropped, so a turn-relative position maps onto the pending audio.
  Once a stretch has been typed it is committed — text frozen, audio dropped —
  so probe cost and memory are bounded by the window and the hold has no length
  limit.
- **The backend stream commits by time.** `/v2/voice-message/transcribe-stream`
  (`velma-2` first) forwards only *finished* utterances, one per message, each
  at the pause that ended it; it never sends the whole transcript. Each final is
  folded in with `adoptStreamFinal(text:startByte:endByte:)`: it becomes the next
  committed stretch and the audio it covers is dropped, exactly like a local
  commit, and the probes carry on from there. Replacing the transcript with each
  message was the bug that froze dictation after the first pause — the second
  utterance no longer opened with "type", so nothing downstream would type it.
  Rules that keep the seams clean: the stream gets first claim on each pause
  (the local commit needs 1.5 s of quiet while the stream is healthy, 0.35 s
  otherwise); a final that begins inside already-committed audio is dropped, so
  no region is ever typed twice; a final that would leave a prefix the parser
  rejects (`stillDictates`) is refused, so a stream that lost the wake word
  cannot freeze the turn; a final that starts *after* the consumed edge never
  drops the gap unheard — live, one adopted across a 10 s gap lost two sentences
  that had only ever been the moving edge — so the manager decodes a speech gap
  on-device first (`uncommittedSpeech(before:)`) and commits both texts together,
  re-checking the window after the decode, and the window itself refuses a
  speech gap (`uncommittedSpeechBefore`); a window opening mid-sentence has its
  recognizer-capitalized first word lowered (`continuingSentence`, "However, A
  few" → "However, a few"); stream time zero is anchored to the window's consumed
  edge when the socket opens, and the pending audio is replayed to it then, so
  the stream hears the wake word too and positions survive a reconnect. Audio is
  sent live only while the socket is open.
- Two seam rules learned live. The stream's utterance `end` can land a few tens
  of milliseconds before the word it closes stops sounding; cutting there gave
  the next window the word's last syllable, typed as a word of its own
  ("thinking ng"). `adoptStreamFinal` slides the seam forward to the next quiet
  20 ms window (`VoiceTypeAudioTrim.quietBoundary`, 0.6 s lookahead). And a
  second hold into the same line landed flush against the first ("voiceI
  think"): at arming, `VoiceTypeSession` asks the sink whether the caret sits
  right after a word (`caretFollowsWordCharacter`, one character read through
  `AXStringForRange`) and types a separating space first; the space is on
  screen but not in the `Completion`.
- Keystrokes go only to the application that was frontmost when the turn
  armed. If focus moves, the session pauses (`focusTarget`) and catches up when
  it returns — live, a dock click brought Omi's own window forward mid-hold and
  two stream commits rewrote text inside it. A gap or flush remainder with less
  than 0.5 s of voiced audio (`VoiceTypeAudioTrim.speechBytes`) is not decoded:
  the on-device model answers a breath with "Thank you.".
- The on-screen keyword corrector (`PTTTranscriptContextualCorrector`) runs on
  the dictated text only, never on the wake word
  (`VoiceTypeCommandParser.correctingPayload`). Live, a window title containing
  "typ" made it rewrite "Type" itself; no probe parsed as a dictation, and the
  realtime model, hearing "type …", spawned an agent to do the typing.
- A stream commit is not typed by itself. It marks the next probe's push as
  *settled* (`voiceTypingSettleOnNextPush`): that push carries committed + the
  new window's decode, so the stream's corrections land inside the committed
  stretch however far back they reach
  (`VoiceTypeStreamPlanner.plan(for:rewritesFreely:)`) while the moving edge
  stays on screen. Pushing the committed prefix alone deleted the whole edge and
  retyped it a probe later — the "double up" flicker. Moving-edge revisions stay
  bounded to the last three words. Edits of 20+ backspaces are logged as shape.
- A claimed hub turn is **cancelled, never committed**, so the model never
  answers a dictation out loud.
- A finished turn reports a `Completion` carrying the text that actually reached
  the focused app — not the raw utterance, which still holds the "type" wake
  word. `PushToTalkManager` journals it as `Typed: <text>` through the ordinary
  `recordExchange` on the realtime voice surface, so a dictation persists and
  enters conversation context exactly like a spoken question and the next turn
  can refer back to it. The continuity key is derived from the turn, so a
  retried flush cannot write a second copy. Key-up asks the stream to finish
  and waits up to 0.6 s for its last utterance to land through the same commit
  path; whatever is still pending after that is closed by one on-device decode.
  The flush outlives the reducer's terminal, so `performTerminalCleanup` leaves
  the window and the stream alone while a flush is open (resetting them there
  lost the last word of every hold), and the flush corrects against the
  keywords pinned at key-up because cleanup clears the context snapshot.

- **Offline dictation.** `PTTRoutePolicy.decide` picks the route at key-down and
  checks the network first and unconditionally: with no path (`NetworkReachability`,
  an `NWPathMonitor`), the turn takes the `.onDeviceASR` route and is transcribed
  entirely by the already-loaded Parakeet model. Nothing waits on the hub's warm
  deadline to discover there was never a network, so the first keystroke lands as
  fast as it does online. A hub that reports itself admitted does not override
  this — it is a socket that *was* admitted, not one that can still carry the
  turn. Only dictation completes offline: answering needs a cloud model, so a
  non-dictation turn ends as `providerFailed` rather than pretending to be in
  flight. The route is a real case, not a reused `deepgramBatch`, so telemetry
  never reports Deepgram for a turn that never left the machine.

Guards: `Tests/VoiceTypingTests.swift`, `Tests/VoiceTypingSimulationTests.swift`.
Harness: `omi-ctl action ptt_manager_turn pcm=<s16le 16k> pace_ms=100 settle_ms=1500`
drives a real-time hold through the production chunk path and reports
`voice_typing_*` diagnostics.

## The pill's glass

`NotchGlassChrome.swift` owns every colour and surface value this package draws
with, and it is the only file here that may. It is `InkGlass` with **two** values
overridden — the appearance the material renders in, and the scrim painted over
it — because the notch pill is **black glass in both themes** (`SBTheme.pillBackground`)
while the rest of the app is pinned light. Everything else (the material, the
corner, the edge alpha, the Reduce Transparency behaviour) is deferred to, not
restated.

- Ink inside the pill is `NotchGlass.primary` / `.secondary` / `.quiet` — the
  white-on-black scale. `Ink.primary` is dynamic and resolves *dark* on the app's
  pinned-light panels, so a run of it here is near-black type on near-black glass.
- A surface that renders on **both** grounds (`PushToTalkMicButton`,
  `VoiceWaveformBars`, shared with the main-window composer) uses `Ink.*` instead,
  precisely because those tokens invert with the ground they land on.
- `floatingBackground(cornerRadius:)` applies the panel. Apply it once per
  **surface**, never per card: docked to the notch every card sits on
  `unifiedFloatingSurface`'s black dock shape, but undocked a notification is a
  bare sibling of the pill with no shared ground, so a card that does not paint
  its own renders over the desktop. Grounding at the call site that knows the
  presentation is what keeps a new card from being born invisible; grounding a
  card as well stacks a second scrim.
- **The panel matches the current rendered surface.** SwiftUI owns the hover
  morph; AppKit snaps once to the entering or settled size so it does not resize
  per animation frame or leave a transparent maximum-size window intercepting
  unrelated controls. The window keeps `hasShadow = false` and the glass draws
  no ambient shadow of its own.

Guards: `Tests/FloatingGlassChromeTests.swift`.

## Realtime hub

`RealtimeHubController` is the single owner of mutable voice-session state and
the facade used by `PushToTalkManager`. Its files are separated by lifecycle,
PTT ingress, provider callbacks, and authorized tool effects, but each
`RealtimeHubController` extension operates on that one state owner. Keep the
dependency direction as follows:

- `RealtimeHubController+SessionLifecycle` owns warm-session creation,
  replacement, context refresh, and output cleanup.
- `RealtimeHubController+PushToTalk` owns begin/feed/commit/cancel ingress.
- `RealtimeHubController+SessionDelegate` translates provider callbacks into
  reducer events and durable tool requests.
- `RealtimeHubController+Tools` performs only already-authorized local effects.
- Policy and value types (`RealtimeHubInputAdmission`, `RealtimeHubTools`,
  `RealtimeHubSessionPolicies`, and `RealtimeTurnPersistence`) stay pure or
  independently testable; they never acquire a second controller instance.

The controller may call the kernel-facing manager for typed context and durable
journal operations, but it must not reach directly into `ChatProvider` or make
agent-routing decisions. Provider tools remain untrusted until the kernel
returns an authorized command.

## Verification

Run the focused Swift tests with `xcrun swift test --package-path Desktop`, then
run `desktop/macos/scripts/agent-logic-harness.sh`. For PTT behavior changes,
also exercise a named `omi-*` development bundle; never target the production
Omi app.
