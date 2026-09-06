// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import DependenciesMacros
import Foundation
import Security

// MARK: - TranslationCredentialClient

/// Reads and writes the API keys translation providers need. Keys live in the
/// login Keychain (never in config.toml, which is plain text and hand-editable)
/// and are never logged.
@DependencyClient
struct TranslationCredentialClient: Sendable {
  /// The stored key for `provider`, or nil if none (or the provider needs none).
  var apiKey: @Sendable (_ provider: TranslationProviderID) -> String? = { _ in nil }
  /// Stores `key` for `provider`; nil or an empty string removes it.
  var setAPIKey: @Sendable (_ key: String?, _ provider: TranslationProviderID) throws -> Void
}

extension TranslationCredentialClient: DependencyKey {
  static let liveValue = TranslationCredentialClient(
    apiKey: { provider in
      guard let account = KeychainCredentialStore.account(for: provider) else { return nil }
      return KeychainCredentialStore.read(account: account)
    },
    setAPIKey: { key, provider in
      guard let account = KeychainCredentialStore.account(for: provider) else { return }
      try KeychainCredentialStore.write(key, account: account)
    }
  )

  static let testValue = TranslationCredentialClient(
    apiKey: { _ in nil },
    setAPIKey: { _, _ in }
  )
}

extension DependencyValues {
  var translationCredential: TranslationCredentialClient {
    get { self[TranslationCredentialClient.self] }
    set { self[TranslationCredentialClient.self] = newValue }
  }
}

// MARK: - KeychainCredentialStore

/// Generic-password items under one service name, one account per provider.
enum KeychainCredentialStore {

  // MARK: Internal

  static let service = "dev.PangMo5.SwiftyCrow.translation"

  static func account(for provider: TranslationProviderID) -> String? {
    switch provider {
    case .apple, .googleWeb, .ollama: nil
    case .google: "google-cloud-api-key"
    }
  }

  static func read(account: String) -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      if status != errSecItemNotFound {
        Log.translation.error("Keychain read failed: \(KeychainError(status: status).localizedDescription, privacy: .public)")
      }
      return nil
    }
    let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }

  static func write(_ value: String?, account: String) throws {
    let query = baseQuery(account: account)
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainError(status: status)
      }
      return
    }
    let data = Data(trimmed.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrLabel as String] = "SwiftyCrow Google Cloud Translation"
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    default:
      throw KeychainError(status: updateStatus)
    }
  }

  // MARK: Private

  private static func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

// MARK: - KeychainError

struct KeychainError: Error, LocalizedError, Equatable {
  var status: OSStatus

  var errorDescription: String? {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return "Keychain error: \(message)"
  }
}
