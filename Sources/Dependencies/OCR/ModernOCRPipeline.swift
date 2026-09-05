// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

// MARK: - ModernOCRPipeline

/// The macOS 26 recognition path: `RecognizeDocumentsRequest` supplies page
/// structure (paragraphs, alignment, text direction) and a `RecognizeTextRequest`
/// recall pass fills in rows the document model omitted.
///
/// Behavior is unchanged from the pre-backport `OCRClient.liveValue`; the body
/// only moved so the Ventura pipeline can sit beside it. Shared post-processing
/// helpers live on `OCRClient` in `OCRClient.swift`.
@available(macOS 26.0, *)
enum ModernOCRPipeline {

  // MARK: Internal

  static func recognizeText(in image: CGImage, language: Language) async throws -> OCRResult {
    // A capture that starts while the proactive probe is loading the model
    // joins that work instead of issuing a second cold Vision request.
    await VisionWarmUp.shared.waitForInFlight()
    var request = RecognizeDocumentsRequest()
    if language.isAuto {
      request.textRecognitionOptions.automaticallyDetectLanguage = true
    } else {
      request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: language.code)]
    }
    let clock = ContinuousClock()
    let started = clock.now
    let observations = try await request.perform(on: image)
    // Always timed: a cold model load and a genuine stall look identical from
    // the UI, and the duration is the only thing that separates them.
    let elapsed = clock.now - started
    if elapsed > .seconds(2) {
      Log.ocr.error("Recognition took \(elapsed.loggedSeconds, privacy: .public)s — model was cold")
    } else {
      Log.ocr.debug("Recognition took \(elapsed.loggedSeconds, privacy: .public)s")
    }

    // Vision's paragraph grouping is semantic, not typographic. A large title
    // and a smaller subtitle can therefore arrive as one paragraph even
    // though they need different font scale, color, and translation frames.
    // Start from Vision's line geometry and conservatively stitch only lines
    // with matching scale/alignment below.
    let postProcessingStarted = clock.now
    let paragraphs = observations.flatMap(\.document.paragraphs)
    var nextRecognitionGroupID = 0
    var lines = paragraphs.flatMap { paragraph in
      let alignment = paragraph.textAlignment?.overlayTextAlignment
      let paragraphWords = paragraph.words?.compactMap { observation -> OCRClient.RecognizedWord? in
        guard let text = observation.topCandidates(1).first?.string.trimmed, !text.isEmpty else {
          return nil
        }
        return OCRClient.RecognizedWord(
          text: text,
          box: OCRClient.topLeftBox(observation.boundingRegion.boundingBox.cgRect)
        )
      } ?? []
      let recognizedLines = paragraph.lines.compactMap { observation -> (
        observation: RecognizedTextObservation,
        candidate: RecognizedText,
        transcript: String
      )? in
        guard
          let candidate = observation.topCandidates(1).first,
          !candidate.string.trimmed.isEmpty
        else {
          return nil
        }
        return (
          observation: observation,
          candidate: candidate,
          transcript: candidate.string.trimmed
        )
      }
      let segmentIndices = OCRParagraphLineGrouping.segmentIndices(
        paragraphTranscript: paragraph.transcript,
        lineTranscripts: recognizedLines.map(\.transcript)
      )
      let groupBase = nextRecognitionGroupID
      nextRecognitionGroupID += max(1, (segmentIndices.max() ?? 0) + 1)
      let mapped = recognizedLines.enumerated().map { lineIndex, recognizedLine -> OCRResult.Line in
        let observation = recognizedLine.observation
        let transcript = recognizedLine.transcript
        let box = OCRClient.topLeftBox(observation.boundingRegion.boundingBox.cgRect)
        let isVertical = observation.textDirection == .topToBottom
        let documentWords = paragraphWords.filter { word in
          let intersection = box.intersection(word.box)
          return !intersection.isNull
            && intersection.width * intersection.height
            / max(0.000_001, word.box.width * word.box.height) >= 0.72
        }
        // Document paragraphs do not always expose `words` (notably dense
        // Japanese educational pages). The line candidate still provides
        // Apple's exact range geometry, so use it to retain punctuation,
        // mixed colors, and inline styles instead of flattening the line.
        let geometricWords = Self.geometricWords(in: recognizedLine.candidate)
        let words = geometricWords.isEmpty ? documentWords : geometricWords
        let wordBoxes = words.map(\.box)
        let patches = (wordBoxes.isEmpty ? [box] : wordBoxes).map {
          OverlaySourcePatch(box: $0)
        }
        let horizontalGlyphScale = isVertical
          ? 0
          : OCRClient.median(wordBoxes.map(\.height)) ?? box.height
        return OCRResult.Line(
          boundingBoxNormalized: box,
          text: transcript,
          isVerticalBlock: isVertical,
          verticalCharScale: isVertical ? box.width : 0,
          horizontalGlyphScale: horizontalGlyphScale,
          recognitionGroupID: groupBase + segmentIndices[lineIndex],
          replacementPatches: patches,
          styleRuns: OCRClient.styleRuns(in: transcript, words: words),
          alignment: alignment
        )
      }
      guard mapped.isEmpty else { return mapped }

      let transcript = paragraph.transcript.trimmed
      guard !transcript.isEmpty else { return [] }
      let box = OCRClient.topLeftBox(paragraph.boundingRegion.boundingBox.cgRect)
      return [
        OCRResult.Line(
          boundingBoxNormalized: box,
          text: transcript,
          rowCount: 1,
          recognitionGroupID: groupBase,
          replacementPatches: [OverlaySourcePatch(box: box)],
          alignment: alignment
        )
      ]
    }
    if OCRClient.shouldRunSupplementalRecognition(for: lines, language: language) {
      do {
        let supplementalStarted = clock.now
        let supplemental = try await Self.supplementalLines(in: image, language: language)
        let previousCount = lines.count
        lines = OCRSupplementalMerger.addingUncovered(supplemental, to: lines)
        Log.ocr.debug(
          "Supplemental recognition added \(lines.count - previousCount, privacy: .public) lines in \((clock.now - supplementalStarted).loggedSeconds, privacy: .public)s"
        )
      } catch {
        // Document recognition remains a complete result on its own. Surface
        // the supplemental failure, but do not turn a successful capture into
        // an error merely because the recall pass was unavailable.
        Log.ocr.error(
          "Supplemental recognition failed: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
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
      var request = RecognizeDocumentsRequest()
      request.textRecognitionOptions.automaticallyDetectLanguage = true
      _ = try await request.perform(on: probe)
      var supplemental = RecognizeTextRequest()
      supplemental.recognitionLevel = .accurate
      supplemental.automaticallyDetectsLanguage = true
      _ = try await supplemental.perform(on: probe)
    }
  }

  // MARK: Private

  private static func geometricWords(in candidate: RecognizedText) -> [OCRClient.RecognizedWord] {
    OCRTextTokenization.ranges(in: candidate.string).compactMap { range in
      guard let observation = candidate.boundingBox(for: range) else { return nil }
      return OCRClient.RecognizedWord(
        text: String(candidate.string[range]),
        box: OCRClient.topLeftBox(observation.boundingBox.cgRect)
      )
    }
  }

  private static func supplementalLines(
    in image: CGImage,
    language: Language
  ) async throws -> [OCRResult.Line] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if language.isAuto {
      request.automaticallyDetectsLanguage = true
    } else {
      request.recognitionLanguages = [language.localeLanguage]
    }
    return try await request.perform(on: image).compactMap { observation in
      guard
        let candidate = observation.topCandidates(1).first,
        candidate.confidence >= 0.25,
        !candidate.string.trimmed.isEmpty
      else { return nil }
      let text = candidate.string.trimmed
      let box = OCRClient.topLeftBox(observation.boundingRegion.boundingBox.cgRect)
      let words = geometricWords(in: candidate)
      let wordBoxes = words.map(\.box)
      return OCRResult.Line(
        boundingBoxNormalized: box,
        text: text,
        horizontalGlyphScale: OCRClient.median(wordBoxes.map(\.height)) ?? box.height,
        replacementPatches: (wordBoxes.isEmpty ? [box] : wordBoxes).map {
          OverlaySourcePatch(box: $0)
        },
        styleRuns: OCRClient.styleRuns(in: text, words: words),
        alignment: OCRClient.inferredSupplementalAlignment(for: box)
      )
    }
  }
}

@available(macOS 26.0, *)
extension DocumentObservation.Container.Text.Alignment {
  fileprivate var overlayTextAlignment: OverlayTextAlignment {
    switch self {
    case .center: .center
    case .leading: .leading
    case .trailing: .trailing
    @unknown default: .center
    }
  }
}
