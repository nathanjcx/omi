import OmiTheme
import SwiftUI

/// Layout constants for the blob the bolt pours out.
enum SuperModeChrome {
  static let panelWidth: CGFloat = 320
  static let panelHeight: CGFloat = 296
  /// Room for roughly four lines of prompt. Fixed rather than growing with the text: a popover that
  /// resizes under the caret moves the box you are typing in.
  static let instructionEditorHeight: CGFloat = 88
  /// Radius of the drop that stays behind at the popover's arrow. Big enough that the blur still
  /// bridges it to the panel one frame after the gesture, which is the whole gooey read.
  static let neckRadius: CGFloat = 13
}

/// **Super Mode's trigger, immediately left of the mic in the composer.**
///
/// Click toggles the mode. *Hold* opens the settings popover, where the Gemini key goes — the same
/// split the mic beside it uses (press to act, hold for the other thing), so the trailing cluster
/// keeps one grammar. It is not a `Button`: a `Button` fires its action when a long press ends, so
/// holding it would open the popover and toggle the mode in the same gesture.
///
/// **One circle, filled when on and bare when off.** It briefly grew into a labelled pill with a
/// running clock, which did make the state obvious but put a widening, ticking object in a row of
/// three fixed-width controls — the composer reflowed every time the mode was toggled, and a timer
/// nobody asked for kept redrawing while you typed. The state is carried by the fill inverting
/// (`Ink.primary` ground, `Ink.surface` glyph — the same pair as the row's Send disc) and, one
/// control away, by the composer's own placeholder changing to name Gemini
/// (`QueryHeroBar.placeholderText`). That is the loud half, and it costs no layout.
struct SuperModeButton: View {
  @ObservedObject private var superMode = SuperModeController.shared

  /// Matched to whichever composer row it lands in, like `PushToTalkMicButton` beside it.
  var diameter: CGFloat = 32
  var glyphSize: CGFloat = OmiType.heading
  var idleTint: Color = Ink.secondary

  @State private var isHovering = false
  /// Counts down the hold. Held here rather than inferred from a gesture's own duration — see the
  /// gesture below.
  @State private var holdTask: Task<Void, Never>?
  /// How far the pointer may drift during a press and still count as a click.
  private static let slipTolerance: CGFloat = 8

  /// Set when the hold completed, so the mouse-up that ends it does not also read as a click.
  @State private var holdOpenedPanel = false

  var body: some View {
    bolt
      .animation(
        InkReduceMotion.animation(.easeOut(duration: InkMotion.press)), value: superMode.isOn)
  }

  private var bolt: some View {
    ZStack {
      Circle().fill(fill)
      // The ink pair the row's Send disc uses, never a hue: "on" reads from the ladder, and the one
      // accent that would look good here is exactly the one the brand does not use (INV-UI-1).
      Image(systemName: "bolt.fill")
        .scaledFont(size: glyphSize * 0.8, weight: .semibold)
        .foregroundColor(superMode.isOn ? Ink.surface : idleTint)
    }
    // Fixed size in both states, so toggling never reflows the row around it.
    .frame(width: diameter, height: diameter)
    .contentShape(Circle())
    .onHover { isHovering = $0 }
    // **One gesture owns both outcomes, and it is timed off the press rather than by a recognizer.**
    //
    // Two false starts are worth recording, because each looked correct and each broke the other
    // half of the control:
    //
    // `LongPressGesture` decides it has succeeded from its *own* internal clock, and it only
    // advances that clock while the view keeps receiving press updates. A press that goes down and
    // holds perfectly still delivers no further updates, so the gesture neither completes nor fails:
    // it consumes the press and nothing happens. Held alone, stacked under `.onTapGesture`, or as
    // the winning half of an `ExclusiveGesture`, the hold did nothing at all.
    //
    // Moving the countdown into a zero-distance `DragGesture` fixed the hold and then broke the
    // click, because a drag that begins on mouse-down swallows the tap a *separate* `.onTapGesture`
    // was waiting for — the button lit on hover and stopped toggling. A second recognizer is the
    // problem in both directions.
    //
    // So there is one gesture. The press starts a countdown we own, which is a fact about the input
    // rather than a recognizer's bookkeeping, and the release decides what the gesture was: a hold
    // already spent it, and anything else is a click.
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard holdTask == nil else { return }
          holdOpenedPanel = false
          holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            holdOpenedPanel = true
            OmiMotion.withGated(.spring(response: 0.34, dampingFraction: 0.72)) {
              superMode.isPanelOpen.toggle()
            }
          }
        }
        .onEnded { value in
          holdTask?.cancel()
          holdTask = nil
          let openedPanel = holdOpenedPanel
          holdOpenedPanel = false
          // A press that wandered off the control before release is a cancelled click, the same as
          // it would be for an `NSButton` — `slipTolerance` is the slack a hand has while holding
          // still, not a drag target.
          let slipped =
            abs(value.translation.width) > Self.slipTolerance
            || abs(value.translation.height) > Self.slipTolerance
          guard !openedPanel, !slipped else { return }
          superMode.toggle()
        }
    )
    .animation(InkReduceMotion.animation(.easeOut(duration: InkMotion.press)), value: isHovering)
    .help(
      superMode.isOn
        ? "Super Mode is on — Gemini answers from this screen only. Click to stop, hold to set up."
        : "Super Mode — answer from this screen with Gemini. Click to start, hold to set up."
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(superMode.isOn ? .isSelected : [])
    .accessibilityLabel(Text("Super Mode"))
    .accessibilityValue(Text(superMode.isOn ? "On" : "Off"))
    .accessibilityHint(Text("Click to turn \(superMode.isOn ? "off" : "on"). Hold to enter a Gemini API key."))
    .accessibilityIdentifier("super-mode-toggle")
    // **A popover, not an overlay drawn under the row.** The first version poured the blob into the
    // space below the composer — and the composer is the *last* thing in the window, so the panel
    // landed outside the window's bounds and was clipped away entirely: the hold worked and nothing
    // appeared. A popover is its own window, so it is visible from either composer placement and
    // from a window sitting at the very bottom of the screen.
    .popover(isPresented: $superMode.isPanelOpen, arrowEdge: .bottom) {
      SuperModePanel()
    }
    // Hovering the control is the earliest honest signal that a request is coming, so the TLS
    // handshake can be paid here instead of inside the wait. Throttled in `warm()`.
    .onChange(of: isHovering) { if isHovering { superMode.warm() } }
  }

  private var fill: Color {
    if superMode.isOn { return Ink.primary }
    return isHovering ? Ink.rowFill : .clear
  }

}

/// The settings blob: it pours down from the bolt and lands as a panel.
///
/// The liquid read is a metaball — every shape is drawn into one `Canvas` layer that is blurred and
/// then alpha-thresholded, so two shapes within a blur radius of each other resolve as a single
/// hard-edged silhouette with a neck stretched between them. It cannot be done with two ordinary
/// views: their alphas composite, and they never merge.
struct SuperModePanel: View {
  @ObservedObject private var superMode = SuperModeController.shared

  @State private var progress: CGFloat = 0

  var body: some View {
    ZStack(alignment: .top) {
      blob
      form
        .padding(.horizontal, OmiSpacing.lg)
        .padding(.top, OmiSpacing.lg)
        .opacity(Double(progress))
    }
    .frame(width: SuperModeChrome.panelWidth, height: SuperModeChrome.panelHeight)
    .onAppear {
      withAnimation(OmiMotion.gated(.spring(response: 0.42, dampingFraction: 0.68))) {
        progress = 1
      }
    }
  }

  private var blob: some View {
    Canvas { context, size in
      context.addFilter(.alphaThreshold(min: 0.4, color: Ink.rowFill))
      context.addFilter(.blur(radius: 12))
      context.drawLayer { layer in
        let radius = SuperModeChrome.neckRadius
        // The drop that never leaves the bolt: drawn straddling the top edge, under the popover's
        // arrow, so the sheet reads as having come out of the button rather than appearing beside it.
        layer.fill(
          Path(
            ellipseIn: CGRect(
              x: size.width / 2 - radius, y: -radius, width: radius * 2, height: radius * 2)),
          with: .color(.white))
        layer.fill(Path(roundedRect: panelRect(in: size), cornerRadius: 20), with: .color(.white))
      }
    }
  }

  /// Starts as a bead hanging off the arrow and grows into the full sheet. Interpolating the width
  /// as well as the height is what makes it read as a drip rather than as a curtain.
  private func panelRect(in size: CGSize) -> CGRect {
    let inset = OmiSpacing.sm
    let fullWidth = max(size.width - inset * 2, 1)
    let width = max(SuperModeChrome.neckRadius * 2, fullWidth * (0.14 + 0.86 * progress))
    let height = max(SuperModeChrome.neckRadius, (size.height - inset * 2) * progress)
    return CGRect(x: (size.width - width) / 2, y: inset, width: width, height: height)
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: OmiSpacing.xs) {
      HStack(spacing: OmiSpacing.xxs) {
        Image(systemName: "bolt.fill").scaledFont(size: OmiType.caption, weight: .semibold)
        Text("Super Mode").scaledFont(size: OmiType.body, weight: .semibold)
        Spacer(minLength: 0)
        // Deliberately no clock. How long the mode has been on is not a thing anyone acts on, and a
        // per-second redraw in a popover you are typing a key into is a cost with no reader.
        Text(superMode.isOn ? "On" : "Off")
          .scaledFont(size: OmiType.caption, weight: .medium)
          .foregroundColor(Ink.tertiary)
      }
      .foregroundColor(Ink.primary)

      SecureField("Gemini API key", text: $superMode.apiKey)
        .textFieldStyle(.plain)
        .scaledFont(size: OmiType.body)
        .foregroundColor(Ink.primary)
        .padding(.horizontal, OmiSpacing.sm)
        .padding(.vertical, OmiSpacing.xs)
        .background(Ink.rowFillHover, in: RoundedRectangle(cornerRadius: OmiChrome.elementRadius))
        .accessibilityIdentifier("super-mode-api-key")

      instructionEditor

      Text(
        "Answers come straight from Gemini — this screen, plus whatever you've asked since Super Mode turned on. Nothing else."
      )
      .scaledFont(size: OmiType.caption)
      .foregroundColor(Ink.tertiary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// **The prompt itself, editable, directly under the key.**
  ///
  /// The two things this mode is made of are the credential it spends and the instruction it sends,
  /// and both belong in the one place the mode is configured. `TextEditor` rather than a `TextField`
  /// because a system prompt is a paragraph — a single-line field scrolls its own beginning out of
  /// view and gives no way to type a newline.
  ///
  /// It has no Save. The value is bound straight to the controller, which persists on write, so a
  /// prompt is in force the moment you stop typing — there is no state in which the box and the next
  /// request disagree about what the instruction is.
  @ViewBuilder
  private var instructionEditor: some View {
    HStack(spacing: OmiSpacing.xxs) {
      Text("System prompt")
        .scaledFont(size: OmiType.caption, weight: .medium)
        .foregroundColor(Ink.secondary)
      Spacer(minLength: 0)
      // Only offered once the text has actually diverged, so the affordance is absent exactly when
      // it would do nothing.
      if superMode.systemInstruction != SuperModeController.defaultSystemInstruction {
        Button("Reset") {
          superMode.systemInstruction = SuperModeController.defaultSystemInstruction
        }
        .buttonStyle(.plain)
        .scaledFont(size: OmiType.caption, weight: .medium)
        .foregroundColor(Ink.secondary)
        .accessibilityIdentifier("super-mode-reset-prompt")
      }
    }

    ZStack(alignment: .topLeading) {
      // `TextEditor` paints its own opaque ground, which on this panel reads as a white slab. Hiding
      // it lets the same fill the key field uses show through, so the two inputs are one family.
      TextEditor(text: $superMode.systemInstruction)
        .scrollContentBackground(.hidden)
        .scaledFont(size: OmiType.caption)
        .foregroundColor(Ink.primary)
        .padding(.horizontal, OmiSpacing.xxs)
        .padding(.vertical, 2)
      if superMode.systemInstruction.isEmpty {
        // Says what an empty box does rather than repeating the label: cleared means the default is
        // sent, not that nothing is.
        Text("Empty — the built-in prompt is used")
          .scaledFont(size: OmiType.caption)
          .foregroundColor(Ink.tertiary)
          .padding(.horizontal, OmiSpacing.sm)
          .padding(.vertical, OmiSpacing.xs)
          .allowsHitTesting(false)
      }
    }
    .frame(height: SuperModeChrome.instructionEditorHeight)
    .padding(.horizontal, OmiSpacing.xxs)
    .padding(.vertical, OmiSpacing.xxs)
    .background(Ink.rowFillHover, in: RoundedRectangle(cornerRadius: OmiChrome.elementRadius))
    .accessibilityIdentifier("super-mode-system-prompt")
  }
}
