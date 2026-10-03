import CoreGraphics
import Foundation

/// The modifier keys held during a key press.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// The modifiers in a keyboard event's flags. Caps Lock and Fn are left out: arrows
    /// and F-keys report Fn on their own, and neither is part of a shortcut.
    public init(_ flags: CGEventFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        self = modifiers
    }

    /// The Mac symbols in the order Apple uses in menus: ⌃ ⌥ ⇧ ⌘.
    public var symbols: [String] {
        [(KeyModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { contains($0.0) }
            .map(\.1)
    }
}

/// One keyboard shortcut, such as ⇧⌘R.
public struct KeyShortcut: Codable, Hashable, Sendable {
    public var modifiers: KeyModifiers
    /// The key's name: a letter or symbol as printed on the key, or a word like "Return".
    public var key: String

    public init(modifiers: KeyModifiers, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// What the badge shows, for example "⇧ ⌘ R".
    public var label: String {
        (modifiers.symbols + [key]).joined(separator: " ")
    }

    /// The shortcut for a key press, or nil if it's ordinary typing that must never be
    /// logged. `characters` is only asked for once the press has passed that check, so
    /// what was typed is never even read.
    /// - Parameters:
    ///   - keyCode: The key's virtual key code.
    ///   - characters: What the key types with no modifiers, in the current layout.
    public static func logged(keyCode: UInt16, modifiers: KeyModifiers,
                              characters: () -> String?) -> KeyShortcut? {
        guard shouldLog(keyCode: keyCode, modifiers: modifiers) else { return nil }
        return KeyShortcut(modifiers: modifiers, key: KeyNames.name(keyCode: keyCode, characters: characters()))
    }

    /// Whether a key press is a shortcut worth showing rather than typing. Passwords and
    /// messages must never end up in a recording's log, so this lets through only:
    ///
    /// - anything pressed while Command or Control is held, which never types text;
    /// - keys that never type a character (Esc, Return, Tab, Delete, arrows, F-keys and
    ///   the like), alone or with Shift or Option, such as ⌥← to jump a word.
    ///
    /// Plain typing, Shift+letter and Option+letter (which types é, ©, and on many
    /// layouts @ or €) are never logged. Space alone is typing, so it isn't either.
    public static func shouldLog(keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
        if !modifiers.isDisjoint(with: [.command, .control]) { return true }
        return KeyNames.isNonTypingKey(keyCode)
    }
}

/// Readable names for keys, by virtual key code.
public enum KeyNames {
    /// Keys whose code means the same key on every layout, and that never type text.
    static let special: [UInt16: String] = [
        36: "Return", 76: "Enter", 48: "Tab", 51: "Delete", 117: "Forward Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 114: "Help",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// What each character key prints on a US keyboard, used when the event's own
    /// characters aren't usable (a dead key, or a control character).
    static let us: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
        // The number pad.
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        65: ".", 67: "*", 69: "+", 75: "/", 78: "-", 81: "=", 71: "Clear",
    ]

    static let space: UInt16 = 49

    /// A key that never types a character, so it's safe to log on its own.
    public static func isNonTypingKey(_ keyCode: UInt16) -> Bool {
        special[keyCode] != nil
    }

    /// The key's name for a badge: "Return", "←", "F5", or the character it types
    /// (capitalized, as printed on the key).
    /// - Parameter characters: What the key types with no modifiers in the current
    ///   layout, so shortcuts read right on non-US keyboards.
    public static func name(keyCode: UInt16, characters: String?) -> String {
        if let name = special[keyCode] { return name }
        if keyCode == space { return "Space" }
        if let characters, characters.count == 1, let scalar = characters.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar), !CharacterSet.whitespacesAndNewlines.contains(scalar),
           !CharacterSet.nonBaseCharacters.contains(scalar) {
            return characters.uppercased()
        }
        return us[keyCode] ?? "Key \(keyCode)"
    }
}

/// The keyboard shortcuts pressed during a recording, on the video's own timeline.
/// Pane saves it with the recording, like the pointer, so badges can be added at export.
public struct ShortcutTrack: Codable, Sendable, Equatable {
    public struct Press: Codable, Sendable, Equatable {
        /// Seconds into the video.
        public var time: Double
        public var shortcut: KeyShortcut

        public init(time: Double, shortcut: KeyShortcut) {
            self.time = time
            self.shortcut = shortcut
        }
    }

    /// Sorted by time.
    public var presses: [Press]
    /// The camera circle (normalized, bottom-left origin), which badges keep clear of.
    public var cameraCircle: CGRect?

    public init(presses: [Press], cameraCircle: CGRect?) {
        self.presses = presses.sorted { $0.time < $1.time }
        self.cameraCircle = cameraCircle
    }
}

// MARK: - Saving with the video

extension ShortcutTrack {
    /// Stored in its own extended attribute next to the pointer's, so it travels with
    /// the file and older versions of Pane simply ignore it.
    static let attributeName = "com.jacobhokanson.pane.keys"

    public func save(to url: URL) throws {
        let json = try JSONEncoder().encode(self)
        let data = try (json as NSData).compressed(using: .lzfse) as Data
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, Self.attributeName, bytes.baseAddress, bytes.count, 0, 0)
        }
        if result != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    /// The shortcuts recorded with `url`, or nil if none were recorded.
    public static func load(from url: URL) -> ShortcutTrack? {
        let size = getxattr(url.path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, attributeName, bytes.baseAddress, size, 0, 0)
        }
        guard read == size,
              let json = try? (data as NSData).decompressed(using: .lzfse) as Data
        else { return nil }
        return try? JSONDecoder().decode(ShortcutTrack.self, from: json)
    }
}
