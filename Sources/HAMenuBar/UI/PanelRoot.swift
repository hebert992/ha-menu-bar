import AppKit
import SwiftUI

/// Root of the menu bar panel.
///
/// `MenuBarExtra(.window)` only hides its window when the panel closes; the SwiftUI hierarchy stays
/// alive and would keep re-laying-out and re-rendering on every store change (sparkline included).
/// While the window is off screen this root renders an inert placeholder of the same size that
/// reads no store state, so entity updates cost nothing UI-wise. The real content is rebuilt from
/// fresh store state the moment the window becomes key/visible again, inside the same display
/// transaction, so it opens without a blank frame or a size jump.
struct PanelRoot: View {
    @State private var isVisible = true
    /// Last laid-out panel size, reused by the placeholder so the window keeps its size.
    @State private var size = CGSize(width: Theme.panelWidth, height: 120)
    /// Scroll content height, kept across teardown so reopening does not re-measure from scratch.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        Group {
            if isVisible {
                PanelView(contentHeight: $contentHeight)
                    .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            } else {
                Color.clear.frame(width: size.width, height: size.height)
            }
        }
        .background(WindowVisibilityReader { isVisible = $0 })
        .preferredColorScheme(.dark)
    }
}

/// Reports whether the hosting window is on screen.
///
/// Uses AppKit window state rather than `onAppear`/`onDisappear`: a `MenuBarExtra` window's content
/// stays alive while hidden, so view lifecycle callbacks are not a dependable open/close signal.
/// - Becoming key means the panel was just opened: visible, synchronously, before the frame is drawn.
/// - Occlusion changes and ordering out (`isVisible`, `occlusionState`) catch the close.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityTrackingView {
        VisibilityTrackingView(onChange: onChange)
    }

    func updateNSView(_ nsView: VisibilityTrackingView, context: Context) {
        nsView.onChange = onChange
    }
}

final class VisibilityTrackingView: NSView {
    var onChange: @MainActor (Bool) -> Void
    private var observers: [any NSObjectProtocol] = []
    private var lastReported: Bool?

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else { return }

        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
        ]
        // `queue: nil` delivers synchronously on the posting (main) thread, so the content is restored
        // within the same transaction that makes the window key, before anything is drawn.
        // No report at attach time: MenuBarExtra builds its content while opening.
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated { self?.evaluate(after: name) }
            }
        }
    }

    private func evaluate(after notification: Notification.Name) {
        guard let window else { return }
        let visible: Bool = switch notification {
        case NSWindow.didBecomeKeyNotification: true
        case NSWindow.willCloseNotification: false
        default: window.isVisible && window.occlusionState.contains(.visible)
        }
        guard visible != lastReported else { return }
        lastReported = visible
        onChange(visible)
    }
}
