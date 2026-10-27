import Foundation
import SQLite3

/// C 侧的 SQLITE_TRANSIENT 宏在 Swift 模块里没有定义，铸一个等价的（-1）。
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 扫描快照与流速（PR-2）
//
// 设计出处：plans/design-diagnostic-dumps-velocity-provenance-2026-10-27.md §4，
// 评审修订 plans/design-review-diagnostic-dumps-2026-10-27.md §2.1：
// · 无守护进程——快照写在类别发现遍历流程内，两次扫描之间的事在下次扫描结算；
// · 告警 OR（绝对量或速率任一命中），徽标分两档：速率命中红「流速异常」、
//   仅绝对量命中黄「显著增长」——不能改成 AND，否则一周没开 app 回来看到
//   +105G 会因均摊速率低而漏报，那恰是事故形态；
// · 基线 = 距今 ≥10 分钟的上一次扫描（连扫两次 30 秒间隔不重置基线），
//   异常粘滞到增长回落（Δ≤0）为止，红徽标不因快速重扫消失。

/// 一次扫描为一个条目记的一行。
public struct ScanSnapshot: Equatable {
    public let entryKey: String
    public let scanID: String
    public let wallTime: Date
    public let bytes: Int64
    public let fileCount: Int
    public let newestMtime: Date?

    public init(entryKey: String, scanID: String, wallTime: Date,
                bytes: Int64, fileCount: Int, newestMtime: Date?) {
        self.entryKey = entryKey
        self.scanID = scanID
        self.wallTime = wallTime
        self.bytes = bytes
        self.fileCount = fileCount
        self.newestMtime = newestMtime
    }
}

/// 流速告警阈值。默认值拍法：事故 ≈ 4,760 个/分钟（红档），周末两天攒 500MB
/// ≈ 0.17MB/分钟（够不着红档，落黄档或不响）——两档之间隔四个量级，阈值很好放。
public struct VelocityThresholds: Equatable {
    public var files: Int
    public var bytes: Int64
    public var filesPerMinute: Double
    public var bytesPerMinute: Int64

    public init(files: Int = 1_000, bytes: Int64 = 500 * 1_000 * 1_000,
                filesPerMinute: Double = 100, bytesPerMinute: Int64 = 50 * 1_000 * 1_000) {
        self.files = files
        self.bytes = bytes
        self.filesPerMinute = filesPerMinute
        self.bytesPerMinute = bytesPerMinute
    }

    public static let `default` = VelocityThresholds()
}

public enum VelocityTier: Equatable {
    /// 速率命中：突发型增长（红）
    case red
    /// 仅绝对量命中：长间隔累积（黄）
    case yellow
}

public struct VelocityReport: Equatable {
    public let deltaFiles: Int
    public let deltaBytes: Int64
    public let intervalSeconds: Double
    public let tier: VelocityTier?

    public var filesPerMinute: Double {
        intervalSeconds > 0 ? Double(deltaFiles) * 60.0 / intervalSeconds : 0
    }

    public var bytesPerMinute: Int64 {
        intervalSeconds > 0 ? Int64(Double(deltaBytes) * 60.0 / intervalSeconds) : 0
    }

    /// 纯计算：两次快照的差 → 两档判定。Δ≤0（清理过或没变）一律不告警。
    public static func compute(current: ScanSnapshot, baseline: ScanSnapshot,
                               thresholds: VelocityThresholds = .default) -> VelocityReport {
        let interval = current.wallTime.timeIntervalSince(baseline.wallTime)
        let df = current.fileCount - baseline.fileCount
        let db = current.bytes - baseline.bytes
        guard interval > 0, df > 0 || db > 0 else {
            return VelocityReport(deltaFiles: df, deltaBytes: db, intervalSeconds: max(0, interval), tier: nil)
        }
        let rate = VelocityReport(deltaFiles: df, deltaBytes: db,
                                  intervalSeconds: interval, tier: nil)
        let rateHit = rate.filesPerMinute >= thresholds.filesPerMinute
            || rate.bytesPerMinute >= thresholds.bytesPerMinute
        if rateHit { return VelocityReport(deltaFiles: df, deltaBytes: db, intervalSeconds: interval, tier: .red) }
        let absHit = df >= thresholds.files || db >= thresholds.bytes
        let tier: VelocityTier? = absHit ? .yellow : nil
        return VelocityReport(deltaFiles: df, deltaBytes: db, intervalSeconds: interval, tier: tier)
    }
}

// MARK: - SQLite 快照库

/// scan_snapshots 表的极薄封装：系统 libsqlite3，无第三方依赖。
/// 库落在应用数据目录（家目录或沙盒容器里的 ~/Library/Application Support/DiskWise/），
/// 「写什么」这笔账已进 docs/PRIVACY.md。
///
/// 库打不开或语句失败一律静默降级：快照与流速是增益不是地基，
/// 库坏掉不该让发现遍历跟着失败——界面只是没有流速可看。
public final class SnapshotStore {
    var db: OpaquePointer?
    public let keepScans: Int

    public static func defaultPath() -> URL {
        let dir = homeDir().appendingPathComponent("Library/Application Support/DiskWise", isDirectory: true)
        return dir.appendingPathComponent("diagnostics.sqlite")
    }

    public init(path: URL, keepScans: Int = 30) {
        self.keepScans = keepScans
        let fm = FileManager.default
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            db = nil
            return
        }
        let ddl = """
        CREATE TABLE IF NOT EXISTS scan_snapshots(
          entryKey TEXT NOT NULL, scanID TEXT NOT NULL, wallTime REAL NOT NULL,
          bytes INTEGER NOT NULL, fileCount INTEGER NOT NULL, newestMtime REAL,
          PRIMARY KEY(entryKey, scanID));
        CREATE INDEX IF NOT EXISTS snap_key_time ON scan_snapshots(entryKey, wallTime);
        CREATE TABLE IF NOT EXISTS probe_cache(
          entryKey TEXT NOT NULL, mtime REAL NOT NULL, owner TEXT, mixed INTEGER NOT NULL,
          hints TEXT NOT NULL, PRIMARY KEY(entryKey, mtime));
        CREATE TABLE IF NOT EXISTS trim_batches(
          batchID TEXT PRIMARY KEY, at REAL NOT NULL, entryKey TEXT NOT NULL,
          count INTEGER NOT NULL, bytes INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS trim_items(
          batchID TEXT NOT NULL, original TEXT NOT NULL, trash TEXT NOT NULL);
        """
        exec(ddl)
    }

    deinit {
        if db != nil { sqlite3_close_v2(db) }
    }

    func exec(_ sql: String) -> Bool {
        guard db != nil else { return false }
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if err != nil { sqlite3_free(err) }
        return ok
    }

    /// 记一轮扫描（同 scanID 重记 = 覆盖），并把历史裁到最近 `keepScans` 轮。
    public func record(scanID: String, wallTime: Date, snapshots: [ScanSnapshot]) {
        guard db != nil else { return }
        exec("BEGIN")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT OR REPLACE INTO scan_snapshots(entryKey, scanID, wallTime, bytes, fileCount, newestMtime)
        VALUES(?,?,?,?,?,?)
        """, -1, &stmt, nil) == SQLITE_OK else { exec("ROLLBACK"); return }
        for s in snapshots {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, s.entryKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, s.scanID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, s.wallTime.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 4, s.bytes)
            sqlite3_bind_int64(stmt, 5, Int64(s.fileCount))
            if let n = s.newestMtime {
                sqlite3_bind_double(stmt, 6, n.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // 滚动保留：只留最近 N 轮（按 distinct wallTime 记轮数）
        exec("""
        DELETE FROM scan_snapshots WHERE wallTime NOT IN
        (SELECT DISTINCT wallTime FROM scan_snapshots ORDER BY wallTime DESC LIMIT \(keepScans));
        """)
        exec("COMMIT")
    }

    /// 基线：同一 entryKey 下、距今 ≥10 分钟、且不属于本轮 scanID 的最新一条。
    /// 连扫两次（间隔 30 秒）不换基线——否则 Δ≈0，刚才的徽标当场消失（评审 §2.1c）。
    public func baseline(entryKey: String, now: Date, currentScanID: String,
                         minAge: TimeInterval = 600) -> ScanSnapshot? {
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT scanID, wallTime, bytes, fileCount, newestMtime FROM scan_snapshots
        WHERE entryKey = ? AND scanID != ? AND wallTime <= ?
        ORDER BY wallTime DESC LIMIT 1
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, entryKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, currentScanID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, now.addingTimeInterval(-minAge).timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rowToSnapshot(stmt, entryKey: entryKey)
    }

    /// 是否存在任何早于本轮的快照（区分「首扫建基线」与「有历史但都在 10 分钟内」）。
    public func hasHistory(entryKey: String, before now: Date) -> Bool {
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT COUNT(*) FROM scan_snapshots WHERE entryKey = ? AND wallTime <= ?
        """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, entryKey, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) > 0
    }

    /// 供 MCP（PR-5）取每个条目最近两轮差。基线规则与界面同一条（10 分钟）。
    public func latestTwo(entryKey: String, now: Date = Date(),
                          minAge: TimeInterval = 600) -> (current: ScanSnapshot, baseline: ScanSnapshot)? {
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT scanID, wallTime, bytes, fileCount, newestMtime FROM scan_snapshots
        WHERE entryKey = ? ORDER BY wallTime DESC LIMIT 1
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, entryKey, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let current = rowToSnapshot(stmt, entryKey: entryKey)
        guard let base = baseline(entryKey: entryKey, now: now, currentScanID: current.scanID, minAge: minAge) else {
            return nil
        }
        return (current, base)
    }

    private func rowToSnapshot(_ stmt: OpaquePointer?, entryKey: String) -> ScanSnapshot {
        let scanID = String(cString: sqlite3_column_text(stmt, 0))
        let wall = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let bytes = sqlite3_column_int64(stmt, 2)
        let files = Int(sqlite3_column_int64(stmt, 3))
        let newest = sqlite3_column_type(stmt, 4) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        return ScanSnapshot(entryKey: entryKey, scanID: scanID, wallTime: wall,
                            bytes: bytes, fileCount: files, newestMtime: newest)
    }
}
