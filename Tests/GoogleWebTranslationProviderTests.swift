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

// MARK: - GoogleWebTranslationProviderTests

@Suite("Google Translate (web) provider")
struct GoogleWebTranslationProviderTests {

  // MARK: Internal

  @Test
  func buildsGtxQueryWithStrictPercentEncoding() throws {
    let url = GoogleWebTranslationProvider.requestURL(text: "a b+c&d=e/f?g", source: "en", target: "ar")
    let string = url.absoluteString
    #expect(string.hasPrefix("https://translate.googleapis.com/translate_a/single?"))
    #expect(string.contains("client=gtx"))
    #expect(string.contains("&sl=en&"))
    #expect(string.contains("&tl=ar&"))
    #expect(string.contains("&dt=t&"))
    #expect(string.hasSuffix("&q=a%20b%2Bc%26d%3De%2Ff%3Fg"))
    // Nothing but unreserved characters and percent escapes survive.
    #expect(!string.contains("+"))
    #expect(!string.contains(" "))

    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(items["q"] == "a b+c&d=e/f?g")
    #expect(items["sl"] == "en")
    #expect(items["tl"] == "ar")
  }

  @Test
  func percentEncodesNonASCIIAndUsesAutoForUnknownSource() throws {
    let url = GoogleWebTranslationProvider.requestURL(text: "مرحبا بالعالم", source: nil, target: "en")
    let string = url.absoluteString
    #expect(string.contains("&sl=auto&"))
    #expect(string.hasSuffix("&q=%D9%85%D8%B1%D8%AD%D8%A8%D8%A7%20%D8%A8%D8%A7%D9%84%D8%B9%D8%A7%D9%84%D9%85"))
    #expect(string.utf8.allSatisfy { $0 < 128 })

    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.queryItems?.first { $0.name == "q" }?.value == "مرحبا بالعالم")
    #expect(GoogleWebTranslationProvider.percentEncode("~-._") == "~-._")
  }

  @Test
  func concatenatesSegmentsAndSkipsNullEntries() throws {
    let body = #"[[["مرحبا ","Hello ",null,null,10],[null,null,null,"Hello"],["بالعالم","world",null,null,3]],null,"en",null,null,null,null,[]]"#
    let text = try GoogleWebTranslationProvider.parseTranslation(from: Data(body.utf8))
    #expect(text == "مرحبا بالعالم")
  }

  @Test
  func rejectsUnexpectedResponseShape() {
    for body in ["{}", "[]", "[null]", "not json", #"[[["ok"]]"#] {
      #expect(throws: TranslationProviderError.self) {
        _ = try GoogleWebTranslationProvider.parseTranslation(from: Data(body.utf8))
      }
    }
  }

  @Test
  func sendsOneGetPerRequestWithBrowserUserAgent() async throws {
    let recorder = TransportRecorder { request in
      let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "q" }?.value ?? ""
      return (200, #"[[["<\#(q)>","\#(q)",null,null,10]],null,"en"]"#)
    }
    let provider = makeProvider(recorder: recorder)
    let requests = (0..<10).map { TranslationRequest(sourceText: "line \($0)", clientIdentifier: "\($0)") }

    let responses = try await collect(provider.translate(
      requests,
      source: Locale.Language(identifier: "en-US"),
      target: Locale.Language(identifier: "zh-Hant-TW"),
      strategy: .lowLatency
    ))

    let sent = await recorder.requests
    #expect(sent.count == 10)
    for request in sent {
      #expect(request.httpMethod == "GET")
      #expect(request.httpBody == nil)
      #expect(request.url?.host() == "translate.googleapis.com")
      #expect(request.url?.path == "/translate_a/single")
      #expect(request.url?.query?.contains("tl=zh-TW") == true)
      #expect(request.url?.query?.contains("sl=en") == true)
      #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Mozilla/5.0") == true)
    }
    #expect(responses.count == 10)
    #expect(responses.first { $0.clientIdentifier == "7" }?.targetText == "<line 7>")
    #expect(Set(responses.map(\.clientIdentifier)) == Set(requests.map(\.clientIdentifier)))
  }

  @Test
  func retriesOnceOnServerErrorThenSucceeds() async throws {
    let recorder = TransportRecorder(responses: [
      (503, "<html>unavailable</html>"),
      (200, #"[[["ok","Hi",null,null,10]],null,"en"]"#),
    ])
    let provider = makeProvider(recorder: recorder)

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
    let recorder = TransportRecorder(responses: [(429, "")])
    let provider = makeProvider(recorder: recorder)

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
  func otherStatusesBecomeAPIErrors() async {
    let recorder = TransportRecorder(responses: [(403, "<html>blocked</html>")])
    let provider = makeProvider(recorder: recorder)

    do {
      _ = try await collect(provider.translate(
        [TranslationRequest(sourceText: "Hi", clientIdentifier: "a")],
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "ja"),
        strategy: .lowLatency
      ))
      Issue.record("Expected an API error")
    } catch let error as TranslationProviderError {
      guard case .api(let code, _) = error else {
        Issue.record("Unexpected error \(error)")
        return
      }
      #expect(code == 403)
      #expect(error.localizedDescription.contains("403"))
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }

  @Test
  func staticLanguagesIncludeArabicWithoutNetwork() async throws {
    let recorder = TransportRecorder(responses: [(200, "[]")])
    let provider = makeProvider(recorder: recorder)

    let languages = try await provider.supportedLanguages()
    let codes = Set(languages.compactMap { $0.languageCode?.identifier })
    #expect(codes.isSuperset(of: ["ar", "en", "ko", "ja", "zh", "fr", "de", "es"]))
    #expect(provider.supportsStyledTranslation == false)
    #expect(provider.id == .googleWeb)
    let sent = await recorder.requests
    #expect(sent.isEmpty)
  }

  // MARK: Private

  private func makeProvider(recorder: TransportRecorder) -> GoogleWebTranslationProvider {
    GoogleWebTranslationProvider(transport: recorder.transport, retryDelay: .zero)
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

// MARK: - OllamaTranslationProviderTests

@Suite("Ollama provider")
struct OllamaTranslationProviderTests {

  // MARK: Internal

  @Test
  func parsesChatReplyTrimmingWhitespaceAndQuotes() throws {
    let body = #"{"model":"gemma3:4b","message":{"role":"assistant","content":"  \"مرحبا بالعالم\"\n"},"done":true}"#
    let text = try OllamaTranslationProvider.parseReply(from: Data(body.utf8))
    #expect(text == "مرحبا بالعالم")
    #expect(OllamaTranslationProvider.stripQuotes("“Hola\nmundo”") == "Hola\nmundo")
    #expect(OllamaTranslationProvider.stripQuotes("\"unbalanced") == "\"unbalanced")
    #expect(OllamaTranslationProvider.stripQuotes("\"") == "\"")
    #expect(OllamaTranslationProvider.stripQuotes("He said \"hi\" there") == "He said \"hi\" there")
  }

  @Test
  func surfacesErrorPayloads() {
    #expect(throws: TranslationProviderError.self) {
      _ = try OllamaTranslationProvider.parseReply(from: Data(#"{"error":"model 'x' not found"}"#.utf8))
    }
    #expect(throws: TranslationProviderError.self) {
      _ = try OllamaTranslationProvider.parseReply(from: Data("nope".utf8))
    }
  }

  @Test
  func buildsChatRequestAndURL() throws {
    #expect(OllamaTranslationProvider.chatURL(endpoint: "http://127.0.0.1:11434/").absoluteString == "http://127.0.0.1:11434/api/chat")
    #expect(OllamaTranslationProvider.chatURL(endpoint: " http://box.local:11434 ").absoluteString == "http://box.local:11434/api/chat")
    #expect(OllamaTranslationProvider.chatURL(endpoint: "").absoluteString == "http://127.0.0.1:11434/api/chat")

    let data = try OllamaTranslationProvider.requestBody(model: "gemma3:4b", text: "Hello\nworld", source: nil, target: "Arabic")
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["model"] as? String == "gemma3:4b")
    #expect(json["stream"] as? Bool == false)
    #expect((json["options"] as? [String: Any])?["temperature"] as? Double == 0)
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 2)
    #expect(messages[0]["role"] as? String == "system")
    #expect((messages[0]["content"] as? String)?.contains("from the detected language to Arabic") == true)
    #expect(messages[1]["role"] as? String == "user")
    #expect(messages[1]["content"] as? String == "Hello\nworld")

    #expect(OllamaTranslationProvider.languageName(for: Locale.Language(identifier: "ar")) == "Arabic")
    #expect(OllamaTranslationProvider.languageName(for: Locale.Language(identifier: "zh-Hans")).contains("Chinese"))
    #expect(OllamaTranslationProvider.languageName(for: Locale.Language(identifier: Language.autoCode)) == nil)
  }
}
