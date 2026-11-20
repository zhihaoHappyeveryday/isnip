<div align="center">
  <img src="Assets/icon.png" width="112" height="112" alt="iSnip Icon" />
  <h1>iSnip</h1>
  <p><strong>Fast, lightweight native macOS screenshot, annotation, smart lossless compression, offline OCR &amp; translation utility</strong></p>
  <p>
    <a href="https://github.com/zhihaoHappyeveryday/isnip/releases/latest"><img src="https://img.shields.io/github/v/release/zhihaoHappyeveryday/isnip?label=Release&color=0A84FF" alt="Latest Release" /></a>
    <img src="https://img.shields.io/badge/macOS-14.0%2B-111827" alt="macOS 14.0+" />
    <img src="https://img.shields.io/badge/Arch-arm64%20%7C%20amd64-0F766E" alt="arm64 | amd64" />
    <img src="https://img.shields.io/badge/Swift-5.10-F05138" alt="Swift 5.10" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue" alt="License GPL-3.0" /></a>
  </p>
  <p>
    <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
  </p>
</div>

---

**iSnip** is built 100% in native Swift (`AppKit` · `ScreenCaptureKit` · `CoreGraphics` · `Vision` · `Translation`) with zero Electron or WebView runtime overhead and **0% idle CPU** in the menu bar. It ships out-of-the-box with a bundled `pngquant + oxipng` dual-engine lossless compression pipeline, on-device offline OCR, and native selection/screenshot translation—combining pixel-accurate annotation with an unobtrusive minimalist interface (`English` / `简体中文` live switching).

## Key Features

- **Zero-Jitter Instant Screen Freeze & Isolated Window Capture (`⌃A` / `⌃S` / `Space`)**
  - Freezes the screen instantly at original brightness (`⌃A`) without dimming flash or scaling jitter; equipped with an `11×11` optical pixel loupe, live dimension readout, and `#HEX` / `RGB` color picker (`C` / `⇧C`).
  - **Isolated Window Capture**: Trigger via menu bar, global shortcut `⌃S`, or press **`Space`** before dragging a selection. Powered by `ScreenCaptureKit` (`desktopIndependentWindow`), it **captures the target window cleanly even when partially occluded by other windows**, preserving transparent rounded corners and native macOS drop shadows (`⌥`+Click or Settings toggle for shadowless capture; `Tab` cycles through overlapping windows).
- **Bundled `pngquant + oxipng` Smart Lossless Compression (On by Default)**
  - Ships standalone `pngquant --speed 1` and `oxipng -o max --strip safe` binaries inside the app bundle—zero CLI setup required.
  - Shrinks typical `1.2 MB` Retina screenshots down to `0.3–0.4 MB` (`60%–75%` smaller) with virtually indistinguishable visual quality across three presets (**Visually Lossless / Balanced / High Compression**).
  - **Zero-Wait Dual-Stage Pipeline**: Both clipboard copy (`Enter`) and local save (`⌘S`) write uncompressed pixels in `0 ms` and atomically swap in the compressed PNG in the background without blocking the UI.
- **Silent Direct Save (No Save-Dialog Interruption)**
  - Clicking Save (`↓`) or pressing `⌘S` saves straight to `~/Downloads` (or your custom folder) with automatic collision-safe numbering; press `⇧⌘S` or `⌥`+Click Save anytime for **Save As…**.
- **Minimalist Floating Toolbar & 10 Vector Annotation Tools**
  - Clean neutral floating bar with on-demand stroke width, font size, palette swatches, and continuous HSV color picker; all 24 toolbar slots can be individually shown or hidden.
  - Includes **Rectangle (adjustable corner radius), Ellipse, Line, Cubic Bézier / Straight Arrow, Smooth Freehand Pen, 3-Pass Box Gaussian Blur, Native CJK/Latin Text, Auto-Increment Step Callout, Spotlight Dimming, and Multiply Highlighter**, all supporting post-draw drag/resize and 100-step undo/redo.
- **Scrolling Capture / Long Screenshot (`⌃D` / `S`)**
  - Start directly via `⌃D` (drag a region or click a window) for **smooth automatic scrolling & stitching**, or press `S` inside an active capture.
  - Built-in non-inertial pixel scroll driver, feature-row peak matching (resilient to sparse whitespace and dynamic scrollbars, with center-column fallback for fixed-sidebar layouts), automatic sticky header/footer stripping, and **automatic bottom-of-page stop detection**; supports `Space` pause/resume, 3 scroll speeds, manual scroll-wheel top-up, and `⌘Z` segment undo.
- **Pin to Screen (`F3` / `⌃F3`)**
  - Float any capture or clipboard image always-on-top for side-by-side reference; supports cursor-centered scroll zoom, `⌘`/`⌃` + scroll opacity control, subtle border toggle, click-through mode, and pressing `Space` to annotate in place.
  - Pin clipboard text with its original spacing and line breaks. From a text pin, use `⌘⇧C` or **Copy Original Text** to copy the text, and `⌘C` to copy the current image.
  - Press `F3` without new clipboard content to restore the most recently closed pin that can be read, including pins from previous launches. **Settings → Capture → Recoverable Pins** defaults to 20 and adjusts from 0 to 50 in steps of 5. Setting it to 0 clears and disables pin history.
  - Use **Settings → About → Pin History Directory** to open the history folder or choose another one. iSnip saves closed pins in `YYYY-MM-DD` folders inside `iSnip Pin History` under the screenshot save location by default. If you choose a folder, iSnip puts the dated folders directly inside it.
- **100% Offline On-Device Vision OCR & QR Code Detection (`⌃F` / `T`)**
  - Extract text directly from screen regions (`⌃F`), active captures (`T`), pinned images (`T`), tall scrolling captures, clipboard images, or local image files (`Recognize Image File…`).
  - Supports multi-language switching (`Auto` / `Simplified Chinese` / `Traditional Chinese` / `English` / `Japanese` / `Korean`), smart soft line-break merging, and one-click QR URL opening—**100% local inference, images never leave your Mac**.
- **Selection Translation & Capture Translation (macOS 15+)**
  - Select text in any app and press `⌥D` to open the source/translation floating panel (or enable the optional **Show Floating Translate Button** in `Settings → OCR & Translate`).
  - Press `⌥S` to capture a screen region, run OCR, and translate automatically; any OCR result window can also switch into translation in one click.
  - Powered by Apple's built-in `Translation` framework with **no API keys required**. Supports editable source text (`⌘Enter` to retranslate), target language switching, `⇧⌘C` to copy the translation, and `Esc` to dismiss. Reads accessible selection text only without simulating `⌘C` or touching your clipboard.

## Installation

### Option 1: Download Prebuilt DMG (Recommended)

1. Download the matching DMG from **[GitHub Releases](https://github.com/zhihaoHappyeveryday/isnip/releases/latest)**:
   - **Apple Silicon (`M1` / `M2` / `M3` / `M4` / `M5`)**: `isnip-macos-arm64-v*.dmg`
   - **Intel / AMD (`x86_64`) Mac**: `isnip-macos-amd64-v*.dmg`
2. Open the DMG and drag **iSnip.app** into `/Applications`.
3. If macOS Gatekeeper blocks the first launch, clear the quarantine attribute once in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/iSnip.app
   ```
4. On your first capture, grant **iSnip** permission in **System Settings → Privacy & Security → Screen & System Audio Recording**.

### Option 2: Build & Install from Source

Requirements: **macOS 14.0+** (`arm64` or `x86_64`) and **Xcode Command Line Tools (Swift 5.10+)**.

```sh
git clone https://github.com/zhihaoHappyeveryday/isnip.git
cd isnip
sh scripts/install-local.sh --no-pull
```

## Default Keyboard Shortcuts

> Every global shortcut, in-capture action key, and annotation tool key can be customized or unbound in **Settings → Shortcuts**.

| Scope | Shortcut | Action |
| :--- | :--- | :--- |
| **Global** | `⌃A` | Capture Area (press `Space` before dragging to switch to Window Capture) |
| **Global** | `⌃S` | Capture Window (`⌥`+Click toggles window shadow; `Tab` cycles stacked windows) |
| **Global** | `⌃D` | Scrolling Capture (select region or window to auto-scroll & stitch) |
| **Global** | `⌃F` | Capture & OCR |
| **Global** | `⌥D` / `⌥S` | Translate Selection / Capture & Translate (macOS 15+) |
| **Global** | `F3` / `⌃F3` | Pin or Restore / Toggle All Pin Borders |
| **Selection & Output** | `Enter` / Double-Click | Copy capture to clipboard and finish |
| **Selection & Output** | `⌘S` / `⇧⌘S` | Silent save to default folder / Save As… |
| **Selection & Output** | `S` / `T` | Start Scrolling Capture (`Space` pause/resume, `Enter` save & copy) / OCR selection |
| **Color Picker** | `C` / `⇧C` | Copy pixel `#HEX` / `RGB` value under cursor |
| **Nudge & Recapture** | `⌥ + Arrow Keys` (`⇧` for 5 px) | Pixel-nudge selection size; `⇧F1` recaptures screen |
| **Annotations** | `1` – `0` | Switch among the 10 vector annotation tools |
| **Annotations** | `⌘Z` / `⇧⌘Z` / `Delete` | Undo / Redo / Delete selected annotation |
| **Pinned Image** | `Space` / `T` / `Esc` | Annotate in place / OCR pin / Close pin |
| **Pinned Image** | `Scroll` / `⌘ + Scroll` | Smooth zoom / Adjust pin opacity |

## Repository Structure

```text
isnip/
├── Package.swift          # SwiftPM manifest (AirSnipCore library + iSnip executable)
├── Info.plist             # App bundle metadata, version & privacy usage descriptions
├── Assets/                # App icons & bundled static resources
├── Sources/
│   ├── AirSnipCore/       # Core engine: vector annotations, PNG/WebP codecs & compression, longshot stitcher, Vision OCR, L10n
│   └── AirSnipApp/        # Native UI: zero-jitter capture overlay, minimalist design system, pin windows, OCR/translation panel, settings
├── Tests/
│   └── AirSnipCoreTests/  # Unit tests for annotations, compression, longshot stitching, OCR layout & config migrations
├── Vendor/                # Bundled standalone compression binaries (pngquant / oxipng & dylibs)
└── scripts/               # Build, code-signing, end-to-end smoke test, release policy, local install & GitHub Release scripts
```

## Local Development & Verification

```sh
# 1. Build iSnip.app, verify code signature & bundled helpers, and run 7 end-to-end smoke checks
sh scripts/test-app-smoke.sh

# 2. Run core unit tests & release policy verification
swift test
python3 scripts/test-release-policy.py

# 3. Run translation self-test (uses installed language packs only)
dist/iSnip.app/Contents/MacOS/iSnip --translation-self-test

# 4. Build and install into /Applications/iSnip.app
sh scripts/install-local.sh --no-pull
```

## Privacy & License

- **Zero Telemetry**: Screen capture, vector annotation, PNG/WebP compression, and Vision OCR / QR recognition run **100% offline on your Mac** (network access is only used when checking GitHub Releases for updates).
- **System Translation**: Powered by macOS's native `Translation` framework; language pack downloads are managed by macOS. Floating selection button is off by default and only reads accessible selection text when enabled.
- **Acknowledgements**: Inspired by [Easydict](https://github.com/tisfeng/Easydict)'s Accessibility text selection, Vision OCR, and Apple Translation integration, implemented directly on Apple system frameworks without external dependencies.
- **License**: Source code is licensed under [GPL-3.0-only](LICENSE); bundled helper binaries follow their respective open-source licenses (`pngquant` GPL-3.0, `oxipng` MIT).

---

<div align="center">
  Community &amp; Feedback: <a href="https://linux.do"><strong>LINUX DO</strong></a>
</div>
