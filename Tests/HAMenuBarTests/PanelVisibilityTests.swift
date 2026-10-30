import AppKit
import Testing
@testable import HAMenuBar

@MainActor
@Suite("Panel visibility")
struct PanelVisibilityTests {
    @Test func reportsVisibilityFromWindowNotifications() {
        var reports: [Bool] = []
        // Never ordered in, so it is not visible: occlusion/close checks report hidden.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let view = VisibilityTrackingView { reports.append($0) }
        window.contentView?.addSubview(view)
        #expect(reports.isEmpty, "Attaching must not report anything")

        let center = NotificationCenter.default
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window) // duplicate is ignored
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(reports == [true, false, true, false])

        view.removeFromSuperview()
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(reports.count == 4, "Detached views stop observing")
    }
}
