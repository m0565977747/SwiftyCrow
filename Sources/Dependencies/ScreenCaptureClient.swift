// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import CoreGraphics
import DependenciesMacros
import Foundation
import ScreenCaptureKit

// MARK: - ScreenCaptureClient

@DependencyClient
struct ScreenCaptureClient {
  /// Captures a region of a display.
  ///
  /// `overlayFrame` is in global AppKit screen coordinates (points, bottom-left origin).
  /// Pass `nil` to capture the whole display.
  var captureImage: @Sendable (
    _ overlayFrame: CGRect?,
    _ displayID: CGDirectDisplayID?,
    _ excludingProcessID: pid_t?
  ) async throws -> CGImage

  /// Captures a single window by id, independent of what's stacked on top of it
  /// (matches the macOS screenshot window mode).
  var captureWindow: @Sendable (_ windowID: CGWindowID) async throws -> CGImage
}

// MARK: - ScreenCaptureError

enum ScreenCaptureError: Error, LocalizedError, Equatable {
  case emptyRegion
  case noDisplay
  case permissionRequired
  case windowUnavailable
  case captureTimedOut

  var errorDescription: String? {
    switch self {
    case .emptyRegion:
      "The capture region is empty."
    case .noDisplay:
      "No display available for capture."
    case .permissionRequired:
      "Screen Recording permission is required. Allow it in System Settings and restart the app."
    case .windowUnavailable:
      "That window is no longer available to capture."
    case .captureTimedOut:
      "Screen capture timed out waiting for a frame."
    }
  }
}

// MARK: - ScreenCaptureClient + DependencyKey

extension ScreenCaptureClient: DependencyKey {
  static let liveValue = ScreenCaptureClient(
    captureImage: { overlayFrame, displayID, excludingProcessID in
      try await ScreenRecordingPermissionTracker.shared.requestIfNeeded()
      let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )

      let display = content.displays.first { display in
        if let displayID { return display.displayID == displayID }
        return display.displayID == CGMainDisplayID()
      } ?? content.displays.first

      guard let display else {
        throw ScreenCaptureError.noDisplay
      }

      let nsScreen = NSScreen.screens.first { screen in
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value == display.displayID
      }
      let scale = nsScreen?.backingScaleFactor ?? 1

      // Resolve exclusions from the current ScreenCaptureKit snapshot on every
      // capture. Passing a window id that was read before the overlay panel was
      // created made the live loop capture its own previous frame forever. A
      // process id is stable for this launch and excludes every SwiftyCrow
      // surface, including panels created after Live starts.
      let excludedApplications = excludingProcessID.map { processID in
        content.applications.filter { $0.processID == processID }
      } ?? []
      let excludedWindows = excludingProcessID.map { processID in
        content.windows.filter { $0.owningApplication?.processID == processID }
      } ?? []
      let filter =
        if !excludedApplications.isEmpty {
          SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
          )
        } else {
          // Some system states omit an application entry while still reporting
          // its windows. Keep the same process-based contract in that case.
          SCContentFilter(display: display, excludingWindows: excludedWindows)
        }

      let configuration = SCStreamConfiguration()
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
      configuration.showsCursor = false

      // `sourceRect` is in points of the display's own top-left coordinate
      // space and `width`/`height` are in pixels — on every supported OS,
      // including macOS 13, where the SCStream-based fallback runs.
      if
        let overlayFrame,
        let nsScreen,
        let sourceRect = displayLocalRect(overlayFrame: overlayFrame, screenFrame: nsScreen.frame)
      {
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(sourceRect.width * scale))
        configuration.height = max(1, Int(sourceRect.height * scale))
      } else {
        configuration.width = Int(Double(display.width) * scale)
        configuration.height = Int(Double(display.height) * scale)
      }

      return try await SingleFrameCapturer.captureImage(filter: filter, configuration: configuration)
    },
    captureWindow: { windowID in
      try await ScreenRecordingPermissionTracker.shared.requestIfNeeded()
      let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
      guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
        throw ScreenCaptureError.windowUnavailable
      }

      // The window may live on a non-main display; match its display's backing
      // scale so the screenshot keeps native resolution.
      let display = content.displays.first { $0.frame.intersects(window.frame) }
      let nsScreen = NSScreen.screens.first { screen in
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value == display?.displayID
      }
      let scale = nsScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

      let configuration = SCStreamConfiguration()
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
      configuration.showsCursor = false
      configuration.width = max(1, Int(window.frame.width * scale))
      configuration.height = max(1, Int(window.frame.height * scale))

      let filter = SCContentFilter(desktopIndependentWindow: window)
      return try await SingleFrameCapturer.captureImage(filter: filter, configuration: configuration)
    }
  )
}

// MARK: - SingleFrameCapturer

/// Routes a one-shot capture to `SCScreenshotManager` where it exists
/// (macOS 14+) and to the `SCStream`-based `VenturaSingleFrameCapture` on
/// macOS 13.
private enum SingleFrameCapturer {
  static func captureImage(
    filter: SCContentFilter,
    configuration: SCStreamConfiguration
  ) async throws -> CGImage {
    if #available(macOS 14.0, *) {
      return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    } else {
      return try await VenturaSingleFrameCapture.captureImage(filter: filter, configuration: configuration)
    }
  }
}

extension DependencyValues {
  var screenCapture: ScreenCaptureClient {
    get { self[ScreenCaptureClient.self] }
    set { self[ScreenCaptureClient.self] = newValue }
  }
}

/// Converts an AppKit-global rectangle (points, bottom-left origin) into
/// a display-local rectangle in ScreenCaptureKit's top-left coordinate space.
///
/// `screenFrame` is the display's `NSScreen.frame`. Internal (not private) so
/// the flip can be unit-tested without a real `NSScreen`.
func displayLocalRect(overlayFrame: CGRect, screenFrame: CGRect) -> CGRect? {
  let intersection = overlayFrame.intersection(screenFrame)
  guard !intersection.isNull, !intersection.isEmpty else { return nil }
  return CGRect(
    x: intersection.minX - screenFrame.minX,
    y: screenFrame.maxY - intersection.maxY,
    width: intersection.width,
    height: intersection.height
  )
}

// MARK: - ScreenRecordingPermissionTracker

private actor ScreenRecordingPermissionTracker {

  // MARK: Internal

  static let shared = ScreenRecordingPermissionTracker()

  func requestIfNeeded() async throws {
    if CGPreflightScreenCaptureAccess() {
      return
    }

    if hasRequested {
      throw ScreenCaptureError.permissionRequired
    }
    hasRequested = true

    let granted = CGRequestScreenCaptureAccess()
    if !granted || !CGPreflightScreenCaptureAccess() {
      throw ScreenCaptureError.permissionRequired
    }
  }

  // MARK: Private

  private var hasRequested = false

}
