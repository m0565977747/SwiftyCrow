// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Translation

// MARK: - AppleTranslationProvider

/// On-device Apple Translation. `TranslationSession(installedSource:target:)`
/// — the only way to open a session outside a SwiftUI view — is macOS 26, so
/// the whole provider is gated on it; older systems use
/// `GoogleCloudTranslationProvider`.
@available(macOS 26.0, *)
struct AppleTranslationProvider: TranslationProvider {

  // MARK: Internal

  let id = TranslationProviderID.apple

  /// Style alignment needs the link-metadata-aware translation of 26.4.
  var supportsStyledTranslation: Bool {
    if #available(macOS 26.4, *) {
      return true
    }
    return false
  }

  func translate(
    _ requests: [TranslationRequest],
    source: Locale.Language,
    target: Locale.Language,
    strategy: TranslationStrategy
  ) -> AsyncThrowingStream<TranslationResponse, any Error> {
    AsyncThrowingStream { continuation in
      let session =
        if #available(macOS 26.4, *) {
          TranslationSession(installedSource: source, target: target, preferredStrategy: strategy.sessionStrategy)
        } else {
          TranslationSession(installedSource: source, target: target)
        }
      let sessionRequests = requests.map {
        TranslationSession.Request(sourceText: $0.sourceText, clientIdentifier: $0.clientIdentifier)
      }
      let task = Task {
        do {
          for try await response in session.translate(batch: sessionRequests) {
            guard let clientIdentifier = response.clientIdentifier else { continue }
            continuation.yield(TranslationResponse(
              clientIdentifier: clientIdentifier,
              targetText: response.targetText
            ))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        // `task.cancel()` alone doesn't stop work already handed to the
        // translation daemon — `cancel()` is the documented way to stop a
        // session's ongoing work. Without it, every live tick whose batch
        // outruns the capture interval abandons a session that keeps working
        // daemon-side, and they accumulate for the life of the process.
        session.cancel()
        task.cancel()
      }
    }
  }

  func supportedLanguages() async throws -> [Locale.Language] {
    await LanguageAvailability().supportedLanguages
  }
}

@available(macOS 26.4, *)
extension TranslationStrategy {
  var sessionStrategy: TranslationSession.Strategy {
    switch self {
    case .lowLatency: .lowLatency
    case .highFidelity: .highFidelity
    }
  }
}
