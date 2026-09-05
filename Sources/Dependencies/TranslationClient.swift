// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import DependenciesMacros
import Foundation
import Sharing

// MARK: - TranslationLine

/// A line to translate (or its translated result), tagged with the overlay
/// line's id so batch responses can be matched back as they stream in.
struct TranslationLine: Equatable, Sendable {
  var id: UUID
  var text: String
  var attributedText: AttributedString? = nil
  /// Neighboring compact value used only to disambiguate this label. It is
  /// never rendered as part of the label's translated output.
  var trailingContext: String? = nil

  var requestText: String {
    guard let trailingContext else { return text }
    return "\(text): \(trailingContext)"
  }
}

// MARK: - TranslatedText

struct TranslatedText: Equatable, Sendable {
  var text: String
  var attributedText: AttributedString? = nil
}

// MARK: - TranslationTextStructure

enum TranslationTextStructure {

  // MARK: Internal

  /// Translation may promote one source line break into a paragraph break.
  /// Keep the target's wording, but cap consecutive newlines to the structure
  /// that OCR recovered from the source frame.
  static func matchingSourceBreaks(_ target: String, source: String) -> String {
    let sourceLimit = maximumConsecutiveNewlines(in: source)
    guard sourceLimit > 0 else { return target }

    let normalized = target
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var result = ""
    var consecutiveNewlines = 0
    for character in normalized {
      if character == "\n" {
        if consecutiveNewlines < sourceLimit {
          result.append(character)
        }
        consecutiveNewlines += 1
      } else {
        consecutiveNewlines = 0
        result.append(character)
      }
    }
    return result
  }

  /// Extracts the label from a contextual `label: value` translation. Apple
  /// Translation retains either the ASCII or full-width colon for supported
  /// language pairs; returning nil keeps a malformed response visible instead
  /// of silently guessing where the label ends.
  static func label(fromContextualTranslation target: String) -> String? {
    guard let separator = target.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
      return nil
    }
    let label = target[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
    return label.isEmpty ? nil : label
  }

  // MARK: Private

  private static func maximumConsecutiveNewlines(in text: String) -> Int {
    var maximum = 0
    var current = 0
    for character in text {
      if character == "\n" {
        current += 1
        maximum = max(maximum, current)
      } else if character != "\r" {
        current = 0
      }
    }
    return maximum
  }
}

// MARK: - TranslationProviderSelection

/// Picks the backend for the current settings and system. Apple Translation
/// needs macOS 26; anything else — or an explicit choice — is Google.
enum TranslationProviderSelection {
  static func resolvedID(preferred: TranslationProviderID) -> TranslationProviderID {
    if #available(macOS 26.0, *), preferred == .apple {
      return .apple
    }
    return .google
  }

  /// The provider to use right now, built from the shared settings and the
  /// stored credential. Cheap to call per batch; sessions are opened per call.
  static func current() -> any TranslationProvider {
    @Shared(.settings) var settings
    @Dependency(\.translationCredential) var translationCredential
    let id = resolvedID(preferred: settings.translation.provider)
    if #available(macOS 26.0, *), id == .apple {
      return AppleTranslationProvider()
    }
    return GoogleCloudTranslationProvider(apiKey: translationCredential.apiKey(.google))
  }
}

// MARK: - TranslationClient

@DependencyClient
struct TranslationClient {
  /// Translates all `lines` in one source-language session, yielding each result
  /// as soon as it's ready (order isn't guaranteed; match by `id`). Translation
  /// always comes from the plain batch response. Attributed source text is used
  /// only to map visual style spans onto that translated string.
  var translateBatch: @Sendable (
    _ lines: [TranslationLine],
    _ source: Locale.Language,
    _ target: Locale.Language,
    _ strategy: TranslationStrategy
  ) -> AsyncThrowingStream<TranslationLine, any Error> = { _, _, _, _ in
    AsyncThrowingStream { $0.finish() }
  }
}

// MARK: DependencyKey

extension TranslationClient: DependencyKey {

  // MARK: Internal

  static let liveValue = TranslationClient(
    translateBatch: { lines, source, target, strategy in
      AsyncThrowingStream { continuation in
        let provider = TranslationProviderSelection.current()
        let pair = "\(source.maximalIdentifier)->\(target.maximalIdentifier)"
        let linesByID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let requests = lines.map {
          TranslationRequest(sourceText: $0.requestText, clientIdentifier: $0.id.uuidString)
        }
        let task = Task {
          let clock = ContinuousClock()
          let started = clock.now
          var receivedFirstResponse = false
          do {
            var styledTargets = [UUID: String]()
            for try await response in provider.translate(requests, source: source, target: target, strategy: strategy) {
              if !receivedFirstResponse {
                receivedFirstResponse = true
                let elapsed = clock.now - started
                Log.translation.debug(
                  "First response for \(pair, privacy: .public) via \(provider.id.rawValue, privacy: .public) arrived in \(elapsed.loggedSeconds, privacy: .public)s"
                )
              }
              guard
                let id = UUID(uuidString: response.clientIdentifier),
                let sourceLine = linesByID[id]
              else { continue }
              let translatedLabel = sourceLine.trailingContext == nil
                ? response.targetText
                : TranslationTextStructure.label(fromContextualTranslation: response.targetText)
                  ?? response.targetText
              let targetText = TranslationTextStructure.matchingSourceBreaks(
                translatedLabel,
                source: sourceLine.text
              )
              if provider.supportsStyledTranslation, sourceLine.attributedText != nil {
                styledTargets[id] = targetText
                continue
              }
              continuation.yield(TranslationLine(
                id: id,
                text: targetText
              ))
            }
            if !styledTargets.isEmpty {
              try await Self.yieldStyledTranslations(
                styledTargets,
                linesByID: linesByID,
                provider: provider,
                source: source,
                target: target,
                strategy: strategy,
                continuation: continuation
              )
            }
            let elapsed = clock.now - started
            Log.translation.debug(
              "Batch of \(lines.count, privacy: .public) lines (\(pair, privacy: .public)) finished in \(elapsed.loggedSeconds, privacy: .public)s"
            )
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        // The translation service is launched on demand, and on the first use
        // after an idle period it can accept a batch and never answer. Nothing
        // else bounds this stream, so without a watchdog the caller's spinner
        // runs forever.
        let watchdog = Task {
          do {
            try await ContinuousClock().sleep(for: CaptureDeadline.translationBatch)
          } catch {
            return
          }
          Log.translation.error("Batch of \(lines.count, privacy: .public) lines (\(pair, privacy: .public)) stalled")
          continuation.finish(throwing: DeadlineExceededError(stage: .translation))
        }
        continuation.onTermination = { _ in
          watchdog.cancel()
          // Cancelling the task ends the provider's stream, whose own
          // termination handler stops the backend work (for Apple, the
          // session's daemon-side batch).
          task.cancel()
        }
      }
    }
  )

  // MARK: Private

  private static func yieldStyledTranslations(
    _ targets: [UUID: String],
    linesByID: [UUID: TranslationLine],
    provider: any TranslationProvider,
    source: Locale.Language,
    target: Locale.Language,
    strategy: TranslationStrategy,
    continuation: AsyncThrowingStream<TranslationLine, any Error>.Continuation
  ) async throws {
    var alternatives = [UUID: [URL: String]]()
    var snippetOwners = [UUID: (lineID: UUID, link: URL)]()
    var snippetRequests = [TranslationRequest]()

    for (lineID, targetText) in targets {
      guard let source = linesByID[lineID]?.attributedText else { continue }
      let alignment = TranslationStyleMapper.align(source: source, target: targetText)
      for span in alignment.unmatched {
        let requestID = UUID()
        snippetOwners[requestID] = (lineID, span.link)
        snippetRequests.append(TranslationRequest(
          sourceText: span.text,
          clientIdentifier: requestID.uuidString
        ))
      }
    }

    if !snippetRequests.isEmpty {
      for try await response in provider.translate(snippetRequests, source: source, target: target, strategy: strategy) {
        guard
          let requestID = UUID(uuidString: response.clientIdentifier),
          let owner = snippetOwners[requestID]
        else { continue }
        alternatives[owner.lineID, default: [:]][owner.link] = response.targetText
      }
    }

    for (lineID, targetText) in targets {
      guard
        let sourceLine = linesByID[lineID],
        let attributedSource = sourceLine.attributedText
      else { continue }
      let alignment = TranslationStyleMapper.align(
        source: attributedSource,
        target: targetText,
        alternatives: alternatives[lineID] ?? [:]
      )
      if !alignment.unmatched.isEmpty {
        Log.translation.debug(
          "Dropping \(alignment.unmatched.count, privacy: .public) unaligned style runs while preserving the plain translation"
        )
      }
      continuation.yield(TranslationLine(
        id: lineID,
        text: targetText,
        attributedText: alignment.target
      ))
    }
  }
}

extension DependencyValues {
  var translation: TranslationClient {
    get { self[TranslationClient.self] }
    set { self[TranslationClient.self] = newValue }
  }
}
