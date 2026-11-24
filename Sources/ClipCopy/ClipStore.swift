import CryptoKit
import Foundation
import SQLite3

/// The clipboard history: text and details in SQLite, images as PNG files next to it.
/// Only what the menu shows is ever read into memory.
final class ClipStore {
    enum StoreError: Error, CustomStringConvertible {
        case sql(String)
        var description: String {
            switch self {
            case .sql(let message): return message
            }
        }
    }

    static let defaultLimit = 1000

    let directory: URL
    let imagesDirectory: URL
    let limit: Int
    private var db: OpaquePointer?

    init(directory: URL, limit: Int = ClipStore.defaultLimit) throws {
        self.directory = directory
        self.limit = limit
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)

        // The history can hold anything that was copied, so only this user account can read it.
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imagesDirectory.path)

        let path = directory.appendingPathComponent("History.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open \(path)"
            sqlite3_close(db)
            throw StoreError.sql(message)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        try exec("""
            PRAGMA journal_mode = WAL;
            PRAGMA secure_delete = ON;
            PRAGMA cache_size = -512;
            CREATE TABLE IF NOT EXISTS clips (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                hash TEXT NOT NULL UNIQUE,
                kind INTEGER NOT NULL,
                plain TEXT NOT NULL DEFAULT '',
                rtf BLOB,
                html BLOB,
                paths TEXT NOT NULL DEFAULT '',
                image_file TEXT,
                thumbnail_file TEXT,
                width INTEGER NOT NULL DEFAULT 0,
                height INTEGER NOT NULL DEFAULT 0,
                source_app TEXT,
                copied_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS clips_copied_at ON clips (copied_at DESC);
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writing

    /// Saves a clip and returns its id. Copying something that's already in the history moves that
    /// clip to the top instead of adding a duplicate. Formatting is only ever added: copying the same
    /// words again as plain text keeps the formatting from before.
    @discardableResult
    func save(_ clip: CapturedClip, at date: Date = Date()) -> Int64? {
        let hash = Self.hash(of: clip)
        if let existing = id(forHash: hash) {
            if clip.rtf != nil || clip.html != nil {
                run("UPDATE clips SET copied_at = ?, source_app = ?, kind = ?, rtf = ?, html = ? WHERE id = ?",
                    [.double(date.timeIntervalSince1970), .text(clip.sourceApp), .int(Int64(ClipKind.rich.rawValue)),
                     .blob(clip.rtf), .blob(clip.html), .int(existing)])
            } else {
                run("UPDATE clips SET copied_at = ?, source_app = ? WHERE id = ?",
                    [.double(date.timeIntervalSince1970), .text(clip.sourceApp), .int(existing)])
            }
            return existing
        }

        var imageFile: String?
        var thumbnailFile: String?
        if clip.kind == .image, let png = clip.imagePNG {
            let name = UUID().uuidString
            imageFile = name + ".png"
            guard (try? png.write(to: imagesDirectory.appendingPathComponent(imageFile!))) != nil else { return nil }
            if let thumbnail = clip.thumbnailPNG {
                thumbnailFile = name + "-thumb.png"
                try? thumbnail.write(to: imagesDirectory.appendingPathComponent(thumbnailFile!))
            }
        }

        let saved = run("""
            INSERT INTO clips (hash, kind, plain, rtf, html, paths, image_file, thumbnail_file, width, height,
                               source_app, copied_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(hash), .int(Int64(clip.kind.rawValue)), .text(clip.plain), .blob(clip.rtf), .blob(clip.html),
             .text(clip.paths.joined(separator: "\n")), .text(imageFile), .text(thumbnailFile),
             .int(Int64(clip.pixelWidth)), .int(Int64(clip.pixelHeight)), .text(clip.sourceApp),
             .double(date.timeIntervalSince1970)])
        guard saved else {
            removeImageFiles([imageFile, thumbnailFile])
            return nil
        }
        let id = sqlite3_last_insert_rowid(db)
        trimToLimit()
        return id
    }

    /// Moves a clip to the top, for when ClipCopy itself has just put it back on the clipboard.
    func touch(_ id: Int64, at date: Date = Date()) {
        run("UPDATE clips SET copied_at = ? WHERE id = ?", [.double(date.timeIntervalSince1970), .int(id)])
    }

    func delete(_ id: Int64) {
        guard let statement = prepare("SELECT image_file, thumbnail_file FROM clips WHERE id = ?") else { return }
        statement.bind([.int(id)])
        if statement.step() {
            removeImageFiles([statement.text(0), statement.text(1)])
        }
        run("DELETE FROM clips WHERE id = ?", [.int(id)])
    }

    func clearAll() {
        run("DELETE FROM clips", [])
        try? exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        let files = (try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Reading

    func count() -> Int {
        guard let statement = prepare("SELECT count(*) FROM clips"), statement.step() else { return 0 }
        return Int(statement.int(0))
    }

    func recent(limit: Int) -> [ClipSummary] {
        summaries(where: "", [], limit: limit)
    }

    /// Clips whose text or file names contain `query`, newest first. Letters A–Z match either case.
    func search(_ query: String, limit: Int) -> [ClipSummary] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return summaries(where: "WHERE plain LIKE ? ESCAPE '\\'", [.text("%\(escaped)%")], limit: limit)
    }

    func load(_ id: Int64) -> StoredClip? {
        guard let statement = prepare("SELECT kind, plain, rtf, html, paths, image_file FROM clips WHERE id = ?")
        else { return nil }
        statement.bind([.int(id)])
        guard statement.step() else { return nil }
        return StoredClip(
            id: id,
            kind: ClipKind(rawValue: Int(statement.int(0))) ?? .text,
            plain: statement.text(1) ?? "",
            rtf: statement.blob(2),
            html: statement.blob(3),
            paths: Self.splitPaths(statement.text(4)),
            imageURL: statement.text(5).map { imagesDirectory.appendingPathComponent($0) })
    }

    private func summaries(where clause: String, _ values: [SQLValue], limit: Int) -> [ClipSummary] {
        guard let statement = prepare("""
            SELECT id, kind, substr(plain, 1, 300), length(plain), paths, thumbnail_file, width, height,
                   source_app, copied_at
            FROM clips \(clause) ORDER BY copied_at DESC LIMIT ?
            """) else { return [] }
        statement.bind(values + [.int(Int64(limit))])
        var result: [ClipSummary] = []
        while statement.step() {
            result.append(ClipSummary(
                id: statement.int(0),
                kind: ClipKind(rawValue: Int(statement.int(1))) ?? .text,
                preview: statement.text(2) ?? "",
                characterCount: Int(statement.int(3)),
                paths: Self.splitPaths(statement.text(4)),
                thumbnailFile: statement.text(5),
                pixelWidth: Int(statement.int(6)),
                pixelHeight: Int(statement.int(7)),
                sourceApp: statement.text(8),
                copiedAt: Date(timeIntervalSince1970: statement.double(9))))
        }
        return result
    }

    // MARK: - Helpers

    private func id(forHash hash: String) -> Int64? {
        guard let statement = prepare("SELECT id FROM clips WHERE hash = ?") else { return nil }
        statement.bind([.text(hash)])
        return statement.step() ? statement.int(0) : nil
    }

    /// Deletes the oldest clips, and their image files, beyond the history limit.
    private func trimToLimit() {
        guard let statement = prepare("""
            SELECT id, image_file, thumbnail_file FROM clips ORDER BY copied_at DESC LIMIT -1 OFFSET ?
            """) else { return }
        statement.bind([.int(Int64(limit))])
        var ids: [Int64] = []
        while statement.step() {
            ids.append(statement.int(0))
            removeImageFiles([statement.text(1), statement.text(2)])
        }
        for id in ids {
            run("DELETE FROM clips WHERE id = ?", [.int(id)])
        }
    }

    private func removeImageFiles(_ names: [String?]) {
        for name in names.compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(name))
        }
    }

    /// Text clips are matched on their words alone, so the same text copied with and without
    /// formatting counts as one clip.
    static func hash(of clip: CapturedClip) -> String {
        switch clip.kind {
        case .text, .rich: return "t:" + sha256(Data(clip.plain.utf8))
        case .files: return "f:" + sha256(Data(clip.paths.joined(separator: "\n").utf8))
        case .image: return "i:" + sha256(clip.imagePNG ?? Data())
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func splitPaths(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw StoreError.sql(message)
        }
    }

    private func prepare(_ sql: String) -> Statement? {
        do {
            return try Statement(db: db, sql: sql)
        } catch {
            NSLog("ClipCopy: \(error)")
            return nil
        }
    }

    @discardableResult
    private func run(_ sql: String, _ values: [SQLValue]) -> Bool {
        guard let statement = prepare(sql) else { return false }
        statement.bind(values)
        let ok = statement.run()
        if !ok {
            NSLog("ClipCopy: \(String(cString: sqlite3_errmsg(db)))")
        }
        return ok
    }
}

// MARK: - SQLite statement

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String?)
    case blob(Data?)
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class Statement {
    private var handle: OpaquePointer?

    init(db: OpaquePointer?, sql: String) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK else {
            throw ClipStore.StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ values: [SQLValue]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number):
                sqlite3_bind_int64(handle, index, number)
            case .double(let number):
                sqlite3_bind_double(handle, index, number)
            case .text(let text):
                if let text {
                    sqlite3_bind_text(handle, index, text, Int32(text.utf8.count), transient)
                } else {
                    sqlite3_bind_null(handle, index)
                }
            case .blob(let data):
                if let data, !data.isEmpty {
                    _ = data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), transient)
                    }
                } else {
                    sqlite3_bind_null(handle, index)
                }
            }
        }
    }

    /// Steps to the next row; false when there are no more.
    func step() -> Bool {
        sqlite3_step(handle) == SQLITE_ROW
    }

    /// Runs a statement that returns no rows.
    func run() -> Bool {
        let result = sqlite3_step(handle)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }

    func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    func blob(_ column: Int32) -> Data? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL,
              let pointer = sqlite3_column_blob(handle, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(handle, column)))
    }
}
