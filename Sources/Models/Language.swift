// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Vision

// MARK: - Language

struct Language: Codable, Equatable, Hashable, Identifiable, Sendable {
  let code: String

  var id: String {
    code
  }

  var displayName: String {
    if isAuto { return "Auto (detect)" }
    return Locale.current.localizedString(forIdentifier: code) ?? code
  }

  /// Whether this is the "detect the source language automatically" sentinel.
  var isAuto: Bool {
    code == Language.autoCode
  }

  var localeLanguage: Locale.Language {
    Locale.Language(identifier: code)
  }
}

extension Locale.Language {
  /// Region variants share the same written language, while script variants
  /// such as Simplified and Traditional Chinese do not. Maximizing both tags
  /// lets Foundation fill in omitted scripts before we compare them.
  func usesSameWritingSystem(as other: Locale.Language) -> Bool {
    let lhs = Locale.Language(identifier: maximalIdentifier)
    let rhs = Locale.Language(identifier: other.maximalIdentifier)
    return lhs.languageCode == rhs.languageCode && lhs.script == rhs.script
  }
}

extension Language {
  /// Reserved code for the auto-detect source sentinel.
  static let autoCode = "auto"

  /// "Detect the source language automatically" — OCR detects the recognition
  /// language and the text's dominant language drives translation.
  static let auto = Language(code: autoCode)

  /// Default source language for new installs (most screen text users
  /// translate is English).
  static let defaultSource = Language(code: "en-US")

  /// Default for new installs. Picks the user's most-preferred system
  /// language; falls back to whatever Translation reports first if Locale
  /// somehow returns nothing useful.
  static func systemPreferred() -> Language {
    let preferred = Locale.preferredLanguages.first
      ?? Locale.current.language.maximalIdentifier
    return Language(code: preferred)
  }

  /// Languages the current translation provider (Apple Translation on macOS
  /// 26, Google Cloud Translation otherwise) reports as supported. When
  /// `intersectedWithOCR` is true, narrows the list to ones Vision can also
  /// OCR — appropriate for source pickers.
  static func systemSupported(intersectedWithOCR: Bool) async -> [Language] {
    let provider = TranslationProviderSelection.current()
    let translationLangs = (try? await provider.supportedLanguages()) ?? []
    return supported(
      translation: translationLangs,
      ocr: intersectedWithOCR ? ocrRecognitionLanguages() : nil
    )
  }

  /// Pure part of `systemSupported`, kept separate so it can be tested
  /// without a provider. `ocr == nil` skips the intersection.
  static func supported(translation: [Locale.Language], ocr: [Locale.Language]?) -> [Language] {
    var ids = Set(translation.map(\.maximalIdentifier))
    if let ocr {
      ids.formIntersection(ocr.map(\.maximalIdentifier))
    }
    return ids
      .filter { !$0.isEmpty }
      .map { Language(code: $0) }
      .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
  }

  /// Languages Vision can recognize with the accurate level. The class-based
  /// `VNRecognizeTextRequest` query exists on every supported macOS release,
  /// unlike the Swift-only `RecognizeTextRequest` (macOS 15).
  static func ocrRecognitionLanguages() -> [Locale.Language] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    let identifiers = (try? request.supportedRecognitionLanguages()) ?? []
    return identifiers.map { Locale.Language(identifier: $0) }
  }
}
