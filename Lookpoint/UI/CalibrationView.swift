import SwiftUI

struct CalibrationView: View {
    var model: AppModel

    @State private var countdown: Int?
    @State private var isSampling = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("主屏不需要校准：正对摄像头（|yaw| < 8°）就算看主屏。")
            Text("点「开始」后，在倒计时内把头转向副屏中央，保持不动约 1.5 秒。")
                .foregroundStyle(.secondary)

            HStack {
                Text("实时头姿").foregroundStyle(.secondary)
                Text(poseText).monospacedDigit()
            }

            HStack(spacing: 12) {
                Button(buttonTitle) { Task { await run() } }
                    .disabled(countdown != nil || isSampling || model.cameraState != .running)
                    .keyboardShortcut(.defaultAction)
                Button("清除校准") {
                    model.calibration = nil
                    message = "已清除，回到按 |yaw| 判断。"
                }
                .disabled(model.calibration == nil || countdown != nil || isSampling)
            }

            if let message {
                Text(message).font(.callout)
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
    }

    private var buttonTitle: String {
        if let countdown { return "\(countdown)…" }
        return isSampling ? "采样中…" : "开始"
    }

    private var poseText: String {
        guard let pose = model.pose else { return "未检测到人脸" }
        return String(format: "yaw %+.1f°  pitch %+.1f°", pose.yaw, pose.pitch)
    }

    private func run() async {
        message = nil
        for remaining in stride(from: 3, through: 1, by: -1) {
            countdown = remaining
            try? await Task.sleep(for: .seconds(1))
        }
        countdown = nil
        isSampling = true
        let outcome = await model.calibrateSecondary()
        isSampling = false
        NSSound.beep()

        switch outcome {
        case .saved(let pose):
            message = String(format: "已保存：yaw %+.1f°  pitch %+.1f°", pose.yaw, pose.pitch)
        case .tooCloseToPrimary:
            message = "副屏方向离主屏太近（不到 12°），无法可靠区分。可以把副屏摆得更偏一些再试。"
        case .noFace:
            message = "采样期间没检测到人脸，换个角度或光线再试。"
        }
    }
}
