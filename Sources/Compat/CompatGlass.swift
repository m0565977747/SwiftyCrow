// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

// MARK: - CompatGlassStyle

/// Deployment-target-independent description of a Liquid Glass surface.
///
/// On macOS 26 this maps 1:1 onto SwiftUI's `Glass` (`.regular`, `.tint(_:)`,
/// `.interactive()`), so the modern build renders exactly as before. On
/// macOS 13–25 `compatGlass(_:in:)` falls back to an `.ultraThinMaterial` fill
/// with a hairline border and an optional translucent tint.
struct CompatGlassStyle: Equatable {

  // MARK: Internal

  static let regular = CompatGlassStyle()

  /// Mirrors `Glass.tint(_:)`; `nil` clears the tint.
  func tint(_ color: Color?) -> CompatGlassStyle {
    var copy = self
    copy.tint = color
    return copy
  }

  /// Mirrors `Glass.interactive(_:)`.
  func interactive(_ isEnabled: Bool = true) -> CompatGlassStyle {
    var copy = self
    copy.isInteractive = isEnabled
    return copy
  }

  // MARK: Fileprivate

  fileprivate var tint: Color?
  fileprivate var isInteractive = false

  @available(macOS 26.0, *)
  fileprivate var glass: Glass {
    var glass = Glass.regular
    if let tint {
      glass = glass.tint(tint)
    }
    if isInteractive {
      glass = glass.interactive()
    }
    return glass
  }

}

// MARK: - View + compatGlass

extension View {
  /// `.glassEffect(_:in:)` on macOS 26, a material-backed approximation below.
  ///
  /// Only `InsettableShape`s are accepted (every call site uses a capsule,
  /// circle or rounded rectangle) so the fallback can draw a crisp inner border.
  @ViewBuilder
  func compatGlass<S: InsettableShape>(_ style: CompatGlassStyle = .regular, in shape: S) -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(style.glass, in: shape)
    } else {
      modifier(CompatGlassFallback(style: style, shape: shape))
    }
  }

  /// `.buttonStyle(.glassProminent)` on macOS 26, `.borderedProminent` below.
  @ViewBuilder
  func compatProminentButtonStyle() -> some View {
    if #available(macOS 26.0, *) {
      buttonStyle(.glassProminent)
    } else {
      buttonStyle(.borderedProminent)
    }
  }
}

// MARK: - CompatGlassFallback

private struct CompatGlassFallback<S: InsettableShape>: ViewModifier {
  let style: CompatGlassStyle
  let shape: S

  func body(content: Content) -> some View {
    content
      .background(.ultraThinMaterial, in: shape)
      .overlay {
        if let tint = style.tint {
          shape.fill(tint.opacity(0.28))
            .allowsHitTesting(false)
        }
      }
      .overlay {
        shape
          .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
          .allowsHitTesting(false)
      }
  }
}
