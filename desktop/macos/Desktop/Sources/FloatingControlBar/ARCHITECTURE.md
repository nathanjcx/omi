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
whichever app owns the caret instead of asking Omi. **Nothing is delivered until
the key comes up.** The hold buffers audio; key-up transcribes the whole
utterance once, formats it, and pastes it in one operation.

That is a deliberate reversal. This feature previously typed as the user spoke,
and the accuracy ceiling was structural rather than a matter of tuning: a
recognizer decoding a six-second window cannot know what the next six seconds
contain, so it guesses at the words on the boundary and revises them a moment
later. To make progress, the design had to *freeze* those guesses — and a frozen
guess is a permanently misspelled word in the user's document ("token19" typed
as "token1"). Everything built on top of that (a stabilizer to hold back the
moving edge, an edit planner to diff and retype, a two-recognizer commit
protocol arbitrating one shared timeline, seam-sliding onto pauses, lowering a
recognizer's mid-sentence capital) existed to make a *partial* answer safe to put
on screen. There are no partial answers now, so all of it is gone.

The pipeline, in order:

- `VoiceTypeUtterance` holds every byte of the hold. Bounded by
  `PushToTalkManager.maxBatchAudioBytes` (4.5 min), which is set below the
  backend batch endpoint's ~5-minute 413. Past the cap it keeps what it has and
  flags `didTruncate` — a truncated sentence beats a discarded one.
- `VoiceTypeAudioTrim` trims silence from **both** ends. A hold begins at
  key-down and ends at key-up, so a turn is bracketed by room tone, and a
  recognizer handed room tone does not return nothing — it invents a phrase
  ("Thank you.", observed live twice in one hold). A remainder carrying under
  0.5 s of voice (`minimumDecodableSpeechBytes`) is not decoded at all.
- `VoiceTypeTranscriber` starts **both** recognizers together and that is the
  whole trick to being accurate *and* fast. On-device Parakeet runs at ~100x
  realtime, so it finishes before the network has opened a connection and costs
  the turn nothing; having its answer in hand is what allows the wait on the
  stronger cloud pass (`/v2/voice-message/transcribe`, on-screen keywords as
  vocabulary context) to be bounded by `defaultBudget` without the dictation
  ever degrading to nothing. Cloud transcript if it arrives in time, on-device
  otherwise, and the reason is reported through `recordFallback`.
- `VoiceTypeCommandParser` decides, once, on the complete utterance. It lost its
  third state with the streaming design: nothing asks "might this still become a
  type command?" any more, because by the time anyone calls it the user has
  stopped talking.
- `VoiceTypeFormatter` tidies the transcript. Its rule is that it may **delete a
  filler, move a space, or raise a letter to a capital, and nothing else** — it
  never lowercases (an acronym or surname would lose), never adds or removes
  punctuation the speaker did not say, and never rewrites a word. Spoken
  punctuation commands ("period", "new line") are deliberately absent: they
  cannot be told from dictation deterministically, and "the period of the wave"
  is a sentence someone will say.
- `VoiceTypeSession` delivers it, and owns only the two decisions that cannot be
  made any earlier — whether this machine will let us synthesize input
  (`AXIsProcessTrusted`), and whether the text needs a separating space in front
  of it (`caretFollowsWordCharacter`, one character read through
  `AXStringForRange`; a second dictation into the same line landed flush against
  the first, "voiceI think"). It refuses to deliver when Omi itself is frontmost:
  a dock click mid-hold brought Omi forward and the dictation rewrote text inside
  Omi's own composer.
- `PasteboardTextInserter` pastes. One pasteboard write plus one ⌘V is a single
  operation whose cost does not grow with the length of what was said;
  synthesizing a paragraph as keystrokes takes an event per handful of characters
  and slow first responders (Electron, Terminal) drop the tail. The user's
  pasteboard is saved and restored after `restoreDelay` — restoring immediately
  races the target app's asynchronous read and pastes the *old* clipboard. The
  event source is **private-state**: PTT is a modifier-only chord, so the user is
  physically holding Option while this posts, and a `.hidSystemState` source
  would send ⌥⌘V. Keystroke synthesis remains as the fallback for a pasteboard
  another process has locked, and reports itself as a fallback.

Routing, which is separate from text and revisable:

- **The dictation decision is made at key-up**, from the full transcript, on
  every route. This is the decision that used to be wrong: the live probes read
  a partial, silence-trimmed buffer, and when they lost the wake word — "type"
  opens on a quiet /t/ burst the trim's pre-roll does not always preserve — the
  turn was committed as an ordinary question and the model, hearing "type …",
  spawned an agent to do the typing. Not a missed dictation but an unrequested
  action. It costs one transcription before the model answers a question, paid
  at key-up rather than while the user is speaking.
- `probeForDictationRouting` is the one thing that still happens during a hold,
  and it exists for **cost, not correctness**. A dictation asks no model
  anything, so streaming a two-minute hold to a realtime voice model whose answer
  will be thrown away is spend for nothing, and it makes that socket's lifetime
  the dictation's. At most two on-device decodes of the opening
  (`voiceTypingArmProbeSeconds`) can *promote* a turn to dictation and release
  the hub turn (`cancelTurn`). Neither can reject one, and neither produces a
  character the user sees, so a probe that mishears costs nothing but a late hub
  release. A turn armed this way whose full transcript then does *not* parse as a
  dictation ends with nothing — rare by construction, reported as a fallback.
- Reducer route transitions under a long hold (the 1 s warm-wait deadline, a late
  hub-ready) are ignored for an armed turn: the chunk handler checks
  `voiceTypingArmed` before any route branch, and `resolveRealtimeHubWarmWait` /
  `.fallbackToTranscription` return early.
- The STT routes (`omniSTT`, `deepgramBatch`) already hold a complete-utterance
  transcript from their own provider, so they run no decode of their own and join
  the pipeline at the parse (`deliverDictation(fromTranscript:…)`).
- Offline (`PTTRoutePolicy.decide`, `NetworkReachability`) the on-device model is
  the only recognizer, and dictation still works end to end. Only dictation
  completes offline: answering needs a cloud model, so a non-dictation turn ends
  as `providerFailed` rather than pretending to be in flight.
- The on-screen keyword corrector (`PTTTranscriptContextualCorrector`) runs on
  the dictated text only, never on the wake word
  (`VoiceTypeCommandParser.correctingPayload`, applied through
  `keywordCorrected`). Live, a window title containing "typ" made it rewrite
  "Type" itself and no probe parsed as a dictation. A question is still corrected
  whole.
- A claimed hub turn is **cancelled, never committed**, so the model never
  answers a dictation out loud.
- A finished turn journals what actually reached the focused app as
  `Typed: <text>` — not the raw utterance, which still holds the wake word —
  through the ordinary `recordExchange` on the realtime voice surface, so a
  dictation persists and enters conversation context exactly like a spoken
  question and the next turn can refer back to it. The continuity key is derived
  from the turn, so a retry cannot write a second copy.

One structural consequence worth keeping: the resolve reads its audio
**synchronously**, before the turn's terminal cleanup runs, so
`performTerminalCleanup` resets the pipeline unconditionally. The previous design
could not — the closing flush outlived the reducer's terminal, so cleanup had to
be taught to leave the decode window and the streaming socket alone while a flush
was open (resetting them there lost the last word of every hold) and a generation
token had to prove the flush still belonged to its turn. Holding the bytes means
nothing shared survives the await. `voiceTypingTurnGeneration` remains as the one
guard that matters: a slow recognizer cannot paste one hold's dictation into the
next.

Guards: `Tests/VoiceTypingTests.swift` (pure pipeline),
`Tests/VoiceTypingSimulationTests.swift` (scripted hold in, pasted text out),
`Tests/VoiceTypingDeliveryTests.swift` (delivery decisions).
Harness: `omi-ctl action ptt_manager_turn pcm=<s16le 16k> pace_ms=100 settle_ms=1500`
drives a hold through the production chunk path and reports `voice_typing_*`
diagnostics.

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
