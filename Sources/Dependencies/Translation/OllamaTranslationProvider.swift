// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - OllamaTranslationProvider

/// Translation by a local LLM served by Ollama (`POST /api/chat`, non-streamed).
/// Fully offline once a model is pulled, no account or key. Quality and speed
/// depend on the model and the machine; the default `gemma3:4b` is a fair
/// trade-off on Apple silicon, small enough for 8 GB of memory.
///
/// Each `TranslationRequest` is one chat completion with a fixed system prompt
/// and the source text as the user turn; two run at a time so a local CPU/GPU
/// isn't swamped. `TranslationStrategy` is ignored.
struct OllamaTranslationProvider: TranslationProvider {

  // MARK: Lifecycle

  init(
    endpoint: String = OllamaTranslationProvider.defaultEndpoint,
    model: String = OllamaTranslationProvider.defaultModel,
    transport: @escaping Transport = GoogleCloudTranslationProvider.urlSessionTransport,
    maximumConcurrentRequests: Int = 2,
    timeout: TimeInterval = 60
  ) {
    self.endpoint = endpoint
    self.model = model
    self.transport = transport
    self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    self.timeout = timeout
  }

  // MARK: Internal

  typealias Transport = GoogleCloudTranslationProvider.Transport

  static let defaultEndpoint = "http://127.0.0.1:11434"
  static let defaultModel = "gemma3:4b"

  let id = TranslationProviderID.ollama
  let supportsStyledTranslation = false

  var endpoint: String
  var model: String
  var transport: Transport
  var maximumConcurrentRequests: Int
  var timeout: TimeInterval

  /// `<endpoint>/api/chat`, tolerating whitespace and a trailing slash. An
  /// unparseable endpoint falls back to the default so the user gets a
  /// connection error naming it rather than a silent no-op.
  static func chatURL(endpoint: String) -> URL {
    var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    if base.isEmpty {
      base = defaultEndpoint
    }
    return URL(string: "\(base)/api/chat") ?? URL(string: "\(defaultEndpoint)/api/chat")!
  }

  /// English name of a language for the prompt ("Arabic", "Chinese
  /// (Simplified)"). English names keep the instruction unambiguous whatever
  /// the user's locale; the current locale is a fallback, then the bare code.
  /// Nil for the auto-detect sentinel and undetermined tags.
  static func languageName(for language: Locale.Language) -> String? {
    guard let code = GoogleCloudTranslationProvider.googleCode(for: language) else { return nil }
    // Script tags name the Chinese variants ("Chinese (Simplified)"); every
    // other Google code is a plain ISO 639-1 tag.
    let identifier: String =
      switch code {
      case "zh-CN": "zh-Hans"
      case "zh-TW": "zh-Hant"
      default: code
      }
    let english = Locale(identifier: "en_US")
    if let name = english.localizedString(forIdentifier: identifier), !name.isEmpty, name != identifier {
      return name
    }
    if let name = Locale.current.localizedString(forLanguageCode: code) {
      return name
    }
    return code
  }

  static func systemPrompt(source: String?, target: String) -> String {
    "You are a translation engine. Translate the user's text from \(source ?? "the detected language") to \(target). "
      + "Output ONLY the translation, no quotes, no explanations, preserve line breaks."
  }

  static func requestBody(model: String, text: String, source: String?, target: String) throws -> Data {
    let body = ChatRequestBody(
      model: model,
      messages: [
        ChatMessage(role: "system", content: systemPrompt(source: source, target: target)),
        ChatMessage(role: "user", content: text),
      ]
    )
    return try JSONEncoder().encode(body)
  }

  /// `message.content` of a non-streamed `/api/chat` reply, trimmed of
  /// surrounding whitespace and of one pair of wrapping quotation marks —
  /// small models like to quote their answer despite the instruction.
  static func parseReply(from data: Data) throws -> String {
    let reply: ChatResponseBody
    do {
      reply = try JSONDecoder().decode(ChatResponseBody.self, from: data)
    } catch {
      throw TranslationProviderError.api(code: 0, message: "Unreadable response from Ollama.")
    }
    if let message = reply.error {
      throw TranslationProviderError.api(code: 0, message: message)
    }
    return stripQuotes(reply.message?.content ?? "")
  }

  static func stripQuotes(_ text: String) -> String {
    var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
    while
      trimmed.count >= 2,
      let first = trimmed.first,
      let last = trimmed.last,
      quotationMarks.contains(first),
      quotationMarks.contains(last)
    {
      trimmed = trimmed.dropFirst().dropLast()
      trimmed = Substring(trimmed.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return String(trimmed)
  }

  func translate(
    _ requests: [TranslationRequest],
    source: Locale.Language,
    target: Locale.Language,
    strategy _: TranslationStrategy
  ) -> AsyncThrowingStream<TranslationResponse, any Error> {
    AsyncThrowingStream { continuation in
      guard let targetName = Self.languageName(for: target) else {
        continuation.finish(throwing: TranslationProviderError.unsupportedLanguagePair)
        return
      }
      let sourceName = Self.languageName(for: source)
      let limit = maximumConcurrentRequests
      let task = Task {
        do {
          try await withThrowingTaskGroup(of: TranslationResponse.self) { group in
            var pending = requests[...]
            for _ in 0..<min(limit, pending.count) {
              let request = pending.removeFirst()
              group.addTask {
                try await translateOne(request, source: sourceName, target: targetName)
              }
            }
            for try await response in group {
              continuation.yield(response)
              if !pending.isEmpty {
                let request = pending.removeFirst()
                group.addTask {
                  try await translateOne(request, source: sourceName, target: targetName)
                }
              }
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// A general LLM handles every language in the static list, so it is
  /// offered as-is; there is nothing to query.
  func supportedLanguages() async throws -> [Locale.Language] {
    GoogleCloudTranslationProvider.staticLanguages
  }

  // MARK: Private

  private struct ChatRequestBody: Encodable {
    struct Options: Encodable {
      var temperature = 0.0
    }

    var model: String
    var messages: [ChatMessage]
    var stream = false
    var options = Options()
  }

  private struct ChatMessage: Codable {
    var role: String
    var content: String
  }

  private struct ChatResponseBody: Decodable {
    var message: ChatMessage?
    var error: String?
  }

  private static let quotationMarks: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}", "\u{300C}", "\u{300D}"]

  private func translateOne(
    _ request: TranslationRequest,
    source: String?,
    target: String
  ) async throws -> TranslationResponse {
    var urlRequest = URLRequest(url: Self.chatURL(endpoint: endpoint))
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = timeout
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try Self.requestBody(
      model: model,
      text: request.sourceText,
      source: source,
      target: target
    )
    let data = try await send(urlRequest)
    let text = try Self.parseReply(from: data)
    return TranslationResponse(clientIdentifier: request.clientIdentifier, targetText: text)
  }

  /// Non-2xx bodies are `{"error": "..."}`; a missing model is the common one.
  private func apiError(forStatus status: Int, body: Data) -> TranslationProviderError {
    let detail = (try? JSONDecoder().decode(ChatResponseBody.self, from: body))?.error
    var message = detail ?? HTTPURLResponse.localizedString(forStatusCode: status)
    if status == 404, message.localizedCaseInsensitiveContains("not found") {
      message += " Pull it with `ollama pull \(model)`."
    }
    return .api(code: status, message: message)
  }

  /// One exchange, no retry: a local server that fails is not going to
  /// recover in the next 600 ms, and the batch is retried on the next tick.
  private func send(_ request: URLRequest) async throws -> Data {
    let exchange: (Data, URLResponse)
    do {
      exchange = try await transport(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError where Self.isUnreachable(error) {
      if Task.isCancelled { throw CancellationError() }
      throw TranslationProviderError.network(OllamaUnreachableError(endpoint: endpoint))
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw TranslationProviderError.network(error)
    }
    let (data, response) = exchange
    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
    if (200..<300).contains(status) {
      return data
    }
    throw apiError(forStatus: status, body: data)
  }

  private static func isUnreachable(_ error: URLError) -> Bool {
    switch error.code {
    case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
      true
    default:
      false
    }
  }
}

// MARK: - OllamaUnreachableError

/// Connection refused at the configured endpoint, worded for the fix.
struct OllamaUnreachableError: Error, LocalizedError, Equatable, Sendable {
  var endpoint: String

  var errorDescription: String? {
    "Ollama isn't running at \(endpoint). Start it with `ollama serve`."
  }
}
