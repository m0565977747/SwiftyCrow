// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Ventura OCR layout inference")
struct VenturaOCRLayoutTests {

  // MARK: Internal

  @Test
  func groupsConsecutiveLeftAlignedRows() {
    let lines = [
      row("The quick brown fox", x: 0.1, y: 0.10, width: 0.5, height: 0.04),
      row("jumps over the lazy dog", x: 0.1, y: 0.15, width: 0.55, height: 0.04),
    ]

    let grouped = VenturaOCRLayout.grouping(for: lines)

    #expect(grouped.count == 2)
    #expect(grouped[0].recognitionGroupID == grouped[1].recognitionGroupID)
    #expect(grouped.allSatisfy { $0.alignment == .leading })
    #expect(grouped.allSatisfy { $0.rowCount == 1 })
  }

  @Test
  func keepsDistantRowsInSeparateGroups() {
    let lines = [
      row("Title", x: 0.1, y: 0.10, width: 0.3, height: 0.04),
      row("Footer", x: 0.1, y: 0.80, width: 0.3, height: 0.04),
    ]

    let grouped = VenturaOCRLayout.grouping(for: lines)

    #expect(grouped.count == 2)
    #expect(grouped[0].recognitionGroupID != grouped[1].recognitionGroupID)
  }

  @Test
  func keepsSideBySideCellsInSeparateGroups() {
    let lines = [
      row("Name", x: 0.1, y: 0.10, width: 0.2, height: 0.04),
      row("Value", x: 0.6, y: 0.10, width: 0.2, height: 0.04),
    ]

    let grouped = VenturaOCRLayout.grouping(for: lines)

    #expect(grouped[0].recognitionGroupID != grouped[1].recognitionGroupID)
  }

  @Test
  func keepsTitleAndBodyApartWhenHeightsDiffer() {
    let lines = [
      row("Big headline", x: 0.1, y: 0.10, width: 0.6, height: 0.10),
      row("small body text", x: 0.1, y: 0.21, width: 0.5, height: 0.03),
    ]

    let grouped = VenturaOCRLayout.grouping(for: lines)

    #expect(grouped[0].recognitionGroupID != grouped[1].recognitionGroupID)
  }

  @Test
  func infersCenterAlignmentFromSharedCenters() {
    let lines = [
      row("A centered heading", x: 0.30, y: 0.10, width: 0.40, height: 0.04),
      row("and its subtitle", x: 0.35, y: 0.15, width: 0.30, height: 0.04),
      row("shorter", x: 0.42, y: 0.20, width: 0.16, height: 0.04),
    ]

    let grouped = VenturaOCRLayout.grouping(for: lines)

    #expect(Set(grouped.compactMap(\.recognitionGroupID)).count == 1)
    #expect(grouped.allSatisfy { $0.alignment == .center })
  }

  @Test
  func infersTrailingAlignmentFromSharedRightEdges() {
    let lines = [
      row("Total due", x: 0.50, y: 0.10, width: 0.40, height: 0.04),
      row("$12.00", x: 0.72, y: 0.15, width: 0.18, height: 0.04),
    ]

    let grouped = VenturaOCRLayout.grouping(for: lines)

    #expect(grouped[0].recognitionGroupID == grouped[1].recognitionGroupID)
    #expect(grouped.allSatisfy { $0.alignment == .trailing })
  }

  @Test
  func returnsRowsInReadingOrder() {
    let lines = [
      row("second", x: 0.1, y: 0.15, width: 0.3, height: 0.04),
      row("first", x: 0.1, y: 0.10, width: 0.3, height: 0.04),
    ]

    let grouped = VenturaOCRLayout.grouping(for: lines)

    #expect(grouped.map(\.text) == ["first", "second"])
  }

  @Test
  func infersVerticalColumnFromAspectAndScript() {
    let box = CGRect(x: 0.8, y: 0.1, width: 0.04, height: 0.4)

    #expect(VenturaOCRLayout.isLikelyVerticalCJK(text: "吾輩は猫である", box: box))
  }

  @Test
  func doesNotInferVerticalColumnForLatinOrSingleGlyph() {
    let tall = CGRect(x: 0.8, y: 0.1, width: 0.04, height: 0.4)
    let wide = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.04)

    #expect(!VenturaOCRLayout.isLikelyVerticalCJK(text: "Hello", box: tall))
    #expect(!VenturaOCRLayout.isLikelyVerticalCJK(text: "猫", box: tall))
    #expect(!VenturaOCRLayout.isLikelyVerticalCJK(text: "吾輩は猫である", box: wide))
  }

  @Test
  func neverGroupsVerticalColumns() {
    var column = row("吾輩は猫である", x: 0.80, y: 0.1, width: 0.04, height: 0.4)
    column.isVerticalBlock = true
    var neighbor = row("名前はまだ無い", x: 0.75, y: 0.1, width: 0.04, height: 0.4)
    neighbor.isVerticalBlock = true

    let grouped = VenturaOCRLayout.grouping(for: [column, neighbor])

    #expect(grouped[0].recognitionGroupID != grouped[1].recognitionGroupID)
  }

  // MARK: Private

  private func row(
    _ text: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat
  ) -> OCRResult.Line {
    OCRResult.Line(
      boundingBoxNormalized: CGRect(x: x, y: y, width: width, height: height),
      text: text
    )
  }
}
