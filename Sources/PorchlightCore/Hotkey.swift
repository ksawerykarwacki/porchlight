import Foundation

/// A keyboard shortcut that works from any app: one key plus modifiers.
public struct Hotkey: Codable, Sendable, Equatable {
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)

        /// In the order macOS writes them.
        static let named: [(Modifiers, name: String, symbol: String)] = [
            (.control, "control", "⌃"), (.option, "option", "⌥"), (.shift, "shift", "⇧"), (.command, "command", "⌘"),
        ]
    }

    /// The key's hardware code (a virtual key code on macOS). This is what is registered.
    public var keyCode: Int
    public var modifiers: Modifiers
    /// What the key types, for display, as seen when the shortcut was recorded. Keys with names
    /// (Space, Return, F5, the arrows) are shown by name instead.
    public var character: String?

    /// The shortcut offered with one click: ⌃⌥⌘N. Three modifiers and a letter is a combination
    /// other apps almost never use, and it is only registered when the user asks for it.
    public static let suggested = Hotkey(keyCode: 45, modifiers: [.control, .option, .command], character: "n")

    public init(keyCode: Int, modifiers: Modifiers, character: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.character = character
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, character
    }

    /// Stored with the modifiers by name, so the settings file can be read and written by hand.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(Int.self, forKey: .keyCode)
        let names = try c.decode([String].self, forKey: .modifiers)
        modifiers = Modifiers(Modifiers.named.filter { names.contains($0.name) }.map(\.0))
        character = try? c.decodeIfPresent(String.self, forKey: .character)
        guard isUsable else {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: c, debugDescription: "a shortcut needs Control, Option or Command")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(Modifiers.named.filter { modifiers.contains($0.0) }.map(\.name), forKey: .modifiers)
        try c.encodeIfPresent(character, forKey: .character)
    }

    /// A shortcut must not swallow ordinary typing: a key alone, or with only Shift, would. The
    /// function keys are the exception, since they type nothing.
    public var isUsable: Bool {
        guard (0...127).contains(keyCode) else { return false }
        if !modifiers.isDisjoint(with: [.control, .option, .command]) { return true }
        return Self.functionKeys.contains(keyCode)
    }

    /// The shortcut as macOS writes it: "⌃⌥Space", "⇧⌘N", "F6".
    public var display: String {
        Modifiers.named.filter { modifiers.contains($0.0) }.map(\.symbol).joined() + keyName
    }

    public var keyName: String {
        if let name = Self.keyNames[keyCode] { return name }
        if let character, !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return character.uppercased() }
        return "Key \(keyCode)"
    }

    static let functionKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// Keys shown by name rather than by what they type. The codes are the same on every Mac keyboard.
    static let keyNames: [Int: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Delete", 117: "Forward Delete", 53: "Escape",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
