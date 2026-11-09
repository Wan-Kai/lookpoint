# lookpoint

macOS 菜单栏工具，用笔记本自带摄像头做两件事：

1. **看哪块屏，光标就去哪块屏**：根据头部朝向（yaw/pitch）在主屏（内建屏，带摄像头）和副屏之间切换。不做眼动追踪。
2. **用手势控制鼠标**（还没做）：按住 ⌘ 时，手势接管移动、捏合点击、拖拽、滚动。

当前进度：头姿切屏可用（第 2 步）；手部识别实验已就绪（第 3 步），等实测数据决定用 Vision 还是 MediaPipe。

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

## 手部识别实验（第 3 步）

菜单 → 手部实验…。窗口打开期间每帧都跑手部识别（30 fps），并且暂停按头姿切屏；关掉窗口就停止手部识别。

- 画面是镜像的，和照镜子一样：白色是 21 个关键点组成的骨架，红线是食指尖的原始轨迹，绿线是 One-Euro 滤波后的轨迹；捏合时指尖圆点变成黄色。
- 底部曲线：拇指尖到食指尖的距离（归一化坐标），虚线是捏合迟滞阈值 on 0.055 / off 0.085。
- 右侧数据：检测帧率、识别到手的比例、单帧耗时、手静止时的抖动（换算成主屏点数，原始 / 滤波后）、捏合距离、捏合距离 ÷ 掌长（和手离摄像头多远无关）、捏合次数。
- 录制：把逐帧关键点存到 `~/Documents/lookpoint-recordings/hand-*.json`，第 4 步的手势状态机单测会用这些录制。

建议在真实坐姿和光照下看这几项：

1. 手静止时，滤波后的抖动能不能稳定在几个点以内；
2. 识别到手的比例，以及手抬到键盘上方、侧面时会不会丢；
3. 连续捏合 20 次，捏合次数是不是正好 20，有没有一次捏合被数成两次（曲线在两条虚线之间来回穿）；
4. 手前后移动时，捏合距离的变化幅度。变化太大的话，第 4 步改用"捏合/掌长"判定。

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
    HandLab.swift             第 3 步实验的统计和录制
  HeadPose/
    HeadPoseRouter.swift      头姿路由状态机（纯 Swift）
    OneEuroFilter.swift
  Screens/
    DisplaySwitcher.swift     CGDisplay* + CGWarpMouseCursorPosition
    UserActivityMonitor.swift 打字/鼠标 grace
  UI/                         菜单面板、校准视图
LookpointTests/               Swift Testing：用录制的头姿序列断言路由输出，包括"不应切换"的情况
```

整个 App 只有一个进程独占摄像头，同一帧同时供头姿和手部两路识别使用。

## 已知限制

- 只支持两块屏：主屏是内建屏（没有内建屏时用系统主屏），副屏是另一块激活且非镜像的屏。
- 没有校准时，"看向哪一侧"不区分左右。
- 头转得太偏（大约超过 45°）时 Vision 可能检测不到人脸，这时保持当前屏不变。

## 路线

1. ~~用 `npx gazectl@latest` 验证头姿切屏能不能接受~~
2. ~~头姿切屏骨架~~。验收：日常用半天，看误切换情况
3. **手部识别小实验** ← 当前：把食指尖坐标和捏合距离画在屏幕上，在真实坐姿和光照下看抖动和丢帧，决定继续用 Vision 还是换 MediaPipe 转成的 Core ML 模型
4. 手势状态机（移动、捏合点击、拖拽、滚动）+ 按住 ⌘ 激活 + 手势激活期间冻结屏幕选择

## 参考

[gazectl](https://github.com/jnsahaj/gazectl) · [FocusFollow](https://github.com/arefbhrn/FocusFollow) · [hyprgaze](https://github.com/xtalax/hyprgaze) · [HandMouse](https://github.com/TangJiacheng7/HandMouse) · [NonMouse](https://github.com/takeyamayuki/NonMouse) · [control-cursor-with-hand](https://github.com/tecnomanu/control-cursor-with-hand) · [swish](https://github.com/Manavarya09/swish)
