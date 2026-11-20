import Foundation
import SQLite3

/// SQLite3 Swift 模块不导出的析构器常量。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 分析结果索引（SQLite）。指令不落库，只存函数/xref/字符串/伪代码/注释。
final class REIndex {
    private var db: OpaquePointer?
    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let db else {
            throw REError.message("无法创建分析索引数据库。")
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS functions(addr INTEGER PRIMARY KEY, name TEXT, end_addr INTEGER, from_symbols INTEGER);
        CREATE TABLE IF NOT EXISTS xrefs(from_addr INTEGER, to_addr INTEGER, kind TEXT);
        CREATE TABLE IF NOT EXISTS strings(addr INTEGER PRIMARY KEY, text TEXT);
        CREATE TABLE IF NOT EXISTS pseudocode(addr INTEGER PRIMARY KEY, text TEXT, ts INTEGER);
        CREATE TABLE IF NOT EXISTS comments(addr INTEGER PRIMARY KEY, text TEXT);
        CREATE INDEX IF NOT EXISTS idx_xrefs_to ON xrefs(to_addr);
        CREATE INDEX IF NOT EXISTS idx_xrefs_from ON xrefs(from_addr);
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - 基础执行

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func failed() -> Bool {
        sqlite3_errcode(db) != SQLITE_OK
    }

    // MARK: - 元信息

    func setMeta(_ key: String, value: String) {
        let sql = "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)"
        prepare(sql) { statement in
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(statement)
        }
    }

    func meta(_ key: String) -> String? {
        let sql = "SELECT value FROM meta WHERE key = ?"
        var result: String?
        prepare(sql) { statement in
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                result = String(cString: text)
            }
        }
        return result
    }

    // MARK: - 函数

    func saveFunctions(_ functions: [REFunction]) {
        exec("BEGIN")
        let sql = "INSERT OR REPLACE INTO functions(addr, name, end_addr, from_symbols) VALUES(?, ?, ?, ?)"
        prepare(sql) { statement in
            for function in functions {
                sqlite3_bind_int64(statement, 1, Int64(bitPattern: function.addr))
                sqlite3_bind_text(statement, 2, (function.name as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(statement, 3, Int64(bitPattern: function.end))
                sqlite3_bind_int64(statement, 4, function.fromSymbols ? 1 : 0)
                sqlite3_step(statement)
                sqlite3_reset(statement)
            }
        }
        exec("COMMIT")
    }

    func functions() -> [REFunction] {
        var result: [REFunction] = []
        prepare("SELECT addr, name, end_addr, from_symbols FROM functions ORDER BY addr") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let addr = UInt64(bitPattern: sqlite3_column_int64(statement, 0))
                let name = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                let end = UInt64(bitPattern: sqlite3_column_int64(statement, 2))
                let fromSymbols = sqlite3_column_int64(statement, 3) == 1
                result.append(REFunction(addr: addr, name: name, end: end, fromSymbols: fromSymbols))
            }
        }
        return result
    }

    func renameFunction(addr: UInt64, name: String) {
        let sql = "UPDATE functions SET name = ? WHERE addr = ?"
        prepare(sql) { statement in
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 2, Int64(bitPattern: addr))
            sqlite3_step(statement)
        }
    }

    // MARK: - 交叉引用

    func saveXrefs(_ xrefs: [REXref]) {
        exec("BEGIN")
        let sql = "INSERT OR IGNORE INTO xrefs(from_addr, to_addr, kind) VALUES(?, ?, ?)"
        prepare(sql) { statement in
            for xref in xrefs {
                sqlite3_bind_int64(statement, 1, Int64(bitPattern: xref.from))
                sqlite3_bind_int64(statement, 2, Int64(bitPattern: xref.to))
                sqlite3_bind_text(statement, 3, (xref.kind.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_step(statement)
                sqlite3_reset(statement)
            }
        }
        exec("COMMIT")
    }

    func xrefs(to addr: UInt64) -> [REXref] {
        var result: [REXref] = []
        prepare("SELECT from_addr, to_addr, kind FROM xrefs WHERE to_addr = ? ORDER BY from_addr") { statement in
            sqlite3_bind_int64(statement, 1, Int64(bitPattern: addr))
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(Self.xref(from: statement))
            }
        }
        return result
    }

    func xrefs(from addr: UInt64) -> [REXref] {
        var result: [REXref] = []
        prepare("SELECT from_addr, to_addr, kind FROM xrefs WHERE from_addr = ? ORDER BY to_addr") { statement in
            sqlite3_bind_int64(statement, 1, Int64(bitPattern: addr))
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(Self.xref(from: statement))
            }
        }
        return result
    }

    private static func xref(from statement: OpaquePointer) -> REXref {
        let from = UInt64(bitPattern: sqlite3_column_int64(statement, 0))
        let to = UInt64(bitPattern: sqlite3_column_int64(statement, 1))
        let kind = sqlite3_column_text(statement, 2).map { REXrefKind(rawValue: String(cString: $0)) ?? .data } ?? .data
        return REXref(from: from, to: to, kind: kind)
    }

    // MARK: - 字符串

    func saveStrings(_ strings: [REString]) {
        exec("BEGIN")
        let sql = "INSERT OR REPLACE INTO strings(addr, text) VALUES(?, ?)"
        prepare(sql) { statement in
            for entry in strings {
                sqlite3_bind_int64(statement, 1, Int64(bitPattern: entry.addr))
                sqlite3_bind_text(statement, 2, (entry.text as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_step(statement)
                sqlite3_reset(statement)
            }
        }
        exec("COMMIT")
    }

    func strings() -> [REString] {
        var result: [REString] = []
        prepare("SELECT addr, text FROM strings ORDER BY addr") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                let addr = UInt64(bitPattern: sqlite3_column_int64(statement, 0))
                let text = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                result.append(REString(addr: addr, text: text))
            }
        }
        return result
    }

    // MARK: - 伪代码与注释

    func savePseudocode(addr: UInt64, text: String) {
        let sql = "INSERT OR REPLACE INTO pseudocode(addr, text, ts) VALUES(?, ?, ?)"
        prepare(sql) { statement in
            sqlite3_bind_int64(statement, 1, Int64(bitPattern: addr))
            sqlite3_bind_text(statement, 2, (text as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 3, Int64(Date().timeIntervalSince1970))
            sqlite3_step(statement)
        }
    }

    func pseudocode(addr: UInt64) -> String? {
        var result: String?
        prepare("SELECT text FROM pseudocode WHERE addr = ?") { statement in
            sqlite3_bind_int64(statement, 1, Int64(bitPattern: addr))
            if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                result = String(cString: text)
            }
        }
        return result
    }

    func setComment(addr: UInt64, text: String?) {
        if let text {
            let sql = "INSERT OR REPLACE INTO comments(addr, text) VALUES(?, ?)"
            prepare(sql) { statement in
                sqlite3_bind_int64(statement, 1, Int64(bitPattern: addr))
                sqlite3_bind_text(statement, 2, (text as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_step(statement)
            }
        } else {
            prepare("DELETE FROM comments WHERE addr = ?") { statement in
                sqlite3_bind_int64(statement, 1, Int64(bitPattern: addr))
                sqlite3_step(statement)
            }
        }
    }

    func comment(addr: UInt64) -> String? {
        var result: String?
        prepare("SELECT text FROM comments WHERE addr = ?") { statement in
            sqlite3_bind_int64(statement, 1, Int64(bitPattern: addr))
            if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                result = String(cString: text)
            }
        }
        return result
    }

    // MARK: - 内部

    private func prepare(_ sql: String, _ body: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return
        }
        defer { sqlite3_finalize(statement) }
        body(statement)
        if failed() {
            exec("ROLLBACK")
        }
    }
}
