// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - GoogleCloudTranslationProvider

/// Google Cloud Translation (Basic / v2) over `URLSession`. This is the
/// backend on every macOS release before 26, and an opt-in on newer ones.
///
/// The API key travels in the `X-Goog-Api-Key` header — never in the URL —
/// so it can't leak into proxy or unified logs. `TranslationStrategy` is
/// ignored: v2 exposes a single NMT model, so `.lowLatency` and
/// `.highFidelity` translate identically here.
struct GoogleCloudTranslationProvider: TranslationProvider {

  // MARK: Lifecycle

  init(
    apiKey: String?,
    transport: @escaping Transport = GoogleCloudTranslationProvider.urlSessionTransport,
    languageCache: GoogleSupportedLanguageCache = .shared,
    retryDelay: Duration = .milliseconds(600)
  ) {
    self.apiKey = apiKey
    self.transport = transport
    self.languageCache = languageCache
    self.retryDelay = retryDelay
  }

  // MARK: Internal

  /// Performs one HTTP exchange. Injected so tests can run the provider
  /// without a network; the default is `URLSession.shared`.
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  static let endpoint = URL(string: "https://translation.googleapis.com/language/translate/v2")!

  /// v2 accepts at most 128 `q` segments per request.
  static let maximumSegmentsPerRequest = 128
  /// v2 rejects requests above ~30k code points; stay under it with margin.
  static let maximumCharactersPerRequest = 28000

  static let urlSessionTransport: Transport = { request in
    try await URLSession.shared.data(for: request)
  }

  /// Offered when no key is stored, so the target picker is never empty and
  /// Arabic and other common targets can be chosen before the key is entered.
  /// v2 supports all of these.
  static let staticLanguages: [Locale.Language] = [
    "ar", "en", "ko", "ja", "zh-Hans", "zh-Hant", "fr", "de", "es", "pt",
    "it", "ru", "tr", "hi", "id", "vi", "th",
  ].map { Locale.Language(identifier: $0) }

  let id = TranslationProviderID.google
  /// Style alignment stays an Apple Translation 26.4 feature for now; Google
  /// results are rendered with the plain translation only.
  let supportsStyledTranslation = false

  var apiKey: String?
  var transport: Transport
  var languageCache: GoogleSupportedLanguageCache
  var retryDelay: Duration

  /// Google's language tag for a `Locale.Language`. v2 takes ISO 639-1 codes
  /// with region-style Chinese variants; anything without a usable language
  /// code (nil, "und", the app's "auto" sentinel) returns nil, which callers
  /// omit so Google auto-detects the source.
  static func googleCode(for language: Locale.Language) -> String? {
    let maximal = Locale.Language(identifier: language.maximalIdentifier)
    guard
      let code = (language.languageCode ?? maximal.languageCode)?.identifier.lowercased(),
      !code.isEmpty,
      code != Language.autoCode,
      code != "und"
    else {
      return nil
    }
    switch code {
    case "zh":
      return maximal.script?.identifier == "Hant" ? "zh-TW" : "zh-CN"
    case "nb", "nn":
      return "no"
    case "fil":
      return "tl"
    default:
      return code
    }
  }

  /// Inverse of `googleCode(for:)` for the `/languages` listing, so Chinese
  /// variants come back as script tags the rest of the app compares on.
  static func localeLanguage(forGoogleCode code: String) -> Locale.Language {
    switch code.lowercased() {
    case "zh", "zh-cn": Locale.Language(identifier: "zh-Hans")
    case "zh-tw": Locale.Language(identifier: "zh-Hant")
    case "iw": Locale.Language(identifier: "he")
    case "jw": Locale.Language(identifier: "jv")
    case "no": Locale.Language(identifier: "nb")
    case "tl": Locale.Language(identifier: "fil")
    default: Locale.Language(identifier: code)
    }
  }

  static func localeLanguages(fromGoogleCodes codes: [String]) -> [Locale.Language] {
    var seen = Set<String>()
    var languages = [Locale.Language]()
    for code in codes {
      let language = localeLanguage(forGoogleCode: code)
      guard seen.insert(language.maximalIdentifier).inserted else { continue }
      languages.append(language)
    }
    return languages
  }

  /// Splits a batch into request-sized chunks (segment and character limits).
  static func chunk(_ requests: [TranslationRequest]) -> [[TranslationRequest]] {
    var chunks = [[TranslationRequest]]()
    var current = [TranslationRequest]()
    var currentCharacters = 0
    for request in requests {
      let length = request.sourceText.unicodeScalars.count
      let full = current.count >= maximumSegmentsPerRequest
        || currentCharacters + length > maximumCharactersPerRequest
      if !current.isEmpty, full {
        chunks.append(current)
        current = []
        currentCharacters = 0
      }
      current.append(request)
      currentCharacters += length
    }
    if !current.isEmpty {
      chunks.append(current)
    }
    return chunks
  }

  func translate(
    _ requests: [TranslationRequest],
    source: Locale.Language,
    target: Locale.Language,
    strategy _: TranslationStrategy
  ) -> AsyncThrowingStream<TranslationResponse, any Error> {
    AsyncThrowingStream { continuation in
      guard let apiKey = self.apiKey, !apiKey.isEmpty else {
        continuation.finish(throwing: TranslationProviderError.missingCredential)
        return
      }
      guard let targetCode = Self.googleCode(for: target) else {
        continuation.finish(throwing: TranslationProviderError.unsupportedLanguagePair)
        return
      }
      let sourceCode = Self.googleCode(for: source)
      let chunks = Self.chunk(requests)
      let task = Task {
        do {
          // Chunks run concurrently; each one's responses are yielded as soon
          // as that chunk lands, which is what keeps the stream unordered.
          try await withThrowingTaskGroup(of: [TranslationResponse].self) { group in
            for chunk in chunks {
              group.addTask {
                try await translateChunk(chunk, source: sourceCode, target: targetCode, apiKey: apiKey)
              }
            }
            for try await responses in group {
              for response in responses {
                continuation.yield(response)
              }
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      // Cancelling the task cancels the group, and `URLSession.data(for:)`
      // honours task cancellation, so in-flight requests are torn down too.
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func supportedLanguages() async throws -> [Locale.Language] {
    guard let apiKey = self.apiKey, !apiKey.isEmpty else { return Self.staticLanguages }
    if let cached = await languageCache.languages(forKey: apiKey) {
      return cached
    }
    do {
      var request = URLRequest(url: Self.endpoint.appending(path: "languages"))
      request.httpMethod = "GET"
      request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
      let data = try await send(request)
      let codes = try Self.decode(LanguagesBody.self, from: data).data.languages.map(\.language)
      return await languageCache.store(codes: codes, forKey: apiKey)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Offline start (or a bad key) shouldn't empty the language pickers:
      // fall back to the last listing this device saw, then the static set.
      Log.translation.error(
        "Supported-language listing failed: \(error.localizedDescription, privacy: .public)"
      )
      if let persisted = await languageCache.persistedLanguages() {
        return persisted
      }
      return Self.staticLanguages
    }
  }

  // MARK: Private

  private struct TranslateRequestBody: Encodable {
    var q: [String]
    var target: String
    var source: String?
    var format = "text"
  }

  private struct TranslateResponseBody: Decodable {
    struct Payload: Decodable {
      var translations: [Translation]
    }

    struct Translation: Decodable {
      var translatedText: String
    }

    var data: Payload
  }

  private struct LanguagesBody: Decodable {
    struct Payload: Decodable {
      var languages: [Entry]
    }

    struct Entry: Decodable {
      var language: String
    }

    var data: Payload
  }

  private struct ErrorBody: Decodable {
    struct Detail: Decodable {
      var code: Int?
      var message: String?
      var status: String?
    }

    var error: Detail
  }

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw TranslationProviderError.api(code: 0, message: "Unreadable response from the translation service.")
    }
  }

  private static func error(forStatus status: Int, body: Data) -> TranslationProviderError {
    let detail = try? JSONDecoder().decode(ErrorBody.self, from: body).error
    let message = detail?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
    if status == 429 {
      return .rateLimited
    }
    if status == 400, message.localizedCaseInsensitiveContains("language") {
      return .unsupportedLanguagePair
    }
    return .api(code: detail?.code ?? status, message: message)
  }

  private func translateChunk(
    _ chunk: [TranslationRequest],
    source: String?,
    target: String,
    apiKey: String
  ) async throws -> [TranslationResponse] {
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
    request.httpBody = try JSONEncoder().encode(
      TranslateRequestBody(q: chunk.map(\.sourceText), target: target, source: source)
    )
    let data = try await send(request)
    let translations = try Self.decode(TranslateResponseBody.self, from: data).data.translations
    // v2 answers in `q` order, which is the only way to pair results back up.
    guard translations.count == chunk.count else {
      throw TranslationProviderError.api(
        code: 0,
        message: "Expected \(chunk.count) translations but received \(translations.count)."
      )
    }
    return zip(chunk, translations).map { request, translation in
      TranslationResponse(clientIdentifier: request.clientIdentifier, targetText: translation.translatedText)
    }
  }

  /// One exchange with a single retry on 429/5xx. Task cancellation — which
  /// `URLSession` surfaces as `URLError.cancelled` — is rethrown as
  /// `CancellationError` so callers keep treating it as "nothing to report".
  private func send(_ request: URLRequest) async throws -> Data {
    var attempt = 0
    while true {
      attempt += 1
      let exchange: (Data, URLResponse)
      do {
        exchange = try await transport(request)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as URLError where error.code == .cancelled {
        throw CancellationError()
      } catch {
        if Task.isCancelled { throw CancellationError() }
        throw TranslationProviderError.network(error)
      }
      let (data, response) = exchange
      let status = (response as? HTTPURLResponse)?.statusCode ?? 200
      if (200..<300).contains(status) {
        return data
      }
      let retryable = status == 429 || (500..<600).contains(status)
      if retryable, attempt == 1 {
        Log.translation.debug("Google Translation answered \(status, privacy: .public); retrying once")
        try await Task.sleep(for: retryDelay)
        continue
      }
      throw Self.error(forStatus: status, body: data)
    }
  }
}

// MARK: - GoogleSupportedLanguageCache

/// Per-key memory of the `/languages` listing, with the last listing also
/// persisted so an offline launch still has real choices to offer.
actor GoogleSupportedLanguageCache {

  // MARK: Lifecycle

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  // MARK: Internal

  static let shared = GoogleSupportedLanguageCache()

  static let defaultsKey = "googleCloudTranslationLanguageCodes"

  func languages(forKey key: String) -> [Locale.Language]? {
    byKey[key]
  }

  @discardableResult
  func store(codes: [String], forKey key: String) -> [Locale.Language] {
    let languages = GoogleCloudTranslationProvider.localeLanguages(fromGoogleCodes: codes)
    byKey[key] = languages
    defaults.set(codes, forKey: Self.defaultsKey)
    return languages
  }

  func persistedLanguages() -> [Locale.Language]? {
    guard let codes = defaults.stringArray(forKey: Self.defaultsKey), !codes.isEmpty else { return nil }
    return GoogleCloudTranslationProvider.localeLanguages(fromGoogleCodes: codes)
  }

  // MARK: Private

  private let defaults: UserDefaults
  private var byKey = [String: [Locale.Language]]()
}
