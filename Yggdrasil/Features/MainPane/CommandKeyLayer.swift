import Carbon.HIToolbox
import Foundation

/// A keyboard layout's Command layer: what each key types while ⌘ is held.
/// ⌘ shortcuts resolve against this layer, and it can differ from what the
/// key types on its own — Hebrew mirrors the brackets, "Dvorak - QWERTY ⌘"
/// switches to QWERTY.
struct CommandKeyLayer {
    private let layoutData: Data

    init?(source: TISInputSource) {
        let data: Data? = withExtendedLifetime(source) {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        }
        guard let data else { return nil }
        layoutData = data
    }

    /// The active layout, or nil when it can't be read.
    static func current() -> CommandKeyLayer? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return CommandKeyLayer(source: source)
    }

    /// What the key types with ⌘ held, or nil for a dead or non-printing key.
    func character(keyCode: UInt16) -> String? {
        layoutData.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeys, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// True when some key types `[` and some key types `]` on this layer.
    var typesBrackets: Bool {
        let typed = Set((UInt16(0) ..< 128).compactMap { character(keyCode: $0) })
        return typed.contains("[") && typed.contains("]")
    }
}
