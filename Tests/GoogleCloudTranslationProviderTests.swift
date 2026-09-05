// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

// MARK: - TransportRecorder

/// Captures every request the provider sends and answers it with a canned
/// response: either the next one from a queue (the last entry repeats once
/// the queue runs dry) or one computed from the request.
private actor TransportRecorder {

  // MARK: Lifecycle

  init(responses: [(status: Int, body: String)]) {
    handler = nil
    self.responses = responses
  }

  init(handler: @escaping @Sendable (URLRequest) -> (status: Int, body: String)) {
    self.handler = handler
    responses = []
  }

  // MARK: Internal

  private(set) var requests = [URLRequest]()

  nonisolated var transport: GoogleCloudTranslationProvider.Transport {
    { request in await self.record(request) }
  }

  func record(_ request: URLRequest) -> (Data, URLResponse) {
    requests.append(request)
    let canned: (status: Int, body: String)
    if let handler {
      canned = handler(request)
    } else {
      canned = responses.count > 1 ? responses.removeFirst() : responses[0]
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: canned.status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    return (Data(canned.body.utf8), response)
  }

  // MARK: Private

  private let handler: (@Sendable (URLRequest) -> (status: Int, body: String))?
  private var responses: [(status: Int, body: String)]

}

// MARK: - GoogleCloudTranslationProviderTests

@Suite("Google Cloud Translation provider")
struct GoogleCloudTranslationProviderTests {

  // MARK: Internal

  @Test
  func encodesTranslateRequestWithHeaderKeyAndJSONBody() async throws {
    let recorder = TransportRecorder(responses: [(200, Self.translations(["مرحبا", "عالم"]))])
    let provider = makeProvider(apiKey: "test-key", recorder: recorder)
    let requests = [
      TranslationRequest(sourceText: "Hello", clientIdentifier: "a"),
      TranslationRequest(sourceText: "World", clientIdentifier: "b"),
    ]

    let responses = try await collect(provider.translate(
      requests,
      source: Locale.Language(identifier: "en-US"),
      target: Locale.Language(identifier: "ar-Arab-EG"),
      strategy: .lowLatency
    ))

    let sent = await recorder.requests
    let request = try #require(sent.first)
    #expect(sent.count == 1)
    #expect(request.httpMethod == "POST")
    #expect(request.url == GoogleCloudTranslationProvider.endpoint)
    #expect(request.value(forHTTPHeaderField: "X-Goog-Api-Key") == "test-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.url?.absoluteString.contains("key=") == false)

    let body = try Self.jsonBody(of: request)
    #expect(body["q"] as? [String] == ["Hello", "World"])
    #expect(body["target"] as? String == "ar")
    #expect(body["source"] as? String == "en")
    #expect(body["format"] as? String == "text")

    #expect(Set(responses) == [
      TranslationResponse(clientIdentifier: "a", targetText: "مرحبا"),
      TranslationResponse(clientIdentifier: "b", targetText: "عالم"),
    ])
  }

  @Test
  func omitsSourceForAutoDetect() async throws {
    let recorder = TransportRecorder(responses: [(200, Self.translations(["x"]))])
    let provider = makeProvider(apiKey: "k", recorder: recorder)

    _ = try await collect(provider.translate(
      [TranslationRequest(sourceText: "Hi", clientIdentifier: "a")],
      source: Locale.Language(identifier: Language.autoCode),
      target: Locale.Language(identifier: "ko"),
      strategy: .highFidelity
    ))

    let sent = await recorder.requests
    let body = try Self.jsonBody(of: #require(sent.first))
    #expect(body["source"] == nil)
    #expect(body["target"] as? String == "ko")
  }

  @Test
  func missingKeyFailsPromptly() async {
    let recorder = TransportRecorder(responses: [(200, Self.translations(["x"]))])
    let provider = makeProvider(apiKey: nil, recorder: recorder)

    await #expect(throws: TranslationProviderError.self) {
      _ = try await collect(provider.translate(
        [TranslationRequest(sourceText: "Hi", clientIdentifier: "a")],
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "ar"),
        strategy: .lowLatency
      ))
    }
    let sent = await recorder.requests
    #expect(sent.isEmpty)
  }

  @Test
  func chunksBySegmentCountAndFansOutRequests() async throws {
    // Echo as many translations as the request carries `q` items.
    let recorder = TransportRecorder { request in
      let count = ((try? Self.jsonBody(of: request))?["q"] as? [String])?.count ?? 0
      return (200, Self.translations((0..<count).map { "t\($0)" }))
    }
    let provider = makeProvider(apiKey: "k", recorder: recorder)
    let requests = (0..<300).map { TranslationRequest(sourceText: "line \($0)", clientIdentifier: "\($0)") }

    let chunks = GoogleCloudTranslationProvider.chunk(requests)
    #expect(chunks.map(\.count) == [128, 128, 44])

    let responses = try await collect(provider.translate(
      requests,
      source: Locale.Language(identifier: "en"),
      target: Locale.Language(identifier: "de"),
      strategy: .lowLatency
    ))
    let sent = await recorder.requests
    #expect(sent.count == 3)
    #expect(responses.count == 300)
    #expect(Set(responses.map(\.clientIdentifier)) == Set(requests.map(\.clientIdentifier)))
    // Pairing is positional within a chunk: the first item of the last chunk
    // is request 256 and gets that chunk's first translation.
    #expect(responses.first { $0.clientIdentifier == "256" }?.targetText == "t0")
  }

  @Test
  func chunksByCharacterBudget() {
    let long = String(repeating: "a", count: 10000)
    let requests = (0..<5).map { TranslationRequest(sourceText: long, clientIdentifier: "\($0)") }
    let chunks = GoogleCloudTranslationProvider.chunk(requests)
    #expect(chunks.map(\.count) == [2, 2, 1])
    #expect(GoogleCloudTranslationProvider.chunk([]).isEmpty)
  }

  @Test
  func retriesOnceOnServerErrorThenSucceeds() async throws {
    let recorder = TransportRecorder(responses: [
      (503, #"{"error":{"code":503,"message":"backend","status":"UNAVAILABLE"}}"#),
      (200, Self.translations(["ok"])),
    ])
    let provider = makeProvider(apiKey: "k", recorder: recorder)

    let responses = try await collect(provider.translate(
      [TranslationRequest(sourceText: "Hi", clientIdentifier: "a")],
      source: Locale.Language(identifier: "en"),
      target: Locale.Language(identifier: "fr"),
      strategy: .lowLatency
    ))
    #expect(responses == [TranslationResponse(clientIdentifier: "a", targetText: "ok")])
    let sent = await recorder.requests
    #expect(sent.count == 2)
  }

  @Test
  func rateLimitAfterRetryIsReported() async {
    let recorder = TransportRecorder(responses: [(429, #"{"error":{"code":429,"message":"quota"}}"#)])
    let provider = makeProvider(apiKey: "k", recorder: recorder)

    do {
      _ = try await collect(provider.translate(
        [TranslationRequest(sourceText: "Hi", clientIdentifier: "a")],
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "fr"),
        strategy: .lowLatency
      ))
      Issue.record("Expected a rate-limit error")
    } catch let error as TranslationProviderError {
      guard case .rateLimited = error else {
        Issue.record("Unexpected error \(error)")
        return
      }
    } catch {
      Issue.record("Unexpected error \(error)")
    }
    let sent = await recorder.requests
    #expect(sent.count == 2)
  }

  @Test
  func apiErrorPayloadIsSurfaced() async {
    let recorder = TransportRecorder(responses: [
      (403, #"{"error":{"code":403,"message":"The request is missing a valid API key.","status":"PERMISSION_DENIED"}}"#),
    ])
    let provider = makeProvider(apiKey: "bad", recorder: recorder)

    do {
      _ = try await collect(provider.translate(
        [TranslationRequest(sourceText: "Hi", clientIdentifier: "a")],
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "ja"),
        strategy: .lowLatency
      ))
      Issue.record("Expected an API error")
    } catch let error as TranslationProviderError {
      guard case .api(let code, let message) = error else {
        Issue.record("Unexpected error \(error)")
        return
      }
      #expect(code == 403)
      #expect(message == "The request is missing a valid API key.")
      #expect(error.localizedDescription.contains("403"))
    } catch {
      Issue.record("Unexpected error \(error)")
    }
    let sent = await recorder.requests
    #expect(sent.count == 1)
  }

  @Test
  func mapsLocaleLanguagesToGoogleCodes() {
    let cases: [(String, String?)] = [
      ("ar", "ar"),
      ("ar-Arab-EG", "ar"),
      ("en-US", "en"),
      ("ko-KR", "ko"),
      ("ja", "ja"),
      ("zh-Hans", "zh-CN"),
      ("zh-Hans-CN", "zh-CN"),
      ("zh-Hant", "zh-TW"),
      ("zh-Hant-TW", "zh-TW"),
      ("zh-TW", "zh-TW"),
      ("pt-BR", "pt"),
      ("pt", "pt"),
      ("nb", "no"),
      (Language.autoCode, nil),
    ]
    for (identifier, expected) in cases {
      let code = GoogleCloudTranslationProvider.googleCode(for: Locale.Language(identifier: identifier))
      #expect(code == expected, "\(identifier)")
    }
  }

  @Test
  func mapsGoogleCodesBackToScriptTags() {
    let languages = GoogleCloudTranslationProvider.localeLanguages(fromGoogleCodes: ["zh-CN", "zh-TW", "zh", "ar", "iw"])
    #expect(languages.map(\.maximalIdentifier) == [
      Locale.Language(identifier: "zh-Hans").maximalIdentifier,
      Locale.Language(identifier: "zh-Hant").maximalIdentifier,
      Locale.Language(identifier: "ar").maximalIdentifier,
      Locale.Language(identifier: "he").maximalIdentifier,
    ])
  }

  @Test
  func staticLanguagesIncludeArabicAndCommonTargets() async throws {
    let recorder = TransportRecorder(responses: [(200, "{}")])
    let provider = makeProvider(apiKey: nil, recorder: recorder)

    let languages = try await provider.supportedLanguages()
    let codes = Set(languages.compactMap { $0.languageCode?.identifier })
    #expect(codes.isSuperset(of: ["ar", "en", "ko", "ja", "zh", "fr", "de", "es", "pt", "it", "ru", "tr", "hi", "id", "vi", "th"]))
    let sent = await recorder.requests
    #expect(sent.isEmpty)

    let catalog = Language.supported(translation: languages, ocr: nil)
    #expect(catalog.contains { $0.localeLanguage.languageCode?.identifier == "ar" })
    #expect(catalog.contains { $0.localeLanguage.script?.identifier == "Hant" })
  }

  @Test
  func supportedLanguagesFetchIsCachedPerKeyAndPersisted() async throws {
    let defaults = try #require(UserDefaults(suiteName: "GoogleCloudTranslationProviderTests.\(UUID().uuidString)"))
    let cache = GoogleSupportedLanguageCache(defaults: defaults)
    let recorder = TransportRecorder(responses: [
      (200, #"{"data":{"languages":[{"language":"ar"},{"language":"zh-CN"},{"language":"en"}]}}"#),
    ])
    let provider = GoogleCloudTranslationProvider(
      apiKey: "k",
      transport: recorder.transport,
      languageCache: cache,
      retryDelay: .zero
    )

    let first = try await provider.supportedLanguages()
    let second = try await provider.supportedLanguages()
    let sent = await recorder.requests
    #expect(sent.count == 1)
    #expect(sent.first?.httpMethod == "GET")
    #expect(sent.first?.url?.path == "/language/translate/v2/languages")
    #expect(sent.first?.value(forHTTPHeaderField: "X-Goog-Api-Key") == "k")
    #expect(first == second)
    #expect(first.map(\.maximalIdentifier).contains(Locale.Language(identifier: "ar").maximalIdentifier))
    #expect(defaults.stringArray(forKey: GoogleSupportedLanguageCache.defaultsKey) == ["ar", "zh-CN", "en"])

    // A failing listing under a different key falls back to the persisted one.
    let failing = TransportRecorder(responses: [(500, "boom")])
    let offline = GoogleCloudTranslationProvider(
      apiKey: "other",
      transport: failing.transport,
      languageCache: cache,
      retryDelay: .zero
    )
    let fallback = try await offline.supportedLanguages()
    #expect(fallback == first)
  }

  // MARK: Private

  private static func translations(_ texts: [String]) -> String {
    let items = texts.map { #"{"translatedText":"\#($0)"}"# }.joined(separator: ",")
    return #"{"data":{"translations":[\#(items)]}}"#
  }

  private static func jsonBody(of request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func makeProvider(apiKey: String?, recorder: TransportRecorder) -> GoogleCloudTranslationProvider {
    GoogleCloudTranslationProvider(
      apiKey: apiKey,
      transport: recorder.transport,
      languageCache: GoogleSupportedLanguageCache(
        defaults: UserDefaults(suiteName: "GoogleCloudTranslationProviderTests.\(UUID().uuidString)")!
      ),
      retryDelay: .zero
    )
  }

  private func collect(
    _ stream: AsyncThrowingStream<TranslationResponse, any Error>
  ) async throws -> [TranslationResponse] {
    var results = [TranslationResponse]()
    for try await response in stream {
      results.append(response)
    }
    return results
  }
}
