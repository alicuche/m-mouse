import Carbon

/// Maps human-readable key names → CGKeyCode
enum KeyMapping {
    // swiftlint:disable:next cyclomatic_complexity
    static func keyCode(for name: String) -> CGKeyCode? {
        let lower = name.lowercased()

        // Single character a-z / 0-9 → look up via UCKeyboardLayout
        if lower.count == 1, let char = lower.unicodeScalars.first {
            return keyCodeFromChar(char)
        }

        switch lower {
        // Function keys
        case "f1":  return CGKeyCode(kVK_F1)
        case "f2":  return CGKeyCode(kVK_F2)
        case "f3":  return CGKeyCode(kVK_F3)
        case "f4":  return CGKeyCode(kVK_F4)
        case "f5":  return CGKeyCode(kVK_F5)
        case "f6":  return CGKeyCode(kVK_F6)
        case "f7":  return CGKeyCode(kVK_F7)
        case "f8":  return CGKeyCode(kVK_F8)
        case "f9":  return CGKeyCode(kVK_F9)
        case "f10": return CGKeyCode(kVK_F10)
        case "f11": return CGKeyCode(kVK_F11)
        case "f12": return CGKeyCode(kVK_F12)
        // Special keys
        case "return", "enter":    return CGKeyCode(kVK_Return)
        case "tab":                return CGKeyCode(kVK_Tab)
        case "space":              return CGKeyCode(kVK_Space)
        case "delete", "backspace":return CGKeyCode(kVK_Delete)
        case "escape", "esc":      return CGKeyCode(kVK_Escape)
        case "left":               return CGKeyCode(kVK_LeftArrow)
        case "right":              return CGKeyCode(kVK_RightArrow)
        case "up":                 return CGKeyCode(kVK_UpArrow)
        case "down":               return CGKeyCode(kVK_DownArrow)
        case "home":               return CGKeyCode(kVK_Home)
        case "end":                return CGKeyCode(kVK_End)
        case "pageup":             return CGKeyCode(kVK_PageUp)
        case "pagedown":           return CGKeyCode(kVK_PageDown)
        // Numpad
        case "kp0": return CGKeyCode(kVK_ANSI_Keypad0)
        case "kp1": return CGKeyCode(kVK_ANSI_Keypad1)
        case "kp2": return CGKeyCode(kVK_ANSI_Keypad2)
        case "kp3": return CGKeyCode(kVK_ANSI_Keypad3)
        case "kp4": return CGKeyCode(kVK_ANSI_Keypad4)
        case "kp5": return CGKeyCode(kVK_ANSI_Keypad5)
        case "kp6": return CGKeyCode(kVK_ANSI_Keypad6)
        case "kp7": return CGKeyCode(kVK_ANSI_Keypad7)
        case "kp8": return CGKeyCode(kVK_ANSI_Keypad8)
        case "kp9": return CGKeyCode(kVK_ANSI_Keypad9)
        default: return nil
        }
    }

    /// Parses a single modifier name OR a "+"-joined combo (e.g. "cmd+shift",
    /// "ctrl+option+shift"). Returns the combined CGEventFlags, or `nil` if
    /// any component is unknown.
    static func modifierFlag(for name: String) -> CGEventFlags? {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty || trimmed == "none" {
            return []
        }
        // Reject leading/trailing/double "+" (e.g. "command+", "+shift", "a++b")
        // — these usually indicate a config typo and silent acceptance hides it.
        if trimmed.hasPrefix("+") || trimmed.hasSuffix("+") || trimmed.contains("++") {
            return nil
        }
        var combined: CGEventFlags = []
        var seen: Set<String> = []
        for raw in trimmed.split(separator: "+") {
            let part = String(raw).trimmingCharacters(in: .whitespaces)
            // Reject duplicates ("command+command") and empty parts.
            if part.isEmpty { return nil }
            if !seen.insert(part).inserted { return nil }
            guard let flag = singleModifierFlag(for: part) else {
                return nil
            }
            combined.insert(flag)
        }
        return combined
    }

    private static func singleModifierFlag(for name: String) -> CGEventFlags? {
        switch name {
        case "control", "ctrl": return .maskControl
        case "option", "alt":   return .maskAlternate
        case "command", "cmd":  return .maskCommand
        case "shift":           return .maskShift
        default:                return nil
        }
    }

    private static func keyCodeFromChar(_ char: Unicode.Scalar) -> CGKeyCode? {
        charMap[Character(char)]
    }

    private static let charMap: [Character: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B),
            "c": CGKeyCode(kVK_ANSI_C), "d": CGKeyCode(kVK_ANSI_D),
            "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
            "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H),
            "i": CGKeyCode(kVK_ANSI_I), "j": CGKeyCode(kVK_ANSI_J),
            "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
            "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N),
            "o": CGKeyCode(kVK_ANSI_O), "p": CGKeyCode(kVK_ANSI_P),
            "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
            "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T),
            "u": CGKeyCode(kVK_ANSI_U), "v": CGKeyCode(kVK_ANSI_V),
            "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
            "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
            "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1),
            "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
            "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
            "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7),
            "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
            ";": CGKeyCode(kVK_ANSI_Semicolon),
            "'": CGKeyCode(kVK_ANSI_Quote),
            ",": CGKeyCode(kVK_ANSI_Comma),
            ".": CGKeyCode(kVK_ANSI_Period),
            "/": CGKeyCode(kVK_ANSI_Slash),
            "[": CGKeyCode(kVK_ANSI_LeftBracket),
            "]": CGKeyCode(kVK_ANSI_RightBracket),
            "\\": CGKeyCode(kVK_ANSI_Backslash),
            "`": CGKeyCode(kVK_ANSI_Grave),
            "-": CGKeyCode(kVK_ANSI_Minus),
            "=": CGKeyCode(kVK_ANSI_Equal),
        ]
}
