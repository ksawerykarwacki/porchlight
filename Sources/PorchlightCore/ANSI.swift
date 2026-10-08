import Foundation

/// Terminal escape handling. The `claude` CLI colours some output even when stdout is not a TTY.
public enum ANSI {
    /// Removes CSI sequences (colours, cursor movement), OSC sequences and two-byte escapes.
    public static func strip(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else {
                out.append(scalar)
                continue
            }
            guard let kind = scalars.next() else { break }
            switch kind {
            case "[":
                // CSI: parameters and intermediates, terminated by a byte in 0x40...0x7E.
                while let next = scalars.next() {
                    if (0x40...0x7E).contains(next.value) { break }
                }
            case "]":
                // OSC: terminated by BEL or ESC \.
                var previous: Unicode.Scalar = "]"
                while let next = scalars.next() {
                    if next == "\u{07}" || (previous == "\u{1B}" && next == "\\") { break }
                    previous = next
                }
            default:
                // Two-byte escape such as ESC 7 / ESC 8: both bytes are dropped.
                break
            }
        }
        return String(out)
    }
}
