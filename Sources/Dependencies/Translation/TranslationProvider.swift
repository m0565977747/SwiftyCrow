// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - TranslationRequest

/// One unit of text handed to a provider. `clientIdentifier` is echoed back
/// on the matching response so unordered results can be matched up.
struct TranslationRequest: Equatable, Hashable, Sendable {
  var sourceText: String
  var clientIdentifier: String
}

// MARK: - TranslationResponse

struct TranslationResponse: Equatable, Hashable, Sendable {
  var clientIdentifier: String
  var targetText: String
}

// MARK: - TranslationProvider

/// A translation backend. `TranslationClient` owns everything that is shared
/// between backends (id matching, label extraction, newline capping, the
/// stall watchdog); a provider only turns request text into target text.
protocol TranslationProvider: Sendable {
  var id: TranslationProviderID { get }

  /// Whether the client may run its second, style-alignment pass (per-span
  /// snippet translations) against this provider.
  var supportsStyledTranslation: Bool { get }

  /// Translates `requests` from `source` to `target`, yielding each result as
  /// soon as it is ready. Order is not guaranteed — match by
  /// `clientIdentifier`. The stream must stop its backend work when it is
  /// terminated (cancelled or dropped) by the consumer.
  func translate(
    _ requests: [TranslationRequest],
    source: Locale.Language,
    target: Locale.Language,
    strategy: TranslationStrategy
  ) -> AsyncThrowingStream<TranslationResponse, any Error>

  /// Languages this backend can translate to/from right now.
  func supportedLanguages() async throws -> [Locale.Language]
}

// MARK: - TranslationProviderError

enum TranslationProviderError: Error, LocalizedError, Sendable {
  /// The backend needs a credential (API key) and none is stored.
  case missingCredential
  /// The request never got a usable answer from the network.
  case network(any Error)
  /// The backend answered with an error payload.
  case api(code: Int, message: String)
  /// The backend refused the request for quota reasons, even after a retry.
  case rateLimited
  /// The backend cannot translate between the requested languages.
  case unsupportedLanguagePair

  // Messages stay provider-neutral: the same cases are thrown by every
  // backend, and the UI names the selected provider where that matters.
  var errorDescription: String? {
    switch self {
    case .missingCredential:
      "Google Cloud Translation API key is missing. Add one under Settings → Translation."
    case .network(let underlying):
      "Couldn't reach the translation service: \(underlying.localizedDescription)"
    case .api(let code, let message):
      "Translation service error \(code): \(message)"
    case .rateLimited:
      "The translation service is rate-limiting requests. Try again in a moment."
    case .unsupportedLanguagePair:
      "The translation service doesn't support this language pair."
    }
  }
}
