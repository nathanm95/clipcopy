import Foundation

enum ClipKind: Int {
    /// Plain text with no formatting.
    case text = 0
    /// Text that came with RTF and/or HTML formatting.
    case rich = 1
    case image = 2
    /// Files copied in Finder, stored as paths.
    case files = 3
}

/// A clipboard read that hasn't been saved yet.
struct CapturedClip {
    var kind: ClipKind
    var plain = ""
    var rtf: Data?
    var html: Data?
    var paths: [String] = []
    var imagePNG: Data?
    var thumbnailPNG: Data?
    var pixelWidth = 0
    var pixelHeight = 0
    var sourceApp: String?
}

/// What the menu needs to show one row. Formatting and image bytes stay on disk until a clip is used.
struct ClipSummary {
    let id: Int64
    let kind: ClipKind
    /// The first few hundred characters of the text, or the file names, one per line.
    let preview: String
    let characterCount: Int
    let paths: [String]
    let thumbnailFile: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let sourceApp: String?
    let copiedAt: Date
}

/// Everything needed to put a clip back on the clipboard.
struct StoredClip {
    let id: Int64
    let kind: ClipKind
    let plain: String
    let rtf: Data?
    let html: Data?
    let paths: [String]
    let imageURL: URL?
}
