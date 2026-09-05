// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

// MARK: - VenturaOCRLayout

/// Geometric stand-in for the page structure `RecognizeDocumentsRequest`
/// provides on macOS 26. The classic `VNRecognizeTextRequest` returns flat rows
/// with no paragraph membership, alignment, or text direction, so those are
/// inferred here from row boxes and script alone. Pure and Vision-free so it can
/// be unit-tested on any OS.
enum VenturaOCRLayout {

  // MARK: Internal

  /// Assigns `recognitionGroupID` and `alignment` to rows by clustering them
  /// geometrically, and returns them in reading order (top to bottom, then left
  /// to right). Each row keeps `rowCount == 1`; `coalescingParagraphFragments`
  /// stitches rows into paragraphs downstream, exactly as on macOS 26.
  ///
  /// Consecutive rows join a group when they overlap horizontally by at least
  /// 40% (or their left edges sit within half a row height), the vertical gap
  /// between them is at most 0.9× the median row height, and their heights are
  /// within ×0.6–1.6 of each other. Vertical CJK columns never join a group
  /// here; the coalescer already understands neighboring columns.
  static func grouping(for lines: [OCRResult.Line]) -> [OCRResult.Line] {
    guard !lines.isEmpty else { return [] }
    let ordered = lines.sorted { lhs, rhs in
      let lhsBox = lhs.boundingBoxNormalized.standardized
      let rhsBox = rhs.boundingBoxNormalized.standardized
      if abs(lhsBox.minY - rhsBox.minY) <= min(lhsBox.height, rhsBox.height) * 0.35 {
        return lhsBox.minX < rhsBox.minX
      }
      return lhsBox.minY < rhsBox.minY
    }
    let medianHeight = OCRClient.median(
      ordered.filter { !$0.isVerticalBlock }.map { $0.boundingBoxNormalized.standardized.height }
    ) ?? OCRClient.median(ordered.map { $0.boundingBoxNormalized.standardized.height })
      ?? 0

    var groups = [[Int]]()
    for index in ordered.indices {
      if
        let last = groups.last?.last,
        joins(ordered[last], ordered[index], medianHeight: medianHeight)
      {
        groups[groups.count - 1].append(index)
      } else {
        groups.append([index])
      }
    }

    var result = ordered
    for (groupID, members) in groups.enumerated() {
      let alignment = inferredAlignment(for: members.map { ordered[$0] })
      for member in members {
        result[member].recognitionGroupID = groupID
        result[member].rowCount = 1
        result[member].alignment = alignment
      }
    }
    return result
  }

  /// `VNRecognizedTextObservation` carries no text direction. A tall, narrow
  /// box holding two or more mostly-CJK characters is read as one vertical
  /// column; everything else stays horizontal.
  static func isLikelyVerticalCJK(text: String, box: CGRect) -> Bool {
    let box = box.standardized
    guard box.width > 0, box.height / box.width >= 2.5 else { return false }
    let characters = text.filter { !$0.isWhitespace }
    guard characters.count >= 2 else { return false }
    let scalars = characters.unicodeScalars
    let cjkCount = scalars.filter(isCJKScalar).count
    return cjkCount * 2 >= scalars.count
  }

  /// A single row falls back to the page-position heuristic the supplemental
  /// pass has always used. Multi-row groups compare their edges: shared left
  /// edges read as leading, shared right edges (with ragged lefts) as trailing,
  /// and shared centers (with both edges ragged) as centered.
  static func inferredAlignment(for lines: [OCRResult.Line]) -> OverlayTextAlignment {
    guard lines.count > 1 else {
      guard let line = lines.first else { return .leading }
      return OCRClient.inferredSupplementalAlignment(for: line.boundingBoxNormalized.standardized)
    }
    let boxes = lines.map { $0.boundingBoxNormalized.standardized }
    let tolerance = (OCRClient.median(boxes.map(\.height)) ?? 0) * 0.15
    func aligned(_ edge: (CGRect) -> CGFloat) -> Bool {
      let values = boxes.map(edge)
      guard let minimum = values.min(), let maximum = values.max() else { return false }
      return maximum - minimum <= tolerance
    }
    let leading = aligned(\.minX)
    let trailing = aligned(\.maxX)
    let centered = aligned(\.midX)
    if leading { return .leading }
    if trailing { return .trailing }
    if centered { return .center }
    return .leading
  }

  // MARK: Private

  private static func joins(
    _ previous: OCRResult.Line,
    _ next: OCRResult.Line,
    medianHeight: CGFloat
  ) -> Bool {
    guard !previous.isVerticalBlock, !next.isVerticalBlock else { return false }
    let lhs = previous.boundingBoxNormalized.standardized
    let rhs = next.boundingBoxNormalized.standardized
    guard lhs.height > 0, rhs.height > 0 else { return false }

    let heightRatio = rhs.height / lhs.height
    guard heightRatio >= 0.6, heightRatio <= 1.6 else { return false }

    let referenceHeight = medianHeight > 0 ? medianHeight : max(lhs.height, rhs.height)
    let gap = rhs.minY - lhs.maxY
    // Rows must follow one another: side-by-side cells on the same row have no
    // horizontal overlap and are rejected below, while a row that merely
    // touches or slightly overlaps the previous one still counts as its wrap.
    guard gap <= referenceHeight * 0.9, gap >= -min(lhs.height, rhs.height) * 0.5 else {
      return false
    }

    let overlap = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
    let narrower = max(0.000_001, min(lhs.width, rhs.width))
    let sharesColumn = overlap / narrower >= 0.4
    let sharesLeftEdge = abs(lhs.minX - rhs.minX) <= min(lhs.height, rhs.height) * 0.5
    return sharesColumn || sharesLeftEdge
  }

  private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040 ... 0x30FF, // Hiragana, Katakana
         0x31F0 ... 0x31FF, // Katakana phonetic extensions
         0x3400 ... 0x4DBF, // CJK Extension A
         0x4E00 ... 0x9FFF, // CJK Unified Ideographs
         0xAC00 ... 0xD7AF, // Hangul syllables
         0xF900 ... 0xFAFF, // CJK Compatibility Ideographs
         0x20000 ... 0x2FA1F: // CJK Extensions B–F
      true
    default:
      false
    }
  }
}
