// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

// MARK: - View + compatWindowDrag

extension View {
  /// Makes this view a window move handle.
  ///
  /// macOS 15+ uses SwiftUI's `WindowDragGesture`. Earlier systems overlay an
  /// AppKit view whose `mouseDown` hands the event to
  /// `NSWindow.performDrag(with:)` — the same window-server-driven drag, so the
  /// overlay's pass-through / hit-zone logic in `OverlayWindowController` is
  /// untouched.
  @ViewBuilder
  func compatWindowDrag() -> some View {
    if #available(macOS 15.0, *) {
      gesture(WindowDragGesture())
    } else {
      overlay(CompatWindowDragHandle())
    }
  }
}

// MARK: - CompatWindowDragHandle

private struct CompatWindowDragHandle: NSViewRepresentable {
  func makeNSView(context _: Context) -> CompatWindowDragView {
    CompatWindowDragView()
  }

  func updateNSView(_: CompatWindowDragView, context _: Context) { }
}

// MARK: - CompatWindowDragView

private final class CompatWindowDragView: NSView {
  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    // The overlay is a non-activating panel; the first click must drag.
    true
  }

  override func mouseDown(with event: NSEvent) {
    guard let window else {
      super.mouseDown(with: event)
      return
    }
    window.performDrag(with: event)
  }
}
