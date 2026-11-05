import Foundation
import SQLite3

/// Access to databases that other processes own (TCC, browsers).
public enum SQLite {
    /// Rows as column name → text value (NULL columns are left out), or nil when the database can't be read.
    /// The file and its WAL are copied into a temporary folder first, so the original is never locked or written.
    /// A database or WAL that is a symbolic link is refused: copying would copy the link and open the target.
    public static func rows(_ db: URL, _ sql: String) -> [[String: String]]? {
        let fm = FileManager.default
        let wal = URL(fileURLWithPath: db.path + "-wal")
        guard isRegularFile(db.path), !isSymlink(wal.path) else { return nil }
        let dir = fm.temporaryDirectory.appendingPathComponent("vc-sqlite-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(db.lastPathComponent)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: db, to: copy)
            if fm.fileExists(atPath: wal.path) { try fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }
        } catch { return nil }

        var handle: OpaquePointer?
        // Read only, on the copy; the schema of a foreign database is not trusted (no functions run from views or triggers).
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(handle); return nil }
        defer { sqlite3_close(handle) }
        sqlite3_exec(handle, "PRAGMA trusted_schema=OFF;", nil, nil, nil)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var out: [[String: String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                guard let text = sqlite3_column_text(stmt, i) else { continue }
                row[String(cString: sqlite3_column_name(stmt, i))] = String(cString: text)
            }
            out.append(row)
        }
        return out
    }

    /// Runs `sql` in one transaction on the database itself. Only for execution, never during a scan;
    /// the owning app must be closed.
    public static func execute(_ db: URL, _ sql: String) throws {
        guard isRegularFile(db.path) else { throw RemovalError.failed(db.path, "base illisible") }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw RemovalError.failed(db.path, "base illisible")
        }
        sqlite3_exec(handle, "PRAGMA trusted_schema=OFF;", nil, nil, nil)
        sqlite3_busy_timeout(handle, 5000)
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE; \(sql) COMMIT;", nil, nil, &message) == SQLITE_OK else {
            let why = message.map { String(cString: $0) } ?? "erreur SQLite"
            sqlite3_free(message)
            sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            throw RemovalError.failed(db.path, why)
        }
    }

    static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }
}
