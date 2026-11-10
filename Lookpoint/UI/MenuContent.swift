import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    var showCalibration: () -> Void
    var showHandLab: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("按头部朝向切换屏幕", isOn: $model.isEnabled)
                .toggleStyle(.switch)
            Toggle("手势控制鼠标", isOn: $model.gesturesEnabled)
                .toggleStyle(.switch)
                .disabled(!model.isEnabled)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("摄像头").foregroundStyle(.secondary)
                    Text(cameraText)
                }
                GridRow {
                    Text("头姿").foregroundStyle(.secondary)
                    Text(poseText).monospacedDigit()
                }
                GridRow {
                    Text("当前屏幕").foregroundStyle(.secondary)
                    Text(model.activeScreen == .primary ? "主屏" : "副屏")
                }
                GridRow {
                    Text("手势").foregroundStyle(.secondary)
                    Text(gestureText)
                }
                GridRow {
                    Text("副屏校准").foregroundStyle(.secondary)
                    Text(calibrationText).monospacedDigit()
                }
            }
            .font(.callout)

            if !model.hasSecondaryDisplay {
                Label("没有检测到第二块屏幕", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if model.cameraState == .denied {
                Button("打开摄像头权限设置…") {
                    openSettings("Privacy_Camera")
                }
            }

            if !model.hasAccessibility {
                Button("授予辅助功能权限…") {
                    model.requestAccessibility()
                    openSettings("Privacy_Accessibility")
                }
                Text("手势控制鼠标、打字时暂停都需要它。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("校准副屏…", action: showCalibration)
                Button("手部实验…", action: showHandLab)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { model.refreshPermissions() }
    }

    private var cameraText: String {
        switch model.cameraState {
        case .off: "已关闭"
        case .starting: "启动中…"
        case .running: "运行中"
        case .denied: "未授权"
        case .failed(let reason): "失败：\(reason)"
        }
    }

    private var poseText: String {
        guard model.cameraState == .running else { return "—" }
        guard let pose = model.pose else { return "未检测到人脸" }
        return String(format: "yaw %+.1f°  pitch %+.1f°", pose.yaw, pose.pitch)
    }

    private var gestureText: String {
        guard model.gesturesEnabled else { return "已关闭" }
        guard model.hasAccessibility else { return "等待辅助功能权限" }
        return model.gestureMode == .idle || model.gestureMode == .activating ? "待命（张开手掌激活）" : "接管中"
    }

    private var calibrationText: String {
        guard let calibration = model.calibration else { return "未校准（按 |yaw| 判断）" }
        return String(format: "yaw %+.1f°  pitch %+.1f°", calibration.yaw, calibration.pitch)
    }

    private func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
