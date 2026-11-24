import Foundation

/// What the plain-text (T) button does to a clip's text, beyond dropping its formatting.
enum TextTidy {
    /// Swaps look-alike spaces for ordinary ones and removes invisible characters. These are what
    /// turn into "?" or odd gaps when text from Word or a web page is pasted into plain-text fields.
    /// Line breaks, tabs and quotes are kept as they are. Zero-width joiners are kept too, because
    /// emoji such as 👨‍👩‍👧 and some scripts need them.
    static func plain(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            // No-break, ogham, en/em/thin/hair and other fixed-width, narrow no-break, medium
            // mathematical and ideographic spaces.
            case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
                scalars.append(" ")
            // Zero-width space, word joiner, byte order mark, soft hyphen, Mongolian vowel separator.
            case 0x200B, 0x2060, 0xFEFF, 0x00AD, 0x180E:
                continue
            // Unicode line and paragraph separators become ordinary line breaks.
            case 0x2028, 0x2029:
                scalars.append("\n")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
