import Foundation
import SQLite3

public enum HistoryDatabaseError: Error, LocalizedError {
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): String(localized: "Error del historial: \(message)")
        }
    }
}

/// Historial persistente de lecturas por paciente (SQLite). LibreLinkUp solo devuelve
/// ~12 h; acá se acumula todo lo que la app va viendo. Una lectura por minuto: si llega
/// otra en el mismo minuto, se queda la última (y se conserva la tendencia si la nueva no trae).
/// No es seguro entre hilos: usarlo desde un solo actor.
public final class HistoryDatabase {
    private var db: OpaquePointer?

    /// - Parameter url: archivo; `nil` = en memoria (demo y tests).
    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let path = url?.path(percentEncoded: false) ?? ":memory:"
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "no se pudo abrir"
            sqlite3_close(db)
            throw HistoryDatabaseError.sqlite(message)
        }
        try execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS readings (
                patient TEXT NOT NULL,
                minute INTEGER NOT NULL,
                mgdl REAL NOT NULL,
                trend INTEGER,
                PRIMARY KEY (patient, minute)
            ) WITHOUT ROWID;
            """)
    }

    deinit { sqlite3_close(db) }

    /// Archivo por defecto: ~/Library/Application Support/LibreLibreLink/history.sqlite
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "LibreLibreLink/history.sqlite")
    }

    public func insert(_ readings: [GlucoseMeasurement], patientID: String) throws {
        guard !readings.isEmpty else { return }
        try execute("BEGIN")
        do {
            let statement = try prepare("""
                INSERT INTO readings (patient, minute, mgdl, trend) VALUES (?, ?, ?, ?)
                ON CONFLICT (patient, minute) DO UPDATE SET
                    mgdl = excluded.mgdl, trend = COALESCE(excluded.trend, readings.trend)
                """)
            defer { sqlite3_finalize(statement) }
            for reading in readings {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, patientID, -1, Self.transient)
                sqlite3_bind_int64(statement, 2, Int64((reading.date.timeIntervalSince1970 / 60).rounded(.down)))
                sqlite3_bind_double(statement, 3, reading.mgdL)
                if let trend = reading.trend {
                    sqlite3_bind_int(statement, 4, Int32(trend.rawValue))
                } else {
                    sqlite3_bind_null(statement, 4)
                }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Lecturas del intervalo, ordenadas por fecha.
    public func readings(patientID: String, in interval: DateInterval) throws -> [GlucoseMeasurement] {
        let statement = try prepare("""
            SELECT minute, mgdl, trend FROM readings
            WHERE patient = ? AND minute >= ? AND minute <= ? ORDER BY minute
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, patientID, -1, Self.transient)
        sqlite3_bind_int64(statement, 2, Int64((interval.start.timeIntervalSince1970 / 60).rounded(.down)))
        sqlite3_bind_int64(statement, 3, Int64((interval.end.timeIntervalSince1970 / 60).rounded(.down)))
        var result: [GlucoseMeasurement] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let date = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)) * 60)
            let mgdL = sqlite3_column_double(statement, 1)
            let trend = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil : Trend(rawValue: Int(sqlite3_column_int(statement, 2)))
            result.append(GlucoseMeasurement(date: date, mgdL: mgdL, trend: trend, isHigh: mgdL > 500, isLow: mgdL < 40))
        }
        return result
    }

    /// Fecha de la lectura más vieja guardada.
    public func earliest(patientID: String) throws -> Date? {
        let statement = try prepare("SELECT MIN(minute) FROM readings WHERE patient = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, patientID, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)) * 60)
    }

    // MARK: SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        return statement
    }

    private func lastError() -> HistoryDatabaseError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
