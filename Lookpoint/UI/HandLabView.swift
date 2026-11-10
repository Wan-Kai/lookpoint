import SwiftUI

struct HandLabView: View {
    @Bindable var model: AppModel
    var lab: HandLab

    private var isPressed: Bool { lab.mode == .pressed || lab.mode == .dragging }

    private static let bones: [(HandLandmarks.Joint, HandLandmarks.Joint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMCP), (.thumbMCP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                handCanvas
                pinchGraph.frame(height: 140)
            }
            sidebar.frame(width: 260)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    // MARK: Hand view (mirrored, like looking in a mirror)

    private var handCanvas: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            let frame = Self.fittedFrame(in: size)
            context.stroke(Path(frame), with: .color(.white.opacity(0.15)), lineWidth: 1)

            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: frame.minX + p.x * frame.width, y: frame.minY + p.y * frame.height)
            }

            if let hand = lab.landmarks {
                let mirrored = { (joint: HandLandmarks.Joint) -> CGPoint in
                    let p = hand[joint]
                    return point(CGPoint(x: 1 - p.x, y: p.y))
                }
                var bones = Path()
                for (a, b) in Self.bones where hand.confidence(a) > 0 && hand.confidence(b) > 0 {
                    bones.move(to: mirrored(a))
                    bones.addLine(to: mirrored(b))
                }
                context.stroke(bones, with: .color(.white.opacity(0.35)), lineWidth: 2)
                for joint in HandLandmarks.Joint.allCases where hand.confidence(joint) > 0 {
                    let c = mirrored(joint)
                    let r = 2 + 3 * hand.confidence(joint)
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(.white.opacity(0.6)))
                }
            }

            drawTrail(lab.rawTrail.map(point), color: .red, in: &context)
            drawTrail(lab.filteredTrail.map(point), color: .green, in: &context)

            if let tip = lab.filteredTrail.last.map(point) {
                let r: CGFloat = isPressed ? 16 : 10
                context.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(isPressed ? .yellow : .green))
            }
        }
    }

    private func drawTrail(_ points: [CGPoint], color: Color, in context: inout GraphicsContext) {
        guard points.count > 1 else { return }
        var path = Path()
        path.addLines(points)
        context.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 2)
    }

    /// Largest 16:9 rectangle centered in `size`.
    private static func fittedFrame(in size: CGSize) -> CGRect {
        let aspect = HandLandmarks.frameAspect
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    // MARK: Pinch ratio (thumb–index over palm length) over the last ~5 s

    private var pinchGraph: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.1)))
            let maxValue = 1.5
            let config = GestureStateMachine.Config()
            func y(_ value: Double) -> CGFloat { size.height * (1 - min(value, maxValue) / maxValue) }

            for (threshold, label) in [(config.pinchOn, "按下 \(config.pinchOn)"), (config.pinchOff, "抬起 \(config.pinchOff)")] {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(threshold)))
                line.addLine(to: CGPoint(x: size.width, y: y(threshold)))
                context.stroke(line, with: .color(.orange.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                context.draw(Text(label).font(.caption2).foregroundStyle(.orange),
                             at: CGPoint(x: 6, y: y(threshold) - 7), anchor: .leading)
            }

            let history = lab.pinchHistory
            let step = size.width / CGFloat(max(history.count - 1, 1))
            var path = Path()
            var drawing = false
            for (index, value) in history.enumerated() {
                guard let value else { drawing = false; continue }
                let p = CGPoint(x: CGFloat(index) * step, y: y(value))
                if drawing { path.addLine(to: p) } else { path.move(to: p) }
                drawing = true
            }
            context.stroke(path, with: .color(.cyan), lineWidth: 1.5)
        }
    }

    // MARK: Numbers

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.cameraState != .running {
                Label("摄像头没在运行：先在菜单里打开「按头部朝向切换屏幕」。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("手势接管鼠标和键盘", isOn: $model.gesturesEnabled)
                .toggleStyle(.switch)
            Text(modeNote)
                .font(.caption)
                .foregroundStyle(model.gesturesLive ? .green : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row("手势状态", modeText)
                row("手形", shapeText)
                row("捏合比", lab.features.map { String(format: "%.2f", $0.indexPinch) } ?? "—")
                row("无名/小指", lab.features.map { String(format: "%.2f", $0.ringLittleRatio) } ?? "—")
                Divider().gridCellUnsizedAxes(.horizontal)
                row("点击次数", "\(lab.clickCount)")
                row("滚动距离", String(format: "%.0f pt", lab.scrollDistance))
                row("右 Alt", "\(lab.toggleCount) 次")
                Divider().gridCellUnsizedAxes(.horizontal)
                row("检测帧率", "\(lab.framesPerSecond) fps")
                row("识别到手", String(format: "%.0f%%", lab.handRate * 100))
                row("单帧耗时", String(format: "%.1f ms", lab.latencyMilliseconds))
                Divider().gridCellUnsizedAxes(.horizontal)
                row("抖动 原始", lab.rawJitter.map { String(format: "%.1f pt", $0) } ?? "—")
                row("抖动 滤波后", lab.filteredJitter.map { String(format: "%.1f pt", $0) } ?? "—")
            }
            .font(.callout.monospacedDigit())

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lab.eventLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }
            .font(.caption.monospacedDigit())

            Text("张开手掌 0.4 秒激活 · 张开平移=移动 · 捏=点击/拖拽 · 双指(V)上下=滚动 · 单指指向静止 0.6 秒=右 Alt · 其他手形=停住。红线/绿线是食指尖的原始/滤波轨迹。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("清零计数") { lab.resetCounters() }
            HStack {
                Button(lab.isRecording ? "停止录制" : "开始录制") { lab.toggleRecording() }
                if lab.isRecording {
                    Circle().fill(.red).frame(width: 8, height: 8)
                }
            }
            if let url = lab.lastRecordingURL {
                Button("在 Finder 中显示 \(url.lastPathComponent)") { lab.revealLastRecording() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(16)
    }

    private var modeNote: String {
        if model.gesturesLive { return "接管中：手势会真正移动鼠标、点击和按键。" }
        if model.gesturesEnabled { return "等待辅助功能权限，授权前只空跑。" }
        return "空跑：只显示会发出什么事件，不碰鼠标键盘。"
    }

    private var modeText: String {
        switch lab.mode {
        case .idle: "未激活"
        case .activating: "激活中…"
        case .moving: "移动"
        case .frozen: "停住"
        case .pressed: "按下"
        case .dragging: "拖拽"
        case .scrolling: "滚动"
        case .holding: "指向（保持触发右 Alt）"
        }
    }

    private var shapeText: String {
        switch lab.features?.shape {
        case nil: "—"
        case .open: "张开"
        case .point: "单指指向"
        case .two: "双指"
        case .other: "其他"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
