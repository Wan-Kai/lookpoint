import SwiftUI

@main
struct LookpointApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model, showCalibration: delegate.showCalibration, showHandLab: delegate.showHandLab)
        } label: {
            Image(systemName: delegate.model.activeScreen == .primary ? "laptopcomputer" : "display")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the model and the app's windows. Windows are plain AppKit windows so
/// they can be opened without the menu bar icon, which macOS may hide behind
/// the notch: opening Lookpoint again shows the status window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusWindow: NSWindow?
    private var calibrationWindow: NSWindow?
    private var handLabWindow: NSWindow?

    func applicationWillTerminate(_ notification: Notification) {
        model.stopGestures()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatus()
        return false
    }

    func showStatus() {
        if statusWindow == nil {
            statusWindow = makeWindow(
                title: "Lookpoint",
                content: MenuContent(model: model, showCalibration: showCalibration, showHandLab: showHandLab)
            )
        }
        present(statusWindow)
    }

    func showCalibration() {
        if calibrationWindow == nil {
            calibrationWindow = makeWindow(title: "校准副屏", content: CalibrationView(model: model))
        }
        model.setCalibrating(true)
        present(calibrationWindow)
    }

    func showHandLab() {
        if handLabWindow == nil {
            handLabWindow = makeWindow(
                title: "手部识别实验",
                content: HandLabView(model: model, lab: model.handLab),
                resizable: true
            )
        }
        model.setHandLabOpen(true)
        present(handLabWindow)
    }

    func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if window === calibrationWindow { model.setCalibrating(false) }
        if window === handLabWindow { model.setHandLabOpen(false) }
    }

    private func makeWindow(title: String, content: some View, resizable: Bool = false) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
