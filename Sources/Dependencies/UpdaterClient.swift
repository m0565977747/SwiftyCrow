// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import DependenciesMacros
import Foundation
import Sparkle

// MARK: - UpdaterClient

@DependencyClient
struct UpdaterClient {
  /// Emits whether the updater can currently start a check.
  var canCheckForUpdates: @Sendable () -> AsyncStream<Bool> = { .finished }
  /// Triggers a user-initiated update check.
  var checkForUpdates: @Sendable () -> Void
  /// Applies the scheduled-check preferences to the underlying updater.
  var configure: @Sendable (_ automaticallyChecks: Bool, _ interval: TimeInterval) -> Void
}

// MARK: DependencyKey

extension UpdaterClient: DependencyKey {
  static let liveValue: UpdaterClient = {
    // Sparkle refuses to start without an EdDSA public key and shows an
    // "Unable to Check For Updates" alert at launch. Builds made without the
    // key (CI / local builds of the Ventura backport) simply have no updater.
    let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
    guard !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return UpdaterClient(
        canCheckForUpdates: {
          AsyncStream { continuation in
            continuation.yield(false)
            continuation.finish()
          }
        },
        checkForUpdates: {},
        configure: { _, _ in }
      )
    }
    let controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    let updater = controller.updater
    return UpdaterClient(
      canCheckForUpdates: {
        // Sparkle doesn't reliably emit KVO change notifications for
        // canCheckForUpdates, so poll it and yield only on change.
        AsyncStream { continuation in
          let task = Task { @MainActor in
            var last: Bool?
            while !Task.isCancelled {
              let value = updater.canCheckForUpdates
              if value != last {
                last = value
                continuation.yield(value)
              }
              try? await Task.sleep(for: .seconds(1))
            }
            continuation.finish()
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      },
      checkForUpdates: {
        Task { @MainActor in updater.checkForUpdates() }
      },
      configure: { automaticallyChecks, interval in
        Task { @MainActor in
          updater.automaticallyChecksForUpdates = automaticallyChecks
          updater.updateCheckInterval = interval
        }
      }
    )
  }()
}

extension DependencyValues {
  var updater: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
