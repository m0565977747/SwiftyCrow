// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

// MARK: - VenturaSingleFrameCapture

/// Single-frame capture for macOS 13 Ventura, where `SCScreenshotManager`
/// (macOS 14+) does not exist.
///
/// Spins up a short-lived `SCStream` with the same filter and configuration the
/// screenshot path would use, waits for the first frame ScreenCaptureKit marks
/// `.complete`, converts it to a `CGImage`, and tears the stream down again.
///
/// Ventura quirks this accounts for:
/// - Static content often produces only `.idle` frames for a while (or for
///   ever). After `idleFrameLimit` frames or `idleAcceptDelay`, the most recent
///   `.idle` frame that carried an image buffer is accepted as the screenshot.
/// - A hard `timeout` bounds the whole call; on timeout an `.idle` frame is
///   still preferred over failing, and `ScreenCaptureError.captureTimedOut` is
///   thrown only when no usable frame arrived at all.
/// - `SCStreamConfiguration.sourceRect` is in points of the display's own
///   top-left coordinate space and `width`/`height` are in pixels — the caller
///   already builds the configuration that way.
/// - `SCContentFilter.contentRect` / `pointPixelScale` are macOS 14 API and are
///   deliberately not used here.
///
/// The instance is single-use: one call to `captureImage(filter:configuration:)`
/// per instance, which is why the public entry point is static.
final class VenturaSingleFrameCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

  // MARK: Internal

  /// Captures one frame for `filter` using `configuration`.
  ///
  /// Mutates `configuration` (queue depth, frame interval, audio) so the stream
  /// stays cheap; the caller's pixel format, cursor, `sourceRect`, `width` and
  /// `height` are left untouched.
  static func captureImage(
    filter: SCContentFilter,
    configuration: SCStreamConfiguration
  ) async throws -> CGImage {
    try await VenturaSingleFrameCapture().run(filter: filter, configuration: configuration)
  }

  // MARK: SCStreamOutput

  /// Called on `sampleQueue`. The sample buffer must not outlive this call; only
  /// its `CVPixelBuffer` (a retained, pool-backed reference) is kept for the
  /// idle fallback, and at most one of them at a time.
  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
    guard !isFinished else { return }
    guard let status = Self.frameStatus(of: sampleBuffer) else {
      Log.capture.debug("Ventura capture: frame without status attachment, waiting")
      return
    }
    // `.idle` / `.blank` frames may arrive without an image buffer at all.
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      Log.capture.debug("Ventura capture: frame status \(status.rawValue, privacy: .public) without image buffer, waiting")
      return
    }

    switch status {
    case .complete:
      if let image = Self.makeImage(from: pixelBuffer) {
        finish(.success(image))
      } else {
        Log.capture.error("Ventura capture: could not convert complete frame, waiting for next")
      }

    case .idle:
      let acceptIdle: CVPixelBuffer? = withState { state in
        state.frameCount += 1
        state.latestIdleBuffer = pixelBuffer
        let firstFrameTime = state.firstFrameTime ?? .now
        state.firstFrameTime = firstFrameTime
        let onlyIdleForTooLong =
          state.frameCount >= Self.idleFrameLimit
            || firstFrameTime.duration(to: .now) >= Self.idleAcceptDelay
        return onlyIdleForTooLong ? pixelBuffer : nil
      }
      if let acceptIdle {
        Log.capture.debug("Ventura capture: only idle frames arrived, accepting latest idle frame")
        acceptFallback(acceptIdle)
      }

    case .blank:
      // Nothing to show yet (e.g. the source is being composed). Wait.
      withState { $0.frameCount += 1 }

    case .started, .suspended, .stopped:
      return

    @unknown default:
      return
    }
  }

  // MARK: SCStreamDelegate

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    Log.capture.error("Ventura capture: stream stopped with error \(error.localizedDescription, privacy: .public)")
    finish(.failure(error))
  }

  // MARK: Private

  private struct State {
    var continuation: CheckedContinuation<Result<CGImage, any Error>, Never>?
    var result: Result<CGImage, any Error>?
    var frameCount = 0
    var firstFrameTime: ContinuousClock.Instant?
    var latestIdleBuffer: CVPixelBuffer?
  }

  /// Hard bound on the whole capture, from `startCapture()` to a usable frame.
  private static let timeout: Duration = .seconds(3)
  /// After this many frames without a `.complete` one, take the latest `.idle`.
  private static let idleFrameLimit = 15
  /// After this long without a `.complete` frame, take the latest `.idle`.
  private static let idleAcceptDelay: Duration = .seconds(1.5)

  private static let sampleQueue = DispatchQueue(label: "dev.PangMo5.SwiftyCrow.capture")

  /// One context for every capture: creating a `CIContext` per frame is the
  /// expensive part of the conversion. `CIContext` is thread-safe.
  private nonisolated(unsafe) static let ciContext = CIContext(options: [.cacheIntermediates: false])

  private let lock = NSLock()
  private var state = State()

  private var isFinished: Bool {
    withState { $0.result != nil }
  }

  private static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let rawStatus = attachments.first?[.status] as? Int
    else {
      return nil
    }
    return SCFrameStatus(rawValue: rawStatus)
  }

  private static func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    return ciContext.createCGImage(ciImage, from: ciImage.extent)
  }

  private func run(
    filter: SCContentFilter,
    configuration: SCStreamConfiguration
  ) async throws -> CGImage {
    // Keep the stream cheap: a few buffers, 60 fps ceiling, video only.
    configuration.queueDepth = 3
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.capturesAudio = false

    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.sampleQueue)

    let clock = ContinuousClock()
    let started = clock.now
    do {
      try await stream.startCapture()
    } catch {
      Log.capture.error("Ventura capture: startCapture failed \(error.localizedDescription, privacy: .public)")
      throw error
    }

    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: Self.timeout)
      guard !Task.isCancelled else { return }
      self?.handleTimeout()
    }

    let result = await waitForResult()
    timeoutTask.cancel()

    do {
      try await stream.stopCapture()
    } catch {
      // The stream may already be stopped (e.g. after `didStopWithError`).
      Log.capture.debug("Ventura capture: stopCapture failed \(error.localizedDescription, privacy: .public)")
    }

    let elapsed = started.duration(to: clock.now)
    switch result {
    case .success:
      Log.capture.debug("Ventura capture took \(elapsed.loggedSeconds, privacy: .public)s")
    case .failure(let error):
      Log.capture.error(
        "Ventura capture failed after \(elapsed.loggedSeconds, privacy: .public)s: \(error.localizedDescription, privacy: .public)"
      )
    }
    return try result.get()
  }

  /// Suspends until `finish(_:)` has been called. A result recorded before the
  /// continuation is installed (a frame that raced `startCapture()` returning)
  /// resumes immediately.
  private func waitForResult() async -> Result<CGImage, any Error> {
    await withCheckedContinuation { continuation in
      let existing: Result<CGImage, any Error>? = withState { state in
        if let result = state.result { return result }
        state.continuation = continuation
        return nil
      }
      if let existing {
        continuation.resume(returning: existing)
      }
    }
  }

  /// Records the outcome and resumes the waiting continuation exactly once.
  /// Later calls are ignored, so a trailing frame, the timeout, and
  /// `didStopWithError` can all race safely.
  private func finish(_ result: Result<CGImage, any Error>) {
    let continuation: CheckedContinuation<Result<CGImage, any Error>, Never>? = withState { state in
      guard state.result == nil else { return nil }
      state.result = result
      state.latestIdleBuffer = nil
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    continuation?.resume(returning: result)
  }

  private func acceptFallback(_ pixelBuffer: CVPixelBuffer) {
    if let image = Self.makeImage(from: pixelBuffer) {
      finish(.success(image))
    } else {
      Log.capture.error("Ventura capture: could not convert idle frame")
    }
  }

  private func handleTimeout() {
    let idleBuffer: CVPixelBuffer? = withState { state in
      guard state.result == nil else { return nil }
      return state.latestIdleBuffer
    }
    if let idleBuffer, let image = Self.makeImage(from: idleBuffer) {
      Log.capture.error("Ventura capture: timed out waiting for a complete frame, using last idle frame")
      finish(.success(image))
    } else {
      finish(.failure(ScreenCaptureError.captureTimedOut))
    }
  }

  private func withState<T>(_ body: (inout State) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&state)
  }

}
