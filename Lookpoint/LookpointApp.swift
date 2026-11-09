import SwiftUI

@main
struct LookpointApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.activeScreen == .primary ? "laptopcomputer" : "display")
        }
        .menuBarExtraStyle(.window)

        Window("校准副屏", id: WindowID.calibration) {
            CalibrationView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let calibration = "calibration"
}
