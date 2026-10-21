import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Turns a key press into the text it types with the current keyboard layout, from its
/// key code and modifier flags, the way apps interpret it (decision 0015). The text a
/// `CGEvent` carries can disagree with its own flags: an event posted right after a
/// shifted one may carry uppercase text while the app types lowercase.
///
/// The layout is read on the main thread (Text Input Sources require it) and again
/// whenever the input source changes; translating is safe on the event tap thread.
final class KeyboardLayout: Sendable {
    /// `UCKeyboardLayout` data of the current input source; nil if it has none (some
    /// input methods), in which case the event's own text is used.
    private let layout = OSAllocatedUnfairLock<Data?>(initialState: nil)
    /// Dead-key state between presses (e.g. ⌥E then E types é). Only the tap thread uses it.
    private let deadKeyState = OSAllocatedUnfairLock<UInt32>(initialState: 0)

    @MainActor
    init() {
        reload()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    @MainActor
    private func reload() {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let data = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }
            .map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() as Data }
        layout.withLock { $0 = data }
        deadKeyState.withLock { $0 = 0 }
    }

    /// The text `keyCode` types with `flags`, or nil if the layout can't say.
    func characters(keyCode: UInt16, flags: CGEventFlags) -> String? {
        guard let data = layout.withLock({ $0 }) else { return nil }
        // UCKeyTranslate takes the Carbon modifier bits shifted down by 8.
        var modifiers: UInt32 = 0
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey >> 8) }
        if flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock >> 8) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey >> 8) }
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey >> 8) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey >> 8) }

        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        var state = deadKeyState.withLock { $0 }
        let status = data.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                0, &state, buffer.count, &length, &buffer
            )
        }
        let newState = state
        deadKeyState.withLock { $0 = newState }
        guard status == noErr else { return nil }
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }
}
