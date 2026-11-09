import SwiftUI

struct HandLabView: View {
    var model: AppModel
    var lab: HandLab

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
                let r: CGFloat = lab.isPinching ? 16 : 10
                context.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(lab.isPinching ? .yellow : .green))
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

    // MARK: Pinch distance over the last ~5 s

    private var pinchGraph: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.1)))
            let maxValue = 0.25
            func y(_ value: Double) -> CGFloat { size.height * (1 - min(value, maxValue) / maxValue) }

            for (threshold, label) in [(HandLab.pinchOn, "on 0.055"), (HandLab.pinchOff, "off 0.085")] {
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

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row("检测帧率", "\(lab.framesPerSecond) fps")
                row("识别到手", String(format: "%.0f%%", lab.handRate * 100))
                row("单帧耗时", String(format: "%.1f ms", lab.latencyMilliseconds))
                Divider().gridCellUnsizedAxes(.horizontal)
                row("抖动 原始", lab.rawJitter.map { String(format: "%.1f pt", $0) } ?? "—")
                row("抖动 滤波后", lab.filteredJitter.map { String(format: "%.1f pt", $0) } ?? "—")
                Divider().gridCellUnsizedAxes(.horizontal)
                row("捏合距离", lab.pinchHistory.last.flatMap { $0 }.map { String(format: "%.3f", $0) } ?? "—")
                row("捏合/掌长", lab.pinchRatio.map { String(format: "%.2f", $0) } ?? "—")
                row("捏合状态", lab.isPinching ? "捏合中" : "松开")
                row("捏合次数", "\(lab.pinchCount)")
            }
            .font(.callout.monospacedDigit())

            Text("红线是原始指尖轨迹，绿线是 One-Euro 滤波后的轨迹。抖动是最近 0.5 秒指尖的离散程度，换算成主屏上的点数，手静止时看才有意义。")
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

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
