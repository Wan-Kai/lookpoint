# lookpoint

macOS 菜单栏工具，用笔记本自带摄像头做两件事：

1. **看哪块屏，光标就去哪块屏**：根据头部朝向（yaw/pitch）在主屏（内建屏，带摄像头）和副屏之间切换。不做眼动追踪。
2. **用手势代替鼠标和一个快捷键**：张开手掌激活，移动、点击、拖拽、滚动、切换右 Option（语音输入）。

当前进度：头姿切屏可用；手部识别实测后确定继续用 Vision；手势状态机已完成，试用中（第 4 步）。

## 构建与运行

要求：macOS 14+，Xcode 26（Swift 6）。零第三方依赖。

```sh
open Lookpoint.xcodeproj            # ⌘R 运行
# 或命令行：
xcodebuild -scheme Lookpoint -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Lookpoint.app
xcodebuild -scheme Lookpoint -derivedDataPath build/DerivedData test
```

首次运行会请求两项权限：

- **摄像头**：必须。
- **辅助功能**：头姿切屏本身不需要；有了它才能在你打字时暂停切换（全局键盘监听），后续手势发 `CGEvent` 也需要。

### 签名（重要）

工程用 Apple Development 证书**手动签名**（`CODE_SIGN_STYLE = Manual`，Team `QGZ4G5UJ65`），Bundle ID 固定为 `io.github.wan-kai.lookpoint`。不要改成 ad-hoc 签名，否则每次重新构建，系统的 TCC 权限都可能失效。换别的开发者构建时，把 `DEVELOPMENT_TEAM` 改成自己的。

**App Sandbox 已关闭**：开了沙盒拿不到辅助功能权限，也发不了 `CGEvent`。Hardened Runtime 也是关的，以后要分发只能走 Developer ID + 公证（届时打开 Hardened Runtime，并加上 `com.apple.security.device.camera` entitlement）。

## 使用

- 菜单栏图标：💻 = 当前在主屏，🖥 = 当前在副屏。点开可以看实时 yaw/pitch、开关功能、校准副屏。
- **主屏不需要校准**：正对摄像头，即 `|yaw| < 8°`，就算看主屏。
- **副屏**：
  - 未校准时，`|yaw| ≥ 15°` 判定为副屏，左右两边都算；
  - 校准后（菜单 → 校准副屏…，倒计时结束后看着副屏中央 1.5 秒），沿校准方向的角度 ≥ 校准角度的 60%（且至少 12°）才判定为副屏。副屏放在上方（主要是 pitch）也能用，看反方向或者低头看键盘不会误判。
- 切换就是把光标移到目标屏：回到这块屏上次离开时的位置，没有记录就放到屏幕中央。只移光标，不点击，所以键盘焦点不会变。

- **找不到菜单栏图标**（刘海屏上可能被藏起来）：再打开一次 Lookpoint.app，会弹出同样内容的状态窗口。

## 手势

菜单里打开「手势控制鼠标」（需要辅助功能权限）。手势接管期间冻结屏幕选择：头决定在哪块屏，手只在这块屏内移动光标。

| 功能 | 手势 |
|---|---|
| 激活 | 张开手掌，抬到画面下方 1/4 以上，保持 0.4 秒 |
| 移动 | 张开手掌平移（相对移动，手越快光标走得越远） |
| 停住 / 离合 | 换成任何其他手形，或者把手放下 |
| 左键单击 / 双击 | 拇指和食指捏一下 / 0.4 秒内捏两下 |
| 拖拽 | 捏住后移动，松开即放下 |
| 上下滚动 | 双指（V）上下移动，内容跟手走，像触控板 |
| 右 Option（切换语音输入） | 单指指向，静止保持 0.6 秒；触发后冷却 1 秒，要再触发须先换手形 |
| 退出 | 手离开画面 0.5 秒，或开始打字 |

为什么这样设计（数据来自 2026-11-10 的 7.9 分钟录制，以及对 Vision Pro、Quest、Android XR、Apple Watch 和几个开源手势鼠标的调研）：

- 拇指捏中指和拇指捏食指在 Vision 下 77% 的帧分不开，所以没用捏中指。
- 握拳时拇指也贴着食指。区分靠两条：无名指和小指的伸直比（握拳约 0.75，捏合约 1.05，阈值 0.88），以及捏合必须在张开手掌后 0.6 秒内开始。
- 主流产品用"捏住拖动"来滚动，但在 Mac 上它已经是左键拖拽，所以滚动改用双指。
- 主流产品的快捷键是"翻手 + 捏"，但我们还没验证 Vision 能分清掌心和手背，所以先用"指向并保持"。

阈值都在 `GestureStateMachine.Config`。关掉开关时，手部实验窗口仍然运行状态机，只显示它会发出的事件（空跑），方便调参。

## 手部识别实验

菜单 → 手部实验…。窗口打开期间每帧都跑手部识别（30 fps），并且暂停按头姿切屏；关掉窗口就停止手部识别。

- 画面是镜像的，和照镜子一样：白色是 21 个关键点组成的骨架，红线是食指尖的原始轨迹，绿线是 One-Euro 滤波后的轨迹；捏合时指尖圆点变成黄色。
- 底部曲线：拇指尖到食指尖的距离除以掌长（和手离摄像头多远无关），虚线是按下 0.25 / 抬起 0.40。
- 右侧：手势开关、当前手势状态和手形、捏合比、无名指/小指伸直比、点击/滚动/右 Option 计数、事件日志，以及检测帧率、识别率、单帧耗时、抖动。
- 录制：把逐帧关键点存到 `~/Documents/lookpoint-recordings/hand-*.json`，第 4 步的手势状态机单测会用这些录制。

## 防误切换

| 机制 | 值 |
|---|---|
| 主屏和副屏阈值之间留迟滞带，带内保持当前屏不变 | 8° / max(12°, 0.6×校准角) |
| dwell：需要在新区域连续停留 | 300 ms |
| cooldown：两次切换的最小间隔 | 600 ms |
| grace：打字、移动或点击鼠标后暂停判定 | 1.5 s |
| 丢失人脸 | 保持当前屏，dwell 重新计时 |
| 校准窗口打开期间 | 不切换 |
| One-Euro 滤波（yaw / pitch） | minCutoff 1 Hz, β 0.02 |

阈值在 `HeadPoseRouter.Config` 里，滤波参数在 `AppModel` 里。

## 结构

```
Lookpoint/
  LookpointApp.swift          MenuBarExtra + 校准窗口
  AppModel.swift              串起采集 → 滤波 → 路由 → 移光标
  Capture/CameraPipeline.swift  AVCaptureSession 720p，串行队列；每 3 帧跑一次 Vision 人脸（约 10 fps），
                              需要时每帧跑手部；同一帧的请求共用一个 VNImageRequestHandler
  Hand/
    HandLandmarks.swift       21 个关键点（MediaPipe 顺序，左上原点，归一化）+ 捏合距离
    HandLandmarker.swift      唯一的可替换接口：帧 → 21 点。现在是 Vision，将来可以换成 Core ML
    HandLab.swift             实验窗口的统计、事件日志和录制
  Gesture/
    HandFeatures.swift        21 点 → 手掌中心、捏合比、四指伸直比、手形（纯 Swift）
    GestureStateMachine.swift 手势状态机（纯 Swift）
    GestureOutput.swift       CGEvent：移动、按键、像素滚动、右 Option
  HeadPose/
    HeadPoseRouter.swift      头姿路由状态机（纯 Swift）
    OneEuroFilter.swift
  Screens/
    DisplaySwitcher.swift     CGDisplay* + CGWarpMouseCursorPosition
    UserActivityMonitor.swift 打字/鼠标 grace
  UI/                         菜单面板、校准视图
LookpointTests/               Swift Testing：头姿路由和手势状态机，包括"不应触发"的情况；
                              hand-recording-*.json.deflate 是真实录制（只有关键点，没有画面）
```

整个 App 只有一个进程独占摄像头，同一帧同时供头姿和手部两路识别使用。

## 已知限制

- 只支持两块屏：主屏是内建屏（没有内建屏时用系统主屏），副屏是另一块激活且非镜像的屏。
- 没有校准时，"看向哪一侧"不区分左右。
- 头转得太偏（大约超过 45°）时 Vision 可能检测不到人脸，这时保持当前屏不变。

## 路线

1. ~~用 `npx gazectl@latest` 验证头姿切屏能不能接受~~
2. ~~头姿切屏骨架~~。验收：日常用半天，看误切换情况
3. ~~手部识别小实验~~：结论是继续用 Vision：把食指尖坐标和捏合距离画在屏幕上，在真实坐姿和光照下看抖动和丢帧，决定继续用 Vision 还是换 MediaPipe 转成的 Core ML 模型
4. **手势状态机** ← 当前：张开手掌激活（没用按住 ⌘，因为目标是不碰键盘），激活期间冻结屏幕选择

## 参考

[gazectl](https://github.com/jnsahaj/gazectl) · [FocusFollow](https://github.com/arefbhrn/FocusFollow) · [hyprgaze](https://github.com/xtalax/hyprgaze) · [HandMouse](https://github.com/TangJiacheng7/HandMouse) · [NonMouse](https://github.com/takeyamayuki/NonMouse) · [control-cursor-with-hand](https://github.com/tecnomanu/control-cursor-with-hand) · [swish](https://github.com/Manavarya09/swish)
