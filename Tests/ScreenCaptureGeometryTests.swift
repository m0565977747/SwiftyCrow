// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Screen capture geometry")
struct ScreenCaptureGeometryTests {

  /// AppKit is bottom-left origin; ScreenCaptureKit's `sourceRect` is top-left
  /// and display-local. A frame near the top of a 1440-point-tall screen must
  /// land near y == 0 in SCK space.
  @Test("flips a global AppKit rect into a top-left display-local rect")
  func flipsToTopLeftDisplayLocal() {
    let screenFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let overlayFrame = CGRect(x: 100, y: 1240, width: 400, height: 100)

    let local = displayLocalRect(overlayFrame: overlayFrame, screenFrame: screenFrame)

    #expect(local == CGRect(x: 100, y: 100, width: 400, height: 100))
  }

  /// A secondary display to the right of the main one has a non-zero origin;
  /// the result must be relative to that display, not global.
  @Test("subtracts the display origin for secondary displays")
  func subtractsDisplayOrigin() {
    let screenFrame = CGRect(x: 2560, y: 200, width: 1920, height: 1080)
    let overlayFrame = CGRect(x: 2760, y: 300, width: 200, height: 100)

    let local = displayLocalRect(overlayFrame: overlayFrame, screenFrame: screenFrame)

    // Bottom edge is 100 points above the screen's bottom (300 - 200), so the
    // top edge is 1080 - 100 - 100 = 880 from the top.
    #expect(local == CGRect(x: 200, y: 880, width: 200, height: 100))
  }

  @Test("clips to the display and returns nil when there is no overlap")
  func clipsAndRejectsNoOverlap() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    let partlyOff = displayLocalRect(
      overlayFrame: CGRect(x: 900, y: -50, width: 200, height: 100),
      screenFrame: screenFrame
    )
    #expect(partlyOff == CGRect(x: 900, y: 950, width: 100, height: 50))

    let fullyOff = displayLocalRect(
      overlayFrame: CGRect(x: 1200, y: 0, width: 10, height: 10),
      screenFrame: screenFrame
    )
    #expect(fullyOff == nil)
  }

}
