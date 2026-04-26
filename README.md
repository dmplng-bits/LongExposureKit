# LongExposureKit

A UI-agnostic Swift Package for long-exposure photography on Apple platforms.

- **Camera capture** via AVFoundation (iOS / visionOS)
- **Frame blending** (Core Image): mean blend (daytime) + lighten blend (night trails)
- **Optional AI stabilization** via the Vision framework (translation or homographic registration)
- **Async-stream API** — drive a capture with `for await event in controller.capture(...)`

Swift 6 language mode. No third-party dependencies.

**Supported platforms.** The full pipeline runs on **iOS** and
**visionOS** (camera capture requires AVCaptureDevice). The
processing engine — `LongExposureProcessor` and `FrameStabilizer` —
also builds on **macOS** and **tvOS** for anyone who wants to feed
frames from another source.

`CameraManager` and `LongExposureController` are guarded by
`#if os(iOS) || os(visionOS)`; on other platforms they simply don't
exist.

**Minimum deployment target.** The package doesn't declare an
explicit minimum — it inherits from the app that consumes it. The
code uses `AsyncStream`, `@MainActor`, and structured concurrency,
so the effective floor is iOS 15 / macOS 12 / tvOS 15 / visionOS 1.

> watchOS is not supported — the Vision framework isn't available
> there. If you need to build for watchOS, the Vision imports in
> `FrameStabilizer.swift` would need a `#if canImport(Vision)`
> guard, and stabilization would become a no-op.

---

## Install

### Option A — local package (while hacking)

In Xcode: **File → Add Package Dependencies → Add Local…** and pick the
`LongExposureKit` folder. Add the product to your app target.

### Option B — git dependency

Push the `LongExposureKit` folder to a git repo, then in Xcode:
**File → Add Package Dependencies → paste your repo URL**.

Or in another Swift Package's `Package.swift`:

```swift
.package(url: "https://github.com/you/LongExposureKit.git", from: "0.1.0"),
```

---

## Usage — the 30-second version

```swift
import LongExposureKit

@MainActor
final class MyCameraViewModel: ObservableObject {
    let controller = LongExposureController()
    @Published var image: UIImage?
    @Published var progress: Double = 0

    var session: AVCaptureSession { controller.session }

    func start() async {
        try? await controller.startCamera()
    }

    func capture() async {
        let settings = CaptureSettings(
            duration: 5,
            blendMode: .mean,
            stabilization: .translation // set to nil to disable
        )

        for await event in controller.capture(settings: settings) {
            switch event {
            case .progress(let p):      progress = p
            case .finished(let result): image = result.image
            case .failed(let error):    print("capture failed:", error)
            case .started, .stabilizing: break
            }
        }
    }
}
```

Hook the session into an `AVCaptureVideoPreviewLayer` via a
`UIViewRepresentable` and you have a working camera.

---

## What's in the box

| Type | Role |
| --- | --- |
| `LongExposureController` | The high-level entry point. `@MainActor`. Wraps everything below. |
| `CameraManager` | AVCaptureSession + frame delegate. Use directly if you want lower-level control. |
| `LongExposureProcessor` | The blending engine. Feed `CVPixelBuffer`s, get a `CGImage` out (or a `UIImage`/`NSImage` via platform-conditional conveniences). |
| `FrameStabilizer` | Vision-based frame alignment. Stateless per-frame. |
| `BlendMode` | `.mean` (day) or `.lighten` (night). |
| `StabilizationMode` | `.translation` (fast) or `.homographic` (slower, stronger). |
| `CaptureSettings` / `CaptureEvent` / `CaptureResult` | Value types driving the async API. |

You can:

- **Drive the full pipeline** — use `LongExposureController`.
- **Bring your own camera** — use `LongExposureProcessor` and `FrameStabilizer` independently, feed them buffers from wherever.
- **Bring your own blend** — use `CameraManager`'s delegate directly and write your own accumulator.

---

## Permissions (host app)

You must add the following to the host app's Info tab:

- `NSCameraUsageDescription` — required to open the camera.
- `NSPhotoLibraryAddUsageDescription` — only if you save the resulting image via `PHPhotoLibrary`. The package itself doesn't touch Photos.

---

## Known limitations

- **Mean-blend precision drift.** Running mean through Core Image with 8-bit
  intermediate renders loses precision on very long captures. For correctness
  on 30s+ exposures, swap to a vImage Float32 accumulator in
  `LongExposureProcessor`.
- **Per-frame exposure is auto.** `CameraManager.lockExposure(iso:duration:)`
  is available; the controller doesn't call it by default.
- **Simulator has no camera.** Tests run; capture needs a real device.

---

## Running tests

From the package directory:

```sh
swift test
```

Tests cover structural behavior (frame counting, reset, render nil-ness).
Pixel-correctness tests are stubbed with TODO comments in
`LongExposureProcessorTests.swift`.
