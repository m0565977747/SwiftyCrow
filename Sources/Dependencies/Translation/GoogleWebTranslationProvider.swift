// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - GoogleWebTranslationProvider

/// Google Translate through the public web endpoint
/// (`translate.googleapis.com/translate_a/single`, `client=gtx`) — the same
/// one the translate.google.com widget uses. It needs no account, key or card,
/// which makes it the out-of-the-box backend on macOS releases before 26.
///
/// This endpoint is **unofficial and undocumented**: Google may rate-limit it
/// (HTTP 429), block a client, or change the response shape at any time, and
/// its terms don't cover heavy or commercial use. Treat it as best-effort for
/// personal use; `GoogleCloudTranslationProvider` is the supported path.
///
/// The endpoint takes one `q` per request, so each `TranslationRequest`
/// becomes its own GET; a few run concurrently and each answer is yielded as
/// it lands. `TranslationStrategy` is ignored (single NMT model).
struct GoogleWebTranslationProvider: TranslationProvider {

  // MARK: Lifecycle

  init(
    transport: @escaping Transport = GoogleCloudTranslationProvider.urlSessionTransport,
    retryDelay: Duration = .milliseconds(600),
    maximumConcurrentRequests: Int = 4
  ) {
    self.transport = transport
    self.retryDelay = retryDelay
    self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
  }

  // MARK: Internal

  typealias Transport = GoogleCloudTranslationProvider.Transport

  static let endpoint = URL(string: "https://translate.googleapis.com/translate_a/single")!

  /// A plain browser identity; the endpoint answers 403 to some default
  /// client strings.
  static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

  /// RFC 3986 unreserved characters, spelled out as ASCII on purpose:
  /// `CharacterSet.alphanumerics` also contains every non-ASCII letter, which
  /// would leave Arabic or CJK text raw in the URL. Everything else — space,
  /// `+`, `&`, `=`, `/`, `?`, non-ASCII — is percent-encoded, so `+` can't be
  /// misread as a space by the server.
  static let unreservedQueryCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  )

  let id = TranslationProviderID.googleWeb
  let supportsStyledTranslation = false

  var transport: Transport
  var retryDelay: Duration
  var maximumConcurrentRequests: Int

  static func percentEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreservedQueryCharacters) ?? value
  }

  /// `?client=gtx&sl=<source|auto>&tl=<target>&dt=t&q=<text>`. The query is
  /// assembled by hand because `URLComponents.queryItems` leaves `+` bare.
  static func requestURL(text: String, source: String?, target: String) -> URL {
    let query = [
      ("client", "gtx"),
      ("sl", source ?? "auto"),
      ("tl", target),
      ("dt", "t"),
      ("q", text),
    ]
    .map { "\($0.0)=\(percentEncode($0.1))" }
    .joined(separator: "&")
    return URL(string: "\(endpoint.absoluteString)?\(query)") ?? endpoint
  }

  /// The response is a nested JSON array, e.g.
  /// `[[["Hola","Hello",null,null,10],["mundo","world",null,null,10]],null,"en",…]`;
  /// the translation is the concatenation of `[0][i][0]`. Entries whose first
  /// element isn't a string (null padding) are skipped.
  static func parseTranslation(from data: Data) throws -> String {
    guard
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
      let segments = root.first as? [Any]
    else {
      throw TranslationProviderError.api(code: 0, message: "Unreadable response from the translation service.")
    }
    var text = ""
    for case let segment as [Any] in segments {
      if let piece = segment.first as? String {
        text += piece
      }
    }
    return text
  }

  func translate(
    _ requests: [TranslationRequest],
    source: Locale.Language,
    target: Locale.Language,
    strategy _: TranslationStrategy
  ) -> AsyncThrowingStream<TranslationResponse, any Error> {
    AsyncThrowingStream { continuation in
      guard let targetCode = GoogleCloudTranslationProvider.googleCode(for: target) else {
        continuation.finish(throwing: TranslationProviderError.unsupportedLanguagePair)
        return
      }
      let sourceCode = GoogleCloudTranslationProvider.googleCode(for: source)
      let limit = maximumConcurrentRequests
      let task = Task {
        do {
          // A sliding window of `limit` requests: each finished one admits the
          // next, so the stream stays unordered without flooding the endpoint.
          try await withThrowingTaskGroup(of: TranslationResponse.self) { group in
            var pending = requests[...]
            for _ in 0..<min(limit, pending.count) {
              let request = pending.removeFirst()
              group.addTask {
                try await translateOne(request, source: sourceCode, target: targetCode)
              }
            }
            for try await response in group {
              continuation.yield(response)
              if !pending.isEmpty {
                let request = pending.removeFirst()
                group.addTask {
                  try await translateOne(request, source: sourceCode, target: targetCode)
                }
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

  /// The endpoint has no listing call; it accepts every language the Cloud
  /// API does, so the same static set (Arabic included) is offered.
  func supportedLanguages() async throws -> [Locale.Language] {
    GoogleCloudTranslationProvider.staticLanguages
  }

  // MARK: Private

  private static func error(forStatus status: Int, body: Data) -> TranslationProviderError {
    if status == 429 {
      return .rateLimited
    }
    let snippet = String(data: body.prefix(200), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let message = snippet.isEmpty || snippet.hasPrefix("<")
      ? HTTPURLResponse.localizedString(forStatusCode: status)
      : snippet
    return .api(code: status, message: message)
  }

  private func translateOne(
    _ request: TranslationRequest,
    source: String?,
    target: String
  ) async throws -> TranslationResponse {
    var urlRequest = URLRequest(url: Self.requestURL(text: request.sourceText, source: source, target: target))
    urlRequest.httpMethod = "GET"
    urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    let data = try await send(urlRequest)
    let text = try Self.parseTranslation(from: data)
    return TranslationResponse(clientIdentifier: request.clientIdentifier, targetText: text)
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
        Log.translation.debug("Google Translate (web) answered \(status, privacy: .public); retrying once")
        try await Task.sleep(for: retryDelay)
        continue
      }
      throw Self.error(forStatus: status, body: data)
    }
  }
}
