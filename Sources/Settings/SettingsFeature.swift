// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Sharing

// MARK: - SettingsFeature

/// Owns the Settings screen's side effects — loading the installed language
/// lists, reading/writing the login item, and the updater's availability —
/// so the views stay declarative.
@Reducer
struct SettingsFeature {

  @ObservableState
  struct State {
    var sourceLanguages = [Language]()
    var targetLanguages = [Language]()
    var launchAtLogin = false
    var canCheckForUpdates = false
    /// Text in the API key field. Only ever written to the Keychain on Save;
    /// cleared afterwards so the key isn't kept around in view state.
    var googleAPIKeyDraft = ""
    var hasGoogleAPIKey = false
    var googleAPIKeyError: String?

    @Shared(.settings) var settings
  }

  enum Action {
    case task
    case launchAtLoginLoaded(Bool)
    case launchAtLoginChanged(Bool)
    case languagesLoaded(source: [Language], target: [Language])
    case canCheckForUpdatesChanged(Bool)
    case checkForUpdatesTapped
    case translationProviderChanged(TranslationProviderID)
    case googleAPIKeyStatusLoaded(hasKey: Bool)
    case googleAPIKeyChanged(String)
    case saveGoogleAPIKey
    case removeGoogleAPIKey
    case googleAPIKeyFailed(String)
  }

  @Dependency(\.languageCatalog) var languageCatalog
  @Dependency(\.loginItem) var loginItem
  @Dependency(\.translationCredential) var translationCredential
  @Dependency(\.updater) var updater

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        return .merge(
          .run { [loginItem] send in
            await send(.launchAtLoginLoaded(loginItem.isEnabled()))
          },
          loadLanguages(),
          .run { [translationCredential] send in
            await send(.googleAPIKeyStatusLoaded(hasKey: translationCredential.apiKey(.google) != nil))
          },
          .run { [updater] send in
            for await value in updater.canCheckForUpdates() {
              await send(.canCheckForUpdatesChanged(value))
            }
          }
        )

      case .launchAtLoginLoaded(let enabled):
        state.launchAtLogin = enabled
        return .none

      case .launchAtLoginChanged(let enabled):
        state.launchAtLogin = enabled
        return .run { [loginItem] _ in loginItem.setEnabled(enabled) }

      case .languagesLoaded(let source, let target):
        state.sourceLanguages = source
        state.targetLanguages = target
        return .none

      case .canCheckForUpdatesChanged(let value):
        state.canCheckForUpdates = value
        return .none

      case .checkForUpdatesTapped:
        return .run { [updater] _ in updater.checkForUpdates() }

      case .translationProviderChanged(let provider):
        state.$settings.withLock { $0.translation.provider = provider }
        // The language lists come from the provider, so they change with it.
        return loadLanguages()

      case .googleAPIKeyStatusLoaded(let hasKey):
        state.hasGoogleAPIKey = hasKey
        return .none

      case .googleAPIKeyChanged(let draft):
        state.googleAPIKeyDraft = draft
        state.googleAPIKeyError = nil
        return .none

      case .saveGoogleAPIKey:
        let key = state.googleAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .none }
        state.googleAPIKeyDraft = ""
        state.googleAPIKeyError = nil
        // Sequenced, not merged: the language listing must see the new key.
        return .concatenate(
          .run { [translationCredential] send in
            do {
              try translationCredential.setAPIKey(key, .google)
              await send(.googleAPIKeyStatusLoaded(hasKey: true))
            } catch {
              await send(.googleAPIKeyFailed(error.localizedDescription))
            }
          },
          loadLanguages()
        )

      case .removeGoogleAPIKey:
        state.googleAPIKeyDraft = ""
        state.googleAPIKeyError = nil
        return .concatenate(
          .run { [translationCredential] send in
            do {
              try translationCredential.setAPIKey(nil, .google)
              await send(.googleAPIKeyStatusLoaded(hasKey: false))
            } catch {
              await send(.googleAPIKeyFailed(error.localizedDescription))
            }
          },
          loadLanguages()
        )

      case .googleAPIKeyFailed(let message):
        state.googleAPIKeyError = message
        return .none
      }
    }
  }

  /// Lists are loaded from the selected translation provider · Vision on this
  /// device.
  private func loadLanguages() -> Effect<Action> {
    .run { [languageCatalog] send in
      async let source = languageCatalog.supported(intersectedWithOCR: true)
      async let target = languageCatalog.supported(intersectedWithOCR: false)
      await send(.languagesLoaded(source: [.auto] + source, target: target))
    }
  }
}
