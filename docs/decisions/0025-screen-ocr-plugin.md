# 0025. Screen OCR plugin

Status: Accepted
Date: 2026-10-22

## Context
The user asked for text and number recognition from the screen, like Raycast's Screen OCR extension: select an area, get its text on the clipboard. It must stay on the device (no network OCR).

What macOS offers:
- `/usr/sbin/screencapture -i` is the system's own area selection (⇧⌘4): drag an area, Space for a window, Esc to cancel, which writes no file. Seeing other apps' windows needs the Screen Recording permission, granted to QuickLaunch as the process that starts it; `CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess` check and ask for it.
- Vision's `VNRecognizeTextRequest` recognizes text on the device, detects the language (macOS 13+), and has an optional language correction that can turn digits into look-alike letters.

## Decision
- **A plugin module, `QLModuleOCR`** (id `ocr`, decision 0022), with one command, `ocr/text` ("Copy Text from Screen (OCR)"): the recognized lines, joined with newlines. Its title names the screen and OCR so both the launcher and the settings search find it.
  - A first version also had `ocr/numbers`, which kept only the numbers. The user chose one command (2026-10-22): text already includes the numbers, and mixed content shouldn't need a choice. Its one real benefit, recognizing without language correction (which can turn 0 into O), became an option.
- **Output goes through core** (decision 0003): the command defaults to `output: clipboard`, so the HUD says "Copied to clipboard", and a binding can choose `replace_selection` or `panel` instead. Nothing found is a failure ("no text found in that area"); Esc ends the run quietly.
- **Two internal adapters** (decision 0005), faked in tests: `ScreenCaptureTool` runs `screencapture -i -o -x <temp>.png` through `ProcessRunning` after checking the permission; `VisionTextRecognizer` runs Vision. The action deletes the screenshot when done.
- **Options:**
  - `ocr.languages`: one code or a list (`en-US`, `fr-FR`); default: detected automatically. Codes Vision doesn't support fail at run time with the supported list, since asking Vision isn't part of a pure config load.
  - `ocr.language_correction` (default true): false keeps digits from being "corrected" into letters, for number-heavy content.
- `scripts/lint-layers.sh` allows `Vision` in modules.
- **Namespace names** (a small core addition): Settings named a namespace's group by capitalizing it, so this one read "Ocr". `CommandCatalog.title(ofNamespace:)` now gives a plugin's own title ("Screen OCR", "Claude Code"), else the capitalized namespace; the settings page's groups and the launcher's kind labels both use it, replacing the app's `CommandKind`.

## Consequences
- Apart from namespace names, no core changes. The plugin is configured, tested and switched off like the others.
- The first use shows macOS's Screen Recording prompt; after allowing, QuickLaunch has to be reopened before macOS applies it.
- Not covered: a numbers-only filter (dropped, above), QR/barcode detection, and keeping a paragraph layout beyond Vision's lines. Barcodes would be another command in the same module (Vision's `VNDetectBarcodesRequest`).
