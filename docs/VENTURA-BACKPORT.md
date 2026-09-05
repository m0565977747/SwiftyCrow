# Ventura backport (macOS 13+)

SwiftyCrow is written against macOS 26. The `ventura-backport` branch lowers
the deployment target to **macOS 13.0** and ships a **Universal 2** binary
(arm64 + x86_64) so the app runs on Intel Macs and on Ventura / Sonoma /
Sequoia. This document is the map of what had to change and where the
compatibility code lives.


## Principles

- Modern code paths stay the default: every shim checks `#available(macOS N, *)`
  and calls the original API on systems that have it, so macOS 26 behaviour is
  unchanged.
- One shim per API family, in its own file, so each can be deleted the day the
  deployment target moves back up.
- No compile-time `#if`; everything is a runtime check so a single binary
  covers 13 → 26.

## Layout

| Folder | Purpose |
| --- | --- |
| `Sources/Compat/` | SwiftUI / AppKit shims for APIs newer than macOS 13 (`compatGlass`, `compatProminentButtonStyle`, `compatWindowDrag`). |
| `Sources/Dependencies/Translation/` | `TranslationProvider` protocol + `AppleTranslationProvider` (macOS 26, original code) + `GoogleCloudTranslationProvider` (Cloud Translation v2 over `URLSession`) + `TranslationCredentialStore` (Keychain). `TranslationClient` keeps all shared post-processing and only picks the provider. |
| `Sources/Dependencies/OCR/` | `ModernOCRPipeline` (macOS 26, `RecognizeDocumentsRequest`, original code) and `VenturaOCRPipeline` (`VNRecognizeTextRequest` revision 3 via `ClassicVisionTextRecognizer`), with `VenturaOCRLayout` synthesising paragraph groups / alignment / vertical-CJK geometrically. `VisionWarmUp` is shared. |
| `Sources/Dependencies/Capture/` | `VenturaSingleFrameCapture`: one-shot `SCStream` that returns the first complete frame and stops, used where `SCScreenshotManager` (macOS 14) is unavailable. Filters, display selection, Retina scaling and own-window exclusion are unchanged. |

## Compatibility layer (`Sources/Compat/`)

| Shim | Modern API (macOS) | Fallback (13–25) |
| --- | --- | --- |
| `View.compatGlass(_:in:)` | `.glassEffect(_:in:)` (26) | `.ultraThinMaterial` fill + hairline border + optional tint |
| `View.compatProminentButtonStyle()` | `.buttonStyle(.glassProminent)` (26) | `.borderedProminent` |
| `View.compatWindowDrag()` | `WindowDragGesture` (15) | `NSViewRepresentable` calling `NSWindow.performDrag(with:)` |

## Observation

- `OverlayWindowModel` is `@Perceptible` (swift-perception) instead of
  `@Observable` (macOS 14). On macOS 14+ it is the same Observation machinery.
- Every SwiftUI `body` that reads TCA `@ObservableState`, `@Shared`, or a
  `@Perceptible` model is wrapped in `WithPerceptionTracking { … }` — required
  for re-rendering on macOS 13, a no-op on 14+.
- `AppFeature` observed `@Shared` settings through `Observations { … }`
  (macOS 26); it now uses swift-sharing's `Shared.publisher` with
  `removeDuplicates()` (the publisher already replays the current value).

## Swift runtime / stdlib

- `Sequence.count(where:)` is Swift 6 stdlib (macOS 15 runtime); replaced with
  `.filter { … }.count`. The `preferCountWhere` SwiftFormat rule is disabled in
  `.swiftformat` so it is not reintroduced.

## Other availability guards

- `AccessibilitySettings.prefersHorizontalTextLayout` (+ notification) is
  macOS 15+; `TranslationOverlayLayer` reports `false` before that.
- `ContentUnavailableView` (macOS 14) has a `VStack` fallback in the legal
  document sheet.
- Shape shorthands (`.rect`, `.rect(cornerRadius:)`) are macOS 14; concrete
  `Rectangle()` / `RoundedRectangle(...)` are used instead.
- `onChange(of:) { old, new in }` (macOS 14) → single-value form.

## CI

`.github/workflows/build.yml` ("Build (Ventura backport)") builds Release with
`ARCHS="arm64 x86_64"` and `MACOSX_DEPLOYMENT_TARGET=13.0`, runs the tests, and
fails unless `lipo` reports both slices and `vtool` reports `minos 13.0`. The
zipped app and logs are uploaded as `SwiftyCrow-ventura-<sha>`.

## Translation on macOS 13–25

Apple's `Translation` framework cannot be driven outside SwiftUI before macOS
26, so those systems use Google Cloud Translation v2. The API key is entered in
Settings → Translation and stored in the login Keychain
(service `dev.PangMo5.SwiftyCrow.translation`); it is sent in the
`X-Goog-Api-Key` header, never in a URL or log. Without a key the app still
captures and recognises text and shows a hint pointing to Settings. The
language list comes from `/v2/languages` (cached) and falls back to a static
list that always includes Arabic. `translation.provider` in `config.toml`
selects `apple` (26+) or `google`.

## Known gaps on macOS 13

- No Apple document-layout recognition: paragraph grouping, alignment and
  vertical CJK detection are inferred from geometry (`VenturaOCRLayout`).
- `TranslationStrategy` (low latency / high fidelity) only affects Apple
  Translation; Google ignores it.
- Styled (attributed) translation alignment is Apple-only (macOS 26.4).
- Liquid Glass is approximated with `.ultraThinMaterial`.
