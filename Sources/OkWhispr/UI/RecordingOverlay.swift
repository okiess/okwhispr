import SwiftUI
import AppKit
import Combine

/// Smoothed microphone level for the recording overlay, 0...1.
///
/// Kept separate from `AppState` so ~50 level updates per second only redraw
/// the overlay, not every view that observes the app state.
@MainActor
final class AudioLevelMeter: ObservableObject {
    static let shared = AudioLevelMeter()

    @Published private(set) var level: CGFloat = 0

    /// Speech sits roughly between these levels (dBFS); mapped to 0...1.
    private static let floorDb: Float = -50
    private static let ceilDb: Float = -12

    /// Feeds one RMS value from the audio tap. Rises fast and falls slower, so
    /// the bars feel lively without flickering.
    func push(rms: Float) {
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = CGFloat(min(max((db - Self.floorDb) / (Self.ceilDb - Self.floorDb), 0), 1))
        let factor: CGFloat = normalized > level ? 0.55 : 0.18
        level += (normalized - level) * factor
    }

    func reset() {
        level = 0
    }
}

/// A floating pill at the bottom center of the active screen that shows live
/// audio bars while listening and a calm wave while transcribing.
///
/// The panel never takes focus and ignores the mouse, so the paste into the
/// frontmost app keeps working.
@MainActor
final class RecordingOverlayController {

    private let appState: AppState
    private let model = OverlayModel()
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var hideGeneration = 0

    private static let panelSize = NSSize(width: 220, height: 80)
    /// Distance from the bottom of the visible frame (above the Dock).
    private static let bottomInset: CGFloat = 18

    init(appState: AppState) {
        self.appState = appState
        appState.$phase
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.update(for: phase) }
            .store(in: &cancellables)
    }

    private func update(for phase: AppState.Phase) {
        switch phase {
        case .idle:
            hide()
        case .listening:
            guard SettingsStore.shared.showOverlay else { return }
            show(mode: .listening)
        case .transcribing:
            guard SettingsStore.shared.showOverlay else { return }
            show(mode: .transcribing)
        }
    }

    private func show(mode: OverlayModel.Mode) {
        hideGeneration &+= 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = model.visible
        if !wasVisible {
            position(panel)
            panel.orderFrontRegardless()
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            model.mode = mode
            model.visible = true
        }
    }

    private func hide() {
        guard model.visible else { return }
        withAnimation(.easeIn(duration: 0.18)) {
            model.visible = false
        }
        hideGeneration &+= 1
        let generation = hideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, generation == self.hideGeneration else { return }
            self.panel?.orderOut(nil)
            AudioLevelMeter.shared.reset()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: RecordingOverlayView(model: model, meter: AudioLevelMeter.shared))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        return panel
    }

    /// Places the panel at the bottom center of the screen under the mouse,
    /// which is the screen the user is working on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.midX - Self.panelSize.width / 2,
            y: frame.minY + Self.bottomInset)
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    enum Mode { case listening, transcribing }
    @Published var mode: Mode = .listening
    @Published var visible = false
}

/// The pill with the animated bars.
struct RecordingOverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var meter: AudioLevelMeter

    private static let barCount = 13
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 3
    private static let minHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 22

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.88))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

                // A continuous glowing border whose colors flow around the
                // pill: a wide soft glow, a tighter halo, and a crisp line.
                Capsule()
                    .strokeBorder(borderGradient(time: t), lineWidth: 6)
                    .blur(radius: 8)
                    .opacity(0.55 + 0.35 * Double(meter.level))
                Capsule()
                    .strokeBorder(borderGradient(time: t), lineWidth: 2.5)
                    .blur(radius: 2.5)
                    .opacity(0.8)
                Capsule()
                    .strokeBorder(borderGradient(time: t), lineWidth: 1.2)

                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(micColor)
                        .scaleEffect(micScale)
                    HStack(alignment: .center, spacing: Self.barSpacing) {
                        ForEach(0..<Self.barCount, id: \.self) { index in
                            Capsule()
                                .fill(barColor(index: index, time: t))
                                .frame(width: Self.barWidth, height: barHeight(index: index, time: t))
                        }
                    }
                }
            }
        }
        .frame(width: 140, height: 38)
        .scaleEffect(model.visible ? 1 : 0.5)
        .opacity(model.visible ? 1 : 0)
        .offset(y: model.visible ? 0 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A seamless, many-stop color loop around the whole border, slowly
    /// rotating. The loop starts and ends on the same color and uses many
    /// intermediate stops, so there is no seam and no hard step anywhere.
    private func borderGradient(time t: Double) -> AngularGradient {
        let anchors: [(Double, Double, Double)]
        let speed: Double   // degrees per second
        switch model.mode {
        case .listening:
            anchors = [(1.0, 0.27, 0.42), (1.0, 0.55, 0.25), (1.0, 0.82, 0.5), (0.95, 0.35, 0.75)]
            speed = 130
        case .transcribing:
            anchors = [(0.38, 0.45, 1.0), (0.65, 0.42, 1.0), (0.55, 0.85, 1.0), (0.45, 0.6, 1.0)]
            speed = 190
        }
        let angle = (t * speed).truncatingRemainder(dividingBy: 360)
        return AngularGradient(
            gradient: Gradient(colors: Self.smoothLoop(anchors, samples: 48)),
            center: .center,
            angle: .degrees(angle))
    }

    /// Interpolates a closed color loop with a cosine ease between anchors,
    /// so neighbouring colors blend without visible bands.
    private static func smoothLoop(_ anchors: [(Double, Double, Double)], samples: Int) -> [Color] {
        (0...samples).map { step in
            let position = Double(step) / Double(samples) * Double(anchors.count)
            let index = Int(position) % anchors.count
            let next = (index + 1) % anchors.count
            let f = position - floor(position)
            let eased = (1 - cos(f * .pi)) / 2
            let a = anchors[index], b = anchors[next]
            return Color(red: a.0 + (b.0 - a.0) * eased,
                         green: a.1 + (b.1 - a.1) * eased,
                         blue: a.2 + (b.2 - a.2) * eased)
        }
    }

    private var micColor: Color {
        switch model.mode {
        case .listening: return .white
        case .transcribing: return .white.opacity(0.5)
        }
    }

    private var micScale: CGFloat {
        model.mode == .listening ? 1 + 0.18 * meter.level : 1
    }

    /// Center bars swing more than the outer ones, like a voice waveform.
    private func envelope(_ index: Int) -> Double {
        let center = Double(Self.barCount - 1) / 2
        let distance = (Double(index) - center) / (center * 0.75)
        return 0.3 + 0.7 * exp(-distance * distance)
    }

    private func barHeight(index: Int, time t: Double) -> CGFloat {
        let i = Double(index)
        let amount: Double
        switch model.mode {
        case .listening:
            let level = Double(meter.level)
            // Two out-of-phase sines give each bar an organic, non-repeating wobble.
            let wobble = 0.55 + 0.45 * abs(sin(t * 9 + i * 1.7) * cos(t * 4.3 + i * 0.9))
            let breathing = 0.06 * (0.5 + 0.5 * sin(t * 3 + i * 0.8))
            amount = breathing + level * envelope(index) * wobble
        case .transcribing:
            // A wave travelling left to right while the model works.
            amount = 0.12 + 0.38 * pow(0.5 + 0.5 * sin(t * 7 - i * 0.55), 2)
        }
        let clamped = min(max(amount, 0), 1)
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * CGFloat(clamped)
    }

    private func barColor(index: Int, time t: Double) -> Color {
        switch model.mode {
        case .listening:
            return .white
        case .transcribing:
            let shimmer = 0.45 + 0.55 * pow(0.5 + 0.5 * sin(t * 7 - Double(index) * 0.55), 2)
            return .white.opacity(shimmer)
        }
    }
}
