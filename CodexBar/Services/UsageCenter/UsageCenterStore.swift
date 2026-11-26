import Foundation
import SQLite3

nonisolated struct UsageCenterError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

private nonisolated enum UsageSQLValue {
    case text(String)
    case integer(Int64)
    case real(Double)
}

actor UsageCenterStore {
    private let directory: URL
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var dashboards: [UsageFilter: UsageDashboard] = [:]
    private var dashboardOrder: [UsageFilter] = []
    private var cacheDay = ""
    private var externalVersion: Int32 = -1

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar-yatotm/UsageCenter", isDirectory: true)
    }

    private func connect() throws -> OpaquePointer {
        if let database {
            return database
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("center-v1.sqlite").path
        var connection: OpaquePointer?
        guard sqlite3_open(path, &connection) == SQLITE_OK, let connection else {
            if let connection {
                sqlite3_close(connection)
            }
            throw UsageCenterError(message: "无法打开用量数据库")
        }
        var versionQuery: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &versionQuery, nil)
        let version: Int32? = if prepared == SQLITE_OK, let versionQuery, sqlite3_step(versionQuery) == SQLITE_ROW {
            sqlite3_column_int(versionQuery, 0)
        } else {
            nil
        }
        sqlite3_finalize(versionQuery)
        guard let version, (0 ... 1).contains(version) else {
            sqlite3_close(connection)
            throw UsageCenterError(message: "用量数据库版本不受支持, 已保留原文件")
        }
        database = connection
        sqlite3_busy_timeout(connection, 2000)
        try migrateSourcesTableIfNeeded(connection: connection, dbPath: path)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA temp_store=MEMORY;
        PRAGMA user_version=1;
        CREATE TABLE IF NOT EXISTS sources (
            id TEXT PRIMARY KEY, payload TEXT NOT NULL, name TEXT NOT NULL, auth TEXT NOT NULL,
            enabled INTEGER NOT NULL, codex INTEGER NOT NULL, claude INTEGER NOT NULL,
            gemini INTEGER NOT NULL DEFAULT 0, gemini_plan TEXT NOT NULL DEFAULT '',
            epoch TEXT NOT NULL DEFAULT '', cursor INTEGER NOT NULL DEFAULT 0,
            collected REAL NOT NULL DEFAULT 0, warnings TEXT NOT NULL DEFAULT '[]', quotas TEXT NOT NULL DEFAULT '[]');
        CREATE TABLE IF NOT EXISTS hub_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS records (
            source TEXT NOT NULL, id TEXT NOT NULL, provider TEXT NOT NULL, auth TEXT NOT NULL,
            day TEXT NOT NULL, session TEXT NOT NULL, model TEXT NOT NULL, project TEXT NOT NULL,
            kind TEXT NOT NULL, state TEXT NOT NULL, observed REAL NOT NULL,
            input INTEGER NOT NULL, output INTEGER NOT NULL, cacheRead INTEGER NOT NULL,
            cacheWrite INTEGER NOT NULL, reasoning INTEGER NOT NULL, turns INTEGER NOT NULL,
            tools INTEGER NOT NULL, permissions INTEGER NOT NULL, compactions INTEGER NOT NULL,
            subagents INTEGER NOT NULL, durationMs INTEGER NOT NULL, PRIMARY KEY(source, id));
        CREATE INDEX IF NOT EXISTS usage_day ON records(day);
        CREATE INDEX IF NOT EXISTS usage_identity ON records(id);
        """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            database = nil
            throw UsageCenterError(message: "用量数据库结构不可用, 已保留原文件")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return connection
    }

    private func migrateSourcesTableIfNeeded(connection: OpaquePointer, dbPath: String) throws {
        var tableCheck: OpaquePointer?
        defer { sqlite3_finalize(tableCheck) }
        guard sqlite3_prepare_v2(
            connection,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sources'",
            -1,
            &tableCheck,
            nil
        ) == SQLITE_OK, sqlite3_step(tableCheck) == SQLITE_ROW else {
            return
        }
        var infoQuery: OpaquePointer?
        defer { sqlite3_finalize(infoQuery) }
        guard sqlite3_prepare_v2(connection, "PRAGMA table_info(sources)", -1, &infoQuery, nil) == SQLITE_OK else {
            return
        }
        var columns = Set<String>()
        while sqlite3_step(infoQuery) == SQLITE_ROW {
            if let raw = sqlite3_column_text(infoQuery, 1) {
                columns.insert(String(cString: raw))
            }
        }
        if !columns.contains("gemini") {
            let backupPath = directory.appendingPathComponent("center-v1.backup.sqlite").path
            if FileManager.default.fileExists(atPath: dbPath), !FileManager.default.fileExists(atPath: backupPath) {
                try? FileManager.default.copyItem(atPath: dbPath, toPath: backupPath)
            }
            _ = sqlite3_exec(connection, "ALTER TABLE sources ADD COLUMN gemini INTEGER NOT NULL DEFAULT 0;", nil, nil, nil)
        }
        if !columns.contains("gemini_plan") {
            _ = sqlite3_exec(connection, "ALTER TABLE sources ADD COLUMN gemini_plan TEXT NOT NULL DEFAULT '';", nil, nil, nil)
        }
    }

    private func statement(_ sql: String, values: [UsageSQLValue] = []) throws -> OpaquePointer {
        let connection = try connect()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageCenterError(message: "用量数据库查询失败")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32 = switch value {
            case let .text(string): sqlite3_bind_text(statement, position, string, -1, transient)
            case let .integer(integer): sqlite3_bind_int64(statement, position, integer)
            case let .real(real): sqlite3_bind_double(statement, position, real)
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw UsageCenterError(message: "用量数据库参数无效")
            }
        }
        return statement
    }

    private func execute(_ sql: String, _ values: [UsageSQLValue] = []) throws {
        let query = try statement(sql, values: values)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw UsageCenterError(message: "用量数据库写入失败") }
    }

    private func string(_ query: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(query, column) else { return "" }
        return String(cString: value)
    }

    private func nextRow(_ query: OpaquePointer) throws -> Bool {
        switch sqlite3_step(query) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        default: throw UsageCenterError(message: "统计查询未完成, 已保留上次显示")
        }
    }

    func sources() throws -> [UsageSource] {
        let query = try statement("SELECT payload FROM sources ORDER BY CASE WHEN id='local' THEN 0 ELSE 1 END, name")
        defer { sqlite3_finalize(query) }
        var result: [UsageSource] = []
        while try nextRow(query) {
            let source = try decoder.decode(UsageSource.self, from: Data(string(query, 0).utf8))
            result.append(source)
        }
        return result
    }

    func save(_ source: UsageSource) throws {
        clearDashboardCache()
        if let error = source.validationError {
            throw UsageCenterError(message: error)
        }
        let payload = try jsonString(source)
        try execute("""
        INSERT INTO sources(id,payload,name,auth,enabled,codex,claude,gemini) VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,name=excluded.name,auth=excluded.auth,
        enabled=excluded.enabled,codex=excluded.codex,claude=excluded.claude,gemini=excluded.gemini
        """, [
            .text(source.id),
            .text(payload),
            .text(source.name),
            .text(source.codexAuthentication.rawValue),
            .integer(source.isEnabled ? 1 : 0),
            .integer(source.includesCodex ? 1 : 0),
            .integer(source.includesClaude ? 1 : 0),
            .integer(source.includesGemini ? 1 : 0)
        ])
    }

    func remove(_ source: UsageSource) throws {
        clearDashboardCache()
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM records WHERE source=?", [.text(source.id)])
            try execute("DELETE FROM sources WHERE id=?", [.text(source.id)])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func cursor(for source: UsageSource) throws -> UsageCursor {
        let query = try statement("SELECT epoch,cursor FROM sources WHERE id=?", values: [.text(source.id)])
        defer { sqlite3_finalize(query) }
        guard try nextRow(query) else { return UsageCursor() }
        return UsageCursor(epoch: string(query, 0), revision: sqlite3_column_int64(query, 1))
    }

    func apply(_ envelope: UsageEnvelope, source: UsageSource) throws {
        guard envelope.isValid else { throw UsageCenterError(message: "统计端协议或数据无效, 未覆盖缓存") }
        if envelope.reset || !envelope.records.isEmpty {
            clearDashboardCache()
        }
        let current = try cursor(for: source)
        guard envelope.reset || (current.epoch == envelope.epoch && envelope.cursor >= current.revision) else {
            throw UsageCenterError(message: "统计端游标不连续, 未覆盖缓存")
        }
        try execute("BEGIN IMMEDIATE")
        do {
            if envelope.reset {
                try execute("DELETE FROM records WHERE source=?", [.text(source.id)])
            }
            for record in envelope.records {
                try execute("INSERT OR REPLACE INTO records VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    .text(source.id), .text(record.id), .text(record.provider), .text(record.auth), .text(record.day),
                    .text(record.session), .text(record.model), .text(record.project), .text(record.kind), .text(record.state),
                    .real(record.observedAt), .integer(record.input), .integer(record.output), .integer(record.cacheRead),
                    .integer(record.cacheWrite), .integer(record.reasoning), .integer(record.turns), .integer(record.tools),
                    .integer(record.permissions), .integer(record.compactions), .integer(record.subagents), .integer(record.durationMs)
                ])
            }
            let planValue = envelope.geminiPlan ?? ""
            try execute("""
            UPDATE sources SET epoch=?,cursor=?,collected=?,warnings=?,quotas=?,
            gemini_plan=CASE WHEN ?!='' THEN ? ELSE gemini_plan END WHERE id=?
            """, [
                .text(envelope.epoch), .integer(envelope.cursor), .real(envelope.generatedAt),
                .text(jsonString(envelope.warnings)),
                .text(jsonString(envelope.quotas)),
                .text(planValue), .text(planValue), .text(source.id)
            ])
            try execute("DELETE FROM records WHERE day < date('now','-210 days')")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func status(for source: UsageSource) throws -> UsageSourceStatus {
        let query = try statement("SELECT collected,warnings,quotas,gemini_plan FROM sources WHERE id=?", values: [.text(source.id)])
        defer { sqlite3_finalize(query) }
        guard try nextRow(query) else { return UsageSourceStatus() }
        let collected = sqlite3_column_double(query, 0)
        let plan = string(query, 3)
        return try UsageSourceStatus(
            lastSuccess: collected > 0 ? Date(timeIntervalSince1970: collected) : nil,
            warnings: decoder.decode([String].self, from: Data(string(query, 1).utf8)),
            quotas: decoder.decode([UsageQuotaObservation].self, from: Data(string(query, 2).utf8)),
            geminiPlan: plan.isEmpty ? nil : plan
        )
    }

    func hubCursor() throws -> UsageCursor {
        let epochQuery = try statement("SELECT value FROM hub_state WHERE key='epoch'")
        defer { sqlite3_finalize(epochQuery) }
        let epoch = try nextRow(epochQuery) ? string(epochQuery, 0) : ""
        let cursorQuery = try statement("SELECT value FROM hub_state WHERE key='cursor'")
        defer { sqlite3_finalize(cursorQuery) }
        let rev = try nextRow(cursorQuery) ? (Int64(string(cursorQuery, 0)) ?? 0) : 0
        return UsageCursor(epoch: epoch, revision: rev)
    }

    func saveHubValue(_ value: String, forKey key: String) throws {
        try execute("INSERT OR REPLACE INTO hub_state(key, value) VALUES(?, ?)", [.text(key), .text(value)])
    }

    func hubValue(forKey key: String) throws -> String? {
        let query = try statement("SELECT value FROM hub_state WHERE key=?", values: [.text(key)])
        defer { sqlite3_finalize(query) }
        return try nextRow(query) ? string(query, 0) : nil
    }

    func valuationUsageRecords(provider: String, localOnly: Bool) throws -> [GeminiStepUsageRecord] {
        guard ["claude", "gemini"].contains(provider) else { return [] }
        let cutoff = Date().timeIntervalSince1970 - 70 * 86400
        let sql = """
        WITH dedup AS (
            SELECT r.id, r.observed, r.model, r.input, r.cacheRead, r.cacheWrite, r.output,
            ROW_NUMBER() OVER(PARTITION BY r.id ORDER BY (r.input+r.output+r.cacheRead+r.cacheWrite) DESC, r.observed DESC) AS pos
            FROM records r JOIN sources s ON s.id=r.source
            WHERE s.enabled=1 AND (?=0 OR s.id='local')
            AND ((r.provider='claude' AND s.claude=1) OR (r.provider='gemini' AND s.gemini=1))
            AND r.provider=? AND r.kind='usage' AND r.auth!='api' AND r.observed>=?
        )
        SELECT id, observed, model, input, cacheRead, cacheWrite, output FROM dedup WHERE pos=1 ORDER BY observed DESC LIMIT 25000
        """
        let query = try statement(sql, values: [.integer(localOnly ? 1 : 0), .text(provider), .real(cutoff)])
        defer { sqlite3_finalize(query) }
        var items: [GeminiStepUsageRecord] = []
        while try nextRow(query) {
            items.append(GeminiStepUsageRecord(
                id: string(query, 0),
                at: sqlite3_column_double(query, 1),
                model: string(query, 2),
                tokens: GeminiStepTokens(
                    input: sqlite3_column_int64(query, 3),
                    cached: sqlite3_column_int64(query, 4),
                    cacheWrite: sqlite3_column_int64(query, 5),
                    output: sqlite3_column_int64(query, 6)
                )
            ))
        }
        return items
    }

    func applyHubBatch(
        epoch: String,
        cursor: Int64,
        reset: Bool,
        generatedAt: Double,
        nodes: [UsageSource],
        nodeStatuses: [String: UsageSourceStatus],
        records: [UsageRecord]
    ) throws {
        if reset || !records.isEmpty || !nodes.isEmpty {
            clearDashboardCache()
        }
        try execute("BEGIN IMMEDIATE")
        do {
            if reset {
                try execute("DELETE FROM records WHERE source IN (SELECT id FROM sources WHERE json_extract(payload,'$.transport')='probe')")
            }
            for node in nodes {
                let payload = try jsonString(node)
                let st = nodeStatuses[node.id] ?? UsageSourceStatus()
                let collected = node.lastSeenAt ?? st.lastSuccess?.timeIntervalSince1970 ?? generatedAt
                let plan = st.geminiPlan ?? ""
                try execute("""
                INSERT INTO sources(id,payload,name,auth,enabled,codex,claude,gemini,gemini_plan,collected,warnings,quotas)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    payload=excluded.payload,name=excluded.name,enabled=excluded.enabled,
                    codex=excluded.codex,claude=excluded.claude,gemini=excluded.gemini,
                    gemini_plan=excluded.gemini_plan,
                    collected=CASE WHEN excluded.collected>0 THEN excluded.collected ELSE sources.collected END,
                    warnings=excluded.warnings,quotas=excluded.quotas
                """, [
                    .text(node.id), .text(payload), .text(node.name), .text(node.codexAuthentication.rawValue),
                    .integer(node.isEnabled ? 1 : 0), .integer(node.includesCodex ? 1 : 0),
                    .integer(node.includesClaude ? 1 : 0), .integer(node.includesGemini ? 1 : 0),
                    .text(plan), .real(collected),
                    .text(jsonString(st.warnings)), .text(jsonString(st.quotas))
                ])
            }
            for record in records where record.isValid {
                guard let nodeId = record.nodeId, !nodeId.isEmpty else { continue }
                try execute("INSERT OR REPLACE INTO records VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    .text(nodeId), .text(record.id), .text(record.provider), .text(record.auth), .text(record.day),
                    .text(record.session), .text(record.model), .text(record.project), .text(record.kind), .text(record.state),
                    .real(record.observedAt), .integer(record.input), .integer(record.output), .integer(record.cacheRead),
                    .integer(record.cacheWrite), .integer(record.reasoning), .integer(record.turns), .integer(record.tools),
                    .integer(record.permissions), .integer(record.compactions), .integer(record.subagents), .integer(record.durationMs)
                ])
            }
            try execute("INSERT OR REPLACE INTO hub_state VALUES('epoch', ?)", [.text(epoch)])
            try execute("INSERT OR REPLACE INTO hub_state VALUES('cursor', ?)", [.text(String(cursor))])
            try execute("DELETE FROM records WHERE day < date('now','-210 days')")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func jsonString(_ value: some Encodable) throws -> String {
        guard let result = try String(data: encoder.encode(value), encoding: .utf8) else {
            throw UsageCenterError(message: "统计数据无法编码")
        }
        return result
    }

    private static let metricsSQL = """
    COALESCE(SUM(input+output+CASE WHEN provider IN ('claude','gemini') THEN cacheRead+cacheWrite ELSE 0 END),0),
    COALESCE(SUM(input),0),COALESCE(SUM(output),0),COALESCE(SUM(cacheRead),0),COALESCE(SUM(cacheWrite),0),
    COUNT(DISTINCT CASE WHEN kind!='activity' THEN session END),COALESCE(SUM(turns),0),COALESCE(SUM(tools),0),
    COALESCE(SUM(permissions),0),COALESCE(SUM(compactions),0),COALESCE(SUM(subagents),0),COALESCE(SUM(durationMs),0),
    NULLIF(SUM(CASE WHEN kind='sharedInterrupt' THEN 1 ELSE 0 END),0)
    """

    private func metrics(_ query: OpaquePointer, start: Int32 = 0) -> UsageMetrics {
        UsageMetrics(
            tokens: sqlite3_column_int64(query, start), input: sqlite3_column_int64(query, start + 1),
            output: sqlite3_column_int64(query, start + 2), cacheRead: sqlite3_column_int64(query, start + 3),
            cacheWrite: sqlite3_column_int64(query, start + 4), sessions: sqlite3_column_int64(query, start + 5),
            turns: sqlite3_column_int64(query, start + 6), tools: sqlite3_column_int64(query, start + 7),
            permissions: sqlite3_column_int64(query, start + 8), compactions: sqlite3_column_int64(query, start + 9),
            subagents: sqlite3_column_int64(query, start + 10), durationMs: sqlite3_column_int64(query, start + 11),
            interruptions: sqlite3_column_type(query, start + 12) == SQLITE_NULL ? nil : sqlite3_column_int64(query, start + 12)
        )
    }

    private func clearDashboardCache() {
        dashboards.removeAll()
        dashboardOrder.removeAll()
    }

    private func touchDashboard(_ key: UsageFilter) {
        dashboardOrder.removeAll { $0 == key }
        dashboardOrder.append(key)
        while dashboardOrder.count > 80 {
            dashboards[dashboardOrder.removeFirst()] = nil
        }
    }

    private func validateDashboardCache() throws {
        let query = try statement("PRAGMA data_version")
        defer { sqlite3_finalize(query) }
        _ = try nextRow(query)
        let version = sqlite3_column_int(query, 0)
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        if day != cacheDay || version != externalVersion {
            clearDashboardCache()
            cacheDay = day
            externalVersion = version
        }
    }

    func dashboard(filter: UsageFilter) throws -> UsageDashboard {
        try Task.checkCancellation()
        try validateDashboardCache()
        if let cached = dashboards[filter] {
            touchDashboard(filter)
            return cached
        }
        let connection = try connect()
        sqlite3_progress_handler(connection, 10000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        defer {
            sqlite3_progress_handler(connection, 0, nil, nil)
            try? execute("DROP TABLE IF EXISTS usage_selection")
        }
        let selection = """
        WITH candidates AS (
        SELECT r.*,s.name AS machine,CASE WHEN r.auth='unknown' AND r.provider='codex' THEN s.auth ELSE r.auth END AS authGroup,
        ROW_NUMBER() OVER(PARTITION BY r.id ORDER BY (r.input+r.output+r.cacheRead+r.cacheWrite) DESC,r.observed DESC,r.source) AS position
        FROM records r JOIN sources s ON s.id=r.source WHERE s.enabled=1 AND (?=0 OR s.id='local')
        AND ((r.provider='codex' AND s.codex=1) OR (r.provider='claude' AND s.claude=1) OR (r.provider='gemini' AND s.gemini=1))
        AND r.day>=date('now',?) AND (?='' OR r.source=?) AND (?='' OR r.provider=?)),
        chosen AS (SELECT * FROM candidates WHERE position=1 AND (?='' OR authGroup=?))
        """
        let bindings: [UsageSQLValue] = [
            .integer(filter.localOnly ? 1 : 0),
            .text("-\(max(0, min(209, filter.days - 1))) days"), .text(filter.sourceID), .text(filter.sourceID),
            .text(filter.provider), .text(filter.provider), .text(filter.authentication), .text(filter.authentication)
        ]
        try execute("CREATE TEMP TABLE usage_selection AS " + selection + " SELECT * FROM chosen", bindings)
        return try aggregateSelection(filter: filter)
    }

    private func aggregateSelection(filter: UsageFilter) throws -> UsageDashboard {
        let cachedSelection = "WITH chosen AS (SELECT * FROM usage_selection) "
        var result = UsageDashboard()
        let total = try statement(cachedSelection + " SELECT " + Self.metricsSQL + " FROM chosen", values: [])
        defer { sqlite3_finalize(total) }
        if try nextRow(total) {
            result.totals = metrics(total)
        }
        var grouped: [UsageGrouping: [UsageGroup]] = [:]
        for grouping in UsageGrouping.allCases {
            let groupColumn = switch grouping {
            case .machine: "machine"
            case .provider: "provider"
            case .authentication: "authGroup"
            case .model: "model"
            case .project: "project"
            }
            let groups = try statement(
                cachedSelection + " SELECT \(groupColumn)," + Self.metricsSQL
                    + " FROM chosen GROUP BY \(groupColumn) ORDER BY 2 DESC LIMIT 200",
                values: []
            )
            defer { sqlite3_finalize(groups) }
            var rows: [UsageGroup] = []
            while try nextRow(groups) {
                rows.append(UsageGroup(name: string(groups, 0), metrics: metrics(groups, start: 1)))
            }
            grouped[grouping] = rows
        }
        let daily = try statement(
            cachedSelection + " SELECT day," + Self.metricsSQL
                + ",MAX(CASE WHEN kind='duration' AND durationMs>0 THEN durationMs END) FROM chosen GROUP BY day ORDER BY day",
            values: []
        )
        defer { sqlite3_finalize(daily) }
        while try nextRow(daily) {
            result.days.append(UsageDay(
                day: string(daily, 0), tokens: sqlite3_column_int64(daily, 1), metrics: metrics(daily, start: 1),
                longestTurnMs: sqlite3_column_type(daily, 14) == SQLITE_NULL ? nil : sqlite3_column_int64(daily, 14)
            ))
        }
        let models = try statement(cachedSelection + """
         SELECT day,model,SUM(input+output+CASE WHEN provider IN ('claude','gemini') THEN cacheRead+cacheWrite ELSE 0 END)
         FROM chosen WHERE kind='usage' AND model NOT IN ('','未知') GROUP BY day,model ORDER BY 1,3 DESC,2
        """, values: [])
        defer { sqlite3_finalize(models) }
        var topModels: [String: String] = [:]
        var modelTokens: [String: [String: Int64]] = [:]
        while try nextRow(models) {
            let day = string(models, 0)
            let model = string(models, 1)
            modelTokens[day, default: [:]][model] = sqlite3_column_int64(models, 2)
            if topModels[day] == nil {
                topModels[day] = model
            }
        }
        for index in result.days.indices {
            result.days[index].topModel = topModels[result.days[index].day]
            result.days[index].modelTokens = modelTokens[result.days[index].day] ?? [:]
        }
        let activity = try statement(cachedSelection + """
         SELECT id,machine,provider,project,model,state,observed FROM chosen
         WHERE kind='activity' AND observed>unixepoch()-86400 ORDER BY observed DESC LIMIT 100
        """, values: [])
        defer { sqlite3_finalize(activity) }
        while try nextRow(activity) {
            result.activities.append(UsageActivity(
                id: string(activity, 0), machine: string(activity, 1), provider: string(activity, 2),
                project: string(activity, 3), model: string(activity, 4), state: string(activity, 5),
                observedAt: sqlite3_column_double(activity, 6)
            ))
        }
        for grouping in UsageGrouping.allCases {
            var key = filter
            key.grouping = grouping
            result.groups = grouped[grouping] ?? []
            dashboards[key] = result
            touchDashboard(key)
        }
        result.groups = grouped[filter.grouping] ?? []
        return result
    }
}
