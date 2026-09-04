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
  full, so a pause catches up. Without this the tail is typed and rewritten every
  probe, which is what "real time but glitchy" looks like.
- `VoiceTypeStreamPlanner` turns each revised transcript into the smallest edit
  (backspaces + insertion), so recognizer revisions correct what is already on
  screen instead of appending a second wrong word.
- `CGEventKeystrokeSink` posts from a **private-state** event source. PTT is a
  modifier-only chord, so the user is physically holding Option while the events
  are posted; a `.hidSystemState` source would turn every dictated "n" into ⌥n.
- The realtime hub does not transcribe the user's own speech until after commit,
  which is far too late to type as they speak or to withhold the model's answer.
  On that route `PushToTalkManager` re-decodes the growing turn buffer with the
  already-loaded Parakeet model (`PTTLanguageIdentifier.transcribe`, ~130 ms per
  probe) every 300 ms. `VoiceTypeAudioTrim` drops the quiet lead-in first: a hold
  begins at key-down, and handing seconds of room tone to the recognizer yields
  invented words, not silence.
- A claimed hub turn is **cancelled, never committed**, so the model never
  answers a dictation out loud.
- A finished turn reports a `Completion` carrying the text that actually reached
  the focused app — not the raw utterance, which still holds the "type" wake
  word. `PushToTalkManager` journals it as `Typed: <text>` through the ordinary
  `recordExchange` on the realtime voice surface, so a dictation persists and
  enters conversation context exactly like a spoken question and the next turn
  can refer back to it. The continuity key is derived from the turn, so a
  retried flush cannot write a second copy. Because the closing decode lands
  after key-up, the record comes from the flush, not from what the probes had
  delivered when the key came up.

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

Guards: `Tests/VoiceTypingTests.swift`.

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
