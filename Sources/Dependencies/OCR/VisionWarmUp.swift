// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CoreText
import Foundation

// MARK: - VisionWarmUp

/// Loads Vision's text-recognition model ahead of any real capture.
///
/// The first recognition request after the system's shared model cache goes
/// cold costs tens of seconds — ~40s measured here, against ~0.25s once it's
/// loaded — and the cache goes cold again on its own while the app sits idle.
/// Paying that on the capture the user just asked for is what made Live and
/// Capture look like they had hung: a spinner, then nothing.
///
/// So the load happens in the background instead — at launch, on wake, and while
/// the user is still dragging out a region. Nothing here makes a cold load
/// faster; it moves the cost to a moment when nobody is waiting on it.
///
/// The actor is pipeline-agnostic: the caller supplies the request(s) to run on
/// the probe image, so the macOS 26 document pipeline and the Ventura classic
/// pipeline share the same in-flight serialization.
actor VisionWarmUp {

  // MARK: Internal

  static let shared = VisionWarmUp()

  /// Concurrent callers share one load, so a capture that starts mid-load joins
  /// it instead of queueing a second one — and a caller that gives up doesn't
  /// take the load down with it.
  ///
  /// Deliberately not memoized across calls: the shared cache goes cold whenever
  /// the system decides to, and there's no API to ask whether it has. Re-probing
  /// costs ~0.1s while it's still warm, which is far cheaper than being wrong.
  func run(_ load: @escaping @Sendable (CGImage) async throws -> Void) async {
    guard let probe = Self.probe else { return }
    if let inFlight {
      await inFlight.value
      return
    }
    let task = Task<Void, Never> {
      let clock = ContinuousClock()
      let started = clock.now
      do {
        try await load(probe)
        let elapsed = clock.now - started
        if elapsed > .seconds(2) {
          Log.ocr.log("Warm-up loaded a cold model in \(elapsed.loggedSeconds, privacy: .public)s")
        } else {
          Log.ocr.debug("Warm-up found the model ready (\(elapsed.loggedSeconds, privacy: .public)s)")
        }
      } catch {
        Log.ocr.error("Warm-up failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    inFlight = task
    await task.value
    inFlight = nil
  }

  func waitForInFlight() async {
    if let inFlight {
      await inFlight.value
    }
  }

  // MARK: Private

  /// Small, but with real text drawn on it: a blank image lets Vision finish
  /// without ever loading the recognition model, which would warm nothing.
  private static let probe: CGImage? = {
    let width = 256
    let height = 64
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let attributed = NSAttributedString(
      string: "Warm up 123",
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 32, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
          red: 0,
          green: 0,
          blue: 0,
          alpha: 1
        ),
      ]
    )
    context.textPosition = CGPoint(x: 8, y: 18)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    return context.makeImage()
  }()

  private var inFlight: Task<Void, Never>?
}
