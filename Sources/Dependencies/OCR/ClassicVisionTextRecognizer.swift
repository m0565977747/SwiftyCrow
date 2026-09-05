// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

// MARK: - ClassicVisionTextRecognizer

/// Runs the ObjC-bridged `VNRecognizeTextRequest` (macOS 13+) off the calling
/// actor and hands its observations to a transform that runs on the same
/// background task.
///
/// `VNImageRequestHandler.perform` is synchronous and blocking, and the
/// observations it produces are `NSObject`s that are not `Sendable`. Both
/// concerns are contained here: the request executes inside a detached task and
/// only the transform's `Sendable` output crosses back to the caller. Vision
/// cannot abandon a request mid-flight, so cancellation is honored at the
/// boundaries — before the request starts and before its results are mapped.
enum ClassicVisionTextRecognizer {

  // MARK: Internal

  struct Configuration: Sendable {
    /// BCP-47 codes accepted by Vision (`supportedRecognitionLanguages()`).
    /// `nil` asks Vision to detect the language.
    var recognitionLanguages: [String]?
    var recognitionLevel = VNRequestTextRecognitionLevel.accurate
    var usesLanguageCorrection = true
    /// Revision 3 (macOS 13) is the first to read CJK and to detect the
    /// language on its own. Only applied when the running OS supports it.
    var revision: Int? = VNRecognizeTextRequestRevision3
  }

  static func recognize<Output: Sendable>(
    in image: CGImage,
    configuration: Configuration,
    transform: @escaping @Sendable ([VNRecognizedTextObservation]) throws -> Output
  ) async throws -> Output {
    let task = Task.detached(priority: .userInitiated) { () throws -> Output in
      try Task.checkCancellation()
      let request = Self.makeRequest(configuration)
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      try handler.perform([request])
      try Task.checkCancellation()
      return try transform(request.results ?? [])
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// Languages the current OS can recognize with the configured revision.
  static func supportedRecognitionLanguages(_ configuration: Configuration) -> [String] {
    let request = makeRequest(configuration)
    return (try? request.supportedRecognitionLanguages()) ?? []
  }

  // MARK: Private

  private static func makeRequest(_ configuration: Configuration) -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    if
      let revision = configuration.revision,
      VNRecognizeTextRequest.supportedRevisions.contains(revision)
    {
      request.revision = revision
    }
    request.recognitionLevel = configuration.recognitionLevel
    request.usesLanguageCorrection = configuration.usesLanguageCorrection
    if let languages = configuration.recognitionLanguages, !languages.isEmpty {
      request.recognitionLanguages = languages
    } else {
      request.automaticallyDetectsLanguage = true
    }
    return request
  }
}
