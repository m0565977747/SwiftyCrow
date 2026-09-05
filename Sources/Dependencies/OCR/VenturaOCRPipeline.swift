// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

// MARK: - VenturaOCRPipeline

/// Recognition path for macOS 13–15, built on the classic `VNRecognizeTextRequest`
/// (revision 3, the first with CJK support and on-device language detection).
///
/// What degrades compared with `ModernOCRPipeline` on macOS 26:
/// - There is no `RecognizeDocumentsRequest`, so Apple's document layout —
///   paragraph membership, `textAlignment`, and `textDirection` — is not
///   available. `VenturaOCRLayout` infers paragraph groups and alignment from
///   row geometry, and vertical CJK columns from box aspect and script.
/// - Vision reports flat rows only; every row starts with `rowCount == 1` and
///   `coalescingParagraphFragments` stitches wrapped rows downstream.
/// - No separate supplemental recall pass: the classic request already is the
///   high-recall text recognizer that pass used, so running it twice buys
///   nothing.
///
/// Everything after recognition — Japanese ruby correction, nested-duplicate
/// removal, appearance sampling, and paragraph coalescing — is the same tail
/// the modern pipeline runs.
enum VenturaOCRPipeline {

  // MARK: Internal

  static func recognizeText(in image: CGImage, language: Language) async throws -> OCRResult {
    // A capture that starts while the proactive probe is loading the model
    // joins that work instead of issuing a second cold Vision request.
    await VisionWarmUp.shared.waitForInFlight()
    let configuration = Self.configuration(for: language)
    let clock = ContinuousClock()
    let started = clock.now
    let recognized = try await ClassicVisionTextRecognizer.recognize(
      in: image,
      configuration: configuration
    ) { observations in
      observations.compactMap(Self.recognizedLine(from:))
    }
    // Always timed: a cold model load and a genuine stall look identical from
    // the UI, and the duration is the only thing that separates them.
    let elapsed = clock.now - started
    if elapsed > .seconds(2) {
      Log.ocr.error("Recognition took \(elapsed.loggedSeconds, privacy: .public)s — model was cold")
    } else {
      Log.ocr.debug("Recognition took \(elapsed.loggedSeconds, privacy: .public)s")
    }

    let postProcessingStarted = clock.now
    let lines = VenturaOCRLayout.grouping(for: recognized)
    let correctedLines: [OCRResult.Line]
    let languageCode = language.localeLanguage.languageCode?.identifier
    if language.isAuto || languageCode == "ja" {
      do {
        correctedLines = try await JapaneseRubyOCRCorrector.correcting(lines, in: image)
      } catch {
        Log.ocr.error(
          "Base-glyph OCR failed: \(error.localizedDescription, privacy: .public)"
        )
        correctedLines = lines
      }
    } else {
      correctedLines = lines
    }
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: correctedLines).removingNestedDuplicates(),
      from: image
    ).coalescingParagraphFragments()
    let postProcessingElapsed = clock.now - postProcessingStarted
    Log.ocr.debug(
      "Post-processing produced \(result.lines.count, privacy: .public) lines in \(postProcessingElapsed.loggedSeconds, privacy: .public)s"
    )
    return result
  }

  static func warmUp() async {
    await VisionWarmUp.shared.run { probe in
      _ = try await ClassicVisionTextRecognizer.recognize(
        in: probe,
        configuration: ClassicVisionTextRecognizer.Configuration(recognitionLanguages: nil)
      ) { observations in
        observations.count
      }
    }
  }

  // MARK: Private

  /// Vision only accepts codes from `supportedRecognitionLanguages()`, and
  /// `Language.code` may be a maximal tag ("en-Latn-US") or a bare one ("ar").
  /// Prefer an exact match, then the same language and script (so Simplified
  /// and Traditional Chinese stay distinct), then the same language; otherwise
  /// let Vision detect the language rather than fail the request.
  private static func configuration(for language: Language) -> ClassicVisionTextRecognizer.Configuration {
    var configuration = ClassicVisionTextRecognizer.Configuration(recognitionLanguages: nil)
    guard !language.isAuto else { return configuration }
    let supported = ClassicVisionTextRecognizer.supportedRecognitionLanguages(configuration)
    if let code = recognitionLanguage(matching: language.code, in: supported) {
      configuration.recognitionLanguages = [code]
    } else {
      Log.ocr.log(
        "Vision cannot recognize \(language.code, privacy: .public); detecting the language instead"
      )
    }
    return configuration
  }

  private static func recognitionLanguage(matching code: String, in supported: [String]) -> String? {
    if supported.contains(code) { return code }
    let wanted = Locale.Language(identifier: Locale.Language(identifier: code).maximalIdentifier)
    guard let wantedCode = wanted.languageCode else { return nil }
    let candidates = supported.map { identifier in
      (identifier, Locale.Language(identifier: Locale.Language(identifier: identifier).maximalIdentifier))
    }
    if
      let sameScript = candidates.first(where: {
        $0.1.languageCode == wantedCode && $0.1.script == wanted.script
      })
    {
      return sameScript.0
    }
    return candidates.first { $0.1.languageCode == wantedCode }?.0
  }

  /// Maps one classic observation onto the shared line model. Runs on the
  /// recognizer's background task, so the non-`Sendable` observation never
  /// leaves it.
  private static func recognizedLine(from observation: VNRecognizedTextObservation) -> OCRResult.Line? {
    guard
      let candidate = observation.topCandidates(1).first,
      candidate.confidence >= 0.25
    else { return nil }
    let text = candidate.string.trimmed
    guard !text.isEmpty else { return nil }
    let box = OCRClient.topLeftBox(observation.boundingBox)
    let words = geometricWords(in: candidate)
    let wordBoxes = words.map(\.box)
    let isVertical = VenturaOCRLayout.isLikelyVerticalCJK(text: text, box: box)
    return OCRResult.Line(
      boundingBoxNormalized: box,
      text: text,
      rowCount: 1,
      isVerticalBlock: isVertical,
      verticalCharScale: isVertical ? box.width : 0,
      horizontalGlyphScale: isVertical ? 0 : OCRClient.median(wordBoxes.map(\.height)) ?? box.height,
      replacementPatches: (wordBoxes.isEmpty ? [box] : wordBoxes).map {
        OverlaySourcePatch(box: $0)
      },
      styleRuns: OCRClient.styleRuns(in: text, words: words)
    )
  }

  private static func geometricWords(in candidate: VNRecognizedText) -> [OCRClient.RecognizedWord] {
    // `VNRecognizedText.string` bridges a fresh `String` on every access; index
    // one copy so the tokenized ranges stay valid for the substring and
    // `boundingBox(for:)` alike.
    let string = candidate.string
    return OCRTextTokenization.ranges(in: string).compactMap { range in
      guard let observation = try? candidate.boundingBox(for: range) else { return nil }
      return OCRClient.RecognizedWord(
        text: String(string[range]),
        box: OCRClient.topLeftBox(observation.boundingBox)
      )
    }
  }
}
