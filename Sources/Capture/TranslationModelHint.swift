// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Perception
import Sharing
import SwiftUI

// MARK: - Open Language Settings

/// Opens System Settings → General → Language & Region, where the user adds
/// on-device translation models via "Translation Languages…".
@MainActor
func openLanguageSettings() {
  guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
  NSWorkspace.shared.open(url)
}

/// UserDefaults key for "don't show again". Read directly by the overlay
/// controller (which isn't a SwiftUI view) to drop the hint's interactive zone.
let translationModelHintDismissedKey = "hideTranslationModelHint"

// MARK: - PreparingRecognitionNote

/// Shown while Vision loads its document-recognition model. Cold, that costs tens
/// of seconds, and it happens in the app's own process — so without saying so the
/// overlay is an empty frame with a spinner, which reads as a hang. Non-interactive
/// on purpose: it needs no buttons, so the overlay's pass-through stays untouched.
struct PreparingRecognitionNote: View {
  var body: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      VStack(alignment: .leading, spacing: 1) {
        Text("Preparing text recognition")
          .font(.caption)
          .fontWeight(.semibold)
        Text("macOS is loading the recognition model. This only happens the first time, or after it has been unloaded.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial)
  }
}

// MARK: - TranslationModelHint

/// Shown when translation fails because the backend can't serve the request.
/// With Apple Translation that means the on-device model isn't installed —
/// the framework only translates languages downloaded in System Settings, so
/// this links straight there. With Google Cloud Translation it means the API
/// key is missing or rejected; with the free Google endpoint the network is
/// down or rate-limiting; with Ollama the server isn't running. Those open
/// the app's own Settings instead. A "Don't show again" suppresses it for
/// good once the user gets the point.
struct TranslationModelHint: View {

  // MARK: Internal

  var body: some View {
    WithPerceptionTracking {
      if !dismissed {
        content
      }
    }
  }

  // MARK: Private

  @Shared(.appStorage(translationModelHintDismissedKey)) private var dismissed = false
  @Shared(.settings) private var settings

  private var provider: TranslationProviderID {
    TranslationProviderSelection.resolvedID(preferred: settings.translation.provider)
  }

  private var usesAppleTranslation: Bool {
    provider == .apple
  }

  private var title: String {
    switch provider {
    case .apple: "Translation model not installed"
    case .google: "Google Cloud Translation API key missing or invalid"
    case .googleWeb: "Translation service unavailable — check your internet connection"
    case .ollama: "Ollama isn't running — start it or pick another provider in Settings"
    }
  }

  private var detail: String {
    switch provider {
    case .apple:
      "Add the language under System Settings → General → Language & Region → Translation Languages, then capture again."
    case .google:
      "Add a Cloud Translation API key under SwiftyCrow Settings → Translation, then capture again."
    case .googleWeb:
      "The free Google Translate endpoint didn't answer (offline, blocked, or rate-limited). Retry in a moment, or choose another provider under SwiftyCrow Settings → Translation."
    case .ollama:
      "Run `ollama serve` and pull the model (`ollama pull \(settings.translation.ollamaModel)`), then capture again — or choose another provider under SwiftyCrow Settings → Translation."
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.caption)
            .fontWeight(.semibold)
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
      }
      HStack(spacing: 14) {
        Button("Open Settings") {
          if usesAppleTranslation {
            openLanguageSettings()
          } else {
            // The hint can be hosted in a detached AppKit view with no scene
            // environment, so it can't call `openWindow`; the always-mounted
            // menu-bar label turns this into a scene-level open.
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
          }
        }
        .controlSize(.small)
        Button("Don't show again") { $dismissed.withLock { $0 = true } }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.orange.opacity(0.18))
    .background(.regularMaterial)
  }
}
