// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import DependenciesMacros
import Foundation

// MARK: - OCRClient

@DependencyClient
struct OCRClient {
  var recognizeText: @Sendable (_ image: CGImage, _ language: Language) async throws -> OCRResult
  /// Loads Vision's document-recognition model without a capture waiting on it.
  /// See `VisionWarmUp` for why this has to happen off the critical path.
  var warmUp: @Sendable () async -> Void
}

// MARK: DependencyKey

extension OCRClient: DependencyKey {
  /// macOS 26 gets Apple's document-layout recognizer; everything older runs
  /// the classic `VNRecognizeTextRequest` pipeline with geometric layout
  /// inference. Both share the post-processing helpers below.
  static let liveValue = OCRClient(
    recognizeText: { image, language in
      if #available(macOS 26.0, *) {
        return try await ModernOCRPipeline.recognizeText(in: image, language: language)
      } else {
        return try await VenturaOCRPipeline.recognizeText(in: image, language: language)
      }
    },
    warmUp: {
      if #available(macOS 26.0, *) {
        await ModernOCRPipeline.warmUp()
      } else {
        await VenturaOCRPipeline.warmUp()
      }
    }
  )
}

// MARK: - OCRParagraphLineGrouping

/// Preserves explicit semantic breaks that Vision exposes inside a document
/// paragraph. Visual wraps share a group; lines separated by a transcript
/// newline do not get stitched back into one translation unit.
enum OCRParagraphLineGrouping {

  // MARK: Internal

  static func segmentIndices(
    paragraphTranscript: String,
    lineTranscripts: [String]
  ) -> [Int] {
    guard !lineTranscripts.isEmpty else { return [] }
    let segments = paragraphTranscript
      .split(whereSeparator: \.isNewline)
      .map { normalized(String($0)) }
      .filter { !$0.isEmpty }
    guard segments.count > 1 else {
      return Array(repeating: 0, count: lineTranscripts.count)
    }

    var segmentIndex = 0
    var consumed = ""
    return lineTranscripts.map { transcript in
      let line = normalized(transcript)
      while
        segmentIndex < segments.count - 1,
        !segments[segmentIndex].hasPrefix(consumed + line)
      {
        segmentIndex += 1
        consumed = ""
      }

      let result = segmentIndex
      consumed += line
      if
        segmentIndex < segments.count - 1,
        consumed.count >= segments[segmentIndex].count
        || !segments[segmentIndex].hasPrefix(consumed)
      {
        segmentIndex += 1
        consumed = ""
      }
      return result
    }
  }

  // MARK: Private

  private static func normalized(_ value: String) -> String {
    value.filter { !$0.isWhitespace && !$0.isNewline }
  }
}

// MARK: - Shared recognition helpers

/// Pure geometry/text helpers shared by `ModernOCRPipeline` (macOS 26) and
/// `VenturaOCRPipeline` (macOS 13+). Nothing here touches Vision.
extension OCRClient {
  struct RecognizedWord: Equatable, Sendable {
    var text: String
    var box: CGRect
  }

  /// Vision reports normalized boxes with a bottom-left origin; the overlay
  /// model uses top-left.
  static func topLeftBox(_ box: CGRect) -> CGRect {
    CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
  }

  static func median(_ values: [CGFloat]) -> CGFloat? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  static func styleRuns(
    in transcript: String,
    words: [RecognizedWord]
  ) -> [OverlaySourceStyleRun] {
    guard !transcript.isEmpty, !words.isEmpty else { return [] }
    let source = transcript as NSString
    var cursor = 0
    var runs = [OverlaySourceStyleRun]()
    for word in words {
      guard cursor < source.length else { break }
      let searchRange = NSRange(location: cursor, length: source.length - cursor)
      var range = source.range(of: word.text, options: [], range: searchRange)
      if range.location == NSNotFound {
        range = source.range(of: word.text, options: .caseInsensitive, range: searchRange)
      }
      guard range.location != NSNotFound else { continue }
      runs.append(OverlaySourceStyleRun(range: range, box: word.box))
      cursor = range.location + range.length
    }
    return runs
  }

  static func shouldRunSupplementalRecognition(
    for lines: [OCRResult.Line],
    language: Language
  ) -> Bool {
    guard !lines.contains(where: \.isVerticalBlock) else { return false }
    let languageCode = language.localeLanguage.languageCode?.identifier
    if !language.isAuto, languageCode == "ja" { return false }
    if language.isAuto, lines.map(\.text).joined().unicodeScalars.contains(where: isJapaneseScalar) {
      return false
    }
    return true
  }

  static func inferredSupplementalAlignment(for box: CGRect) -> OverlayTextAlignment {
    box.width >= 0.35 && abs(box.midX - 0.5) <= 0.06 ? .center : .leading
  }

  static func isJapaneseScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040 ... 0x30FF,
         0x31F0 ... 0x31FF:
      true
    default:
      false
    }
  }
}

// MARK: - OCRSupplementalMerger

enum OCRSupplementalMerger {

  // MARK: Internal

  /// Adds only text rows that document recognition omitted. RecognizeText is a
  /// high-recall companion pass; overlapping document rows remain canonical so
  /// paragraph membership, style, and alignment are not destabilized.
  static func addingUncovered(
    _ supplemental: [OCRResult.Line],
    to primary: [OCRResult.Line]
  ) -> [OCRResult.Line] {
    let additions = supplemental.filter { candidate in
      !primary.contains { covers(candidate, primary: $0) }
    }
    return (primary + additions).sorted { lhs, rhs in
      let lhsBox = lhs.boundingBoxNormalized.standardized
      let rhsBox = rhs.boundingBoxNormalized.standardized
      if abs(lhsBox.minY - rhsBox.minY) <= min(lhsBox.height, rhsBox.height) * 0.35 {
        return lhsBox.minX < rhsBox.minX
      }
      return lhsBox.minY < rhsBox.minY
    }
  }

  // MARK: Private

  private static func covers(_ candidate: OCRResult.Line, primary: OCRResult.Line) -> Bool {
    let candidateBox = candidate.boundingBoxNormalized.standardized
    let primaryBox = primary.boundingBoxNormalized.standardized
    let intersection = candidateBox.intersection(primaryBox)
    guard !intersection.isNull, !intersection.isEmpty else { return false }
    let intersectionArea = intersection.width * intersection.height
    let candidateCoverage = intersectionArea / max(0.000_001, candidateBox.width * candidateBox.height)
    if candidateCoverage >= 0.58 { return true }

    let candidateText = normalized(candidate.text)
    let primaryText = normalized(primary.text)
    guard
      !candidateText.isEmpty,
      candidateText == primaryText || candidateText.contains(primaryText) || primaryText.contains(candidateText)
    else { return false }
    return hypot(candidateBox.midX - primaryBox.midX, candidateBox.midY - primaryBox.midY)
      <= max(candidateBox.height, primaryBox.height) * 1.5
  }

  private static func normalized(_ text: String) -> String {
    text.lowercased().unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }
      .map(String.init)
      .joined()
  }
}

// MARK: - OCRTextTokenization

/// Produces style-sized ranges while leaving their geometry to Vision. Words
/// remain intact for Latin scripts; CJK text remains contiguous; punctuation is
/// separate so brackets, links, and emphasized symbols can keep their own style.
enum OCRTextTokenization {

  // MARK: Internal

  static func ranges(in text: String) -> [Range<String.Index>] {
    var result = [Range<String.Index>]()
    var start: String.Index?
    var currentKind: Kind?

    func finish(at end: String.Index) {
      if let start, start < end {
        result.append(start ..< end)
      }
      start = nil
      currentKind = nil
    }

    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(after: index)
      guard let kind = Kind(text[index]) else {
        finish(at: index)
        index = next
        continue
      }
      if currentKind != kind {
        finish(at: index)
        start = index
        currentKind = kind
      }
      index = next
    }
    finish(at: text.endIndex)
    return result
  }

  // MARK: Private

  private enum Kind: Equatable {
    case cjk
    case word
    case punctuation

    // MARK: Lifecycle

    init?(_ character: Character) {
      let scalars = character.unicodeScalars
      guard !scalars.allSatisfy(\.properties.isWhitespace) else { return nil }
      if scalars.contains(where: { Self.isCJK($0) }) {
        self = .cjk
      } else if scalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) {
        self = .word
      } else {
        self = .punctuation
      }
    }

    // MARK: Private

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
      switch scalar.value {
      case 0x3040 ... 0x30FF,
           0x31F0 ... 0x31FF,
           0x3400 ... 0x4DBF,
           0x4E00 ... 0x9FFF,
           0xAC00 ... 0xD7AF,
           0xF900 ... 0xFAFF,
           0x20000 ... 0x2FA1F:
        true
      default:
        false
      }
    }
  }
}

extension DependencyValues {
  var ocr: OCRClient {
    get { self[OCRClient.self] }
    set { self[OCRClient.self] = newValue }
  }
}

extension StringProtocol {
  /// Shared by both OCR pipelines.
  var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
