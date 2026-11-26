import Foundation
import SQLite3
import Testing

struct ControlCenterAndValuationTests {
    @Test func localSnapshotLeavesBundledResourcesUntouched() async throws {
        let temp = try TestDirectory()
        defer { try? temp.remove() }
        let resources = Bundle(for: AppUpdater.self)
        for name in ["CodexBarProbe", "UsageCollector"] {
            let src = try #require(resources.url(forResource: name, withExtension: "py"))
            try FileManager.default.copyItem(at: src, to: temp.url.appendingPathComponent(name + ".py"))
        }
        var source = UsageSource.local
        source.claudeHome = temp.url.appendingPathComponent("claude").path
        let probe = temp.url.appendingPathComponent("CodexBarProbe.py")
        _ = try await UsageCollectorClient().fetchLocalZeroHookSnapshot(source: source, probeURL: probe)
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("__pycache__").path))
    }

    @Test
    func menuScopeIncludesRespectsEnabledAndProviderToggles() {
        var local = UsageSource.local
        local.includesCodex = true
        local.includesClaude = true
        local.includesGemini = false

        #expect(UsageMenuScope.codex.includes(local))
        #expect(UsageMenuScope.claude.includes(local))
        #expect(!UsageMenuScope.gemini.includes(local))
        #expect(UsageMenuScope.all.includes(local))

        local.isEnabled = false
        #expect(!UsageMenuScope.codex.includes(local))
        #expect(!UsageMenuScope.all.includes(local))
    }

    @Test
    func geminiAndClaudeWeeklyValuationExtrapolation() {
        let now = Date(timeIntervalSince1970: 1780000000)
        let resetAt = now.timeIntervalSince1970 + 86400 * 3
        let stepTs = now.timeIntervalSince1970 - 3600
        let account = String(repeating: "a", count: 64)

        let geminiObs = UsageQuotaObservation(
            provider: "gemini",
            observedAt: now.timeIntervalSince1970 - 120,
            windows: [
                .init(name: "5h", usedPercent: 15, resetsAt: now.timeIntervalSince1970 + 7200),
                .init(name: "7d", usedPercent: 25, resetsAt: resetAt)
            ], accountKey: account
        )
        let geminiRecord = GeminiStepUsageRecord(
            id: "gem-1",
            at: stepTs,
            model: "gemini-4-neon",
            tokens: GeminiStepTokens(input: 1000000, cached: 0, cacheWrite: 0, output: 200000)
        )
        let geminiPeriods = GeminiValuationCalculator.computePeriods(
            provider: "gemini",
            evidences: [
                GeminiValuationEvidence(accountKey: account, accountScoped: true, planTier: "Ultra", windows: [], records: [geminiRecord]),
                GeminiValuationEvidence(accountKey: account, accountScoped: true, windows: [], records: [geminiRecord]),
                GeminiValuationEvidence(
                    accountKey: String(repeating: "b", count: 64),
                    accountScoped: true,
                    windows: [],
                    records: [.init(id: "other", at: stepTs, model: geminiRecord.model, tokens: geminiRecord.tokens)]
                )
            ],
            storeRecords: [.init(id: "legacy", at: stepTs, model: geminiRecord.model, tokens: geminiRecord.tokens)],
            liveWeeklyObservation: geminiObs,
            priceBook: .fallback,
            now: now
        )
        #expect(geminiPeriods.count == 1)
        let gPeriod = geminiPeriods[0]
        #expect(abs(gPeriod.dollars - 6.0) < 0.001)
        #expect(gPeriod.projectedDollars != nil)
        #expect(abs((gPeriod.projectedDollars ?? 0) - 24.0) < 0.01)
        #expect(gPeriod.planTitle == "Ultra")
        #expect(gPeriod.tokens == geminiRecord.tokens)

        let claudeObs = UsageQuotaObservation(
            provider: "claude",
            observedAt: now.timeIntervalSince1970 - 60,
            windows: [
                .init(name: "7d", usedPercent: 20, resetsAt: resetAt)
            ]
        )
        let claudeRecord = GeminiStepUsageRecord(
            id: "cc-1",
            at: stepTs,
            model: "claude-sonnet-5-5",
            tokens: GeminiStepTokens(input: 1000000, cached: 0, cacheWrite: 0, output: 300000)
        )
        let claudePeriods = GeminiValuationCalculator.computePeriods(
            provider: "claude",
            evidences: [GeminiValuationEvidence(windows: [], records: [claudeRecord])],
            liveWeeklyObservation: claudeObs,
            priceBook: .fallback,
            now: now
        )
        #expect(claudePeriods.count == 1)
        let cPeriod = claudePeriods[0]
        #expect(abs(cPeriod.dollars - 5.0) < 0.001)
        #expect(abs((cPeriod.projectedDollars ?? 0) - 25.0) < 0.01)
    }

    @Test
    func storeMigratesLegacyV1DatabaseAndAppliesHubBatch() async throws {
        let tempDir = try TestDirectory()
        defer { try? tempDir.remove() }
        let dbURL = tempDir.url.appendingPathComponent("center-v1.sqlite")

        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let localPayload = #"{"id":"local","name":"本机 Mac","transport":"local","address":"","#
            + #""isEnabled":true,"includesCodex":true,"includesClaude":true,"codexAuthentication":"oauth","codexHome":"","claudeHome":""}"#
        let remotePayload = #"{"id":"sk_203","name":"sk_203","transport":"ssh","address":"sk_203","#
            + #""isEnabled":true,"includesCodex":true,"includesClaude":true,"codexAuthentication":"oauth","codexHome":"","claudeHome":""}"#
        let legacySQL = """
        CREATE TABLE sources (
            id TEXT PRIMARY KEY, payload TEXT NOT NULL, name TEXT NOT NULL, auth TEXT NOT NULL,
            enabled INTEGER NOT NULL, codex INTEGER NOT NULL, claude INTEGER NOT NULL,
            epoch TEXT NOT NULL DEFAULT '', cursor INTEGER NOT NULL DEFAULT 0,
            collected REAL NOT NULL DEFAULT 0, warnings TEXT NOT NULL DEFAULT '[]', quotas TEXT NOT NULL DEFAULT '[]'
        );
        INSERT INTO sources VALUES ('local', '\(localPayload)', '本机 Mac', 'oauth', 1, 1, 1, '', 0, 0, '[]', '[]');
        INSERT INTO sources VALUES ('sk_203', '\(remotePayload)', 'sk_203', 'oauth', 1, 1, 1, 'e1', 42, 1770000000, '[]', '[]');
        """
        #expect(sqlite3_exec(db, legacySQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = UsageCenterStore(directory: tempDir.url)
        let loaded = try await store.sources()
        #expect(loaded.count == 2)
        #expect(FileManager.default.fileExists(atPath: tempDir.url.appendingPathComponent("center-v1.backup.sqlite").path))

        var probeNode = UsageSource(id: "lan-box", name: "LAN Box", transport: .probe)
        probeNode.includesGemini = true
        probeNode.isOnline = true
        let now = Date().timeIntervalSince1970
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let recordData = try JSONSerialization.data(withJSONObject: [
            "nodeId": "lan-box",
            "id": String(repeating: "g", count: 64),
            "session": String(repeating: "s", count: 64),
            "provider": "gemini",
            "auth": "oauth",
            "day": day,
            "model": "gemini-4-neon",
            "project": "demo",
            "kind": "usage",
            "state": "",
            "observedAt": now,
            "input": 2000,
            "output": 400,
            "cacheRead": 500,
            "cacheWrite": 100,
            "reasoning": 0,
            "turns": 1,
            "tools": 2,
            "permissions": 0,
            "compactions": 0,
            "subagents": 0,
            "durationMs": 1200
        ])
        let record = try JSONDecoder().decode(UsageRecord.self, from: recordData)
        try await store.applyHubBatch(
            epoch: UUID().uuidString,
            cursor: 1,
            reset: false,
            generatedAt: now,
            nodes: [probeNode],
            nodeStatuses: ["lan-box": UsageSourceStatus(geminiPlan: "Pro")],
            records: [record]
        )

        let allDash = try await store.dashboard(filter: UsageFilter(provider: "gemini", days: 210, localOnly: false))
        #expect(allDash.totals.tokens == 3000)

        let localOnlyDash = try await store.dashboard(filter: UsageFilter(provider: "gemini", days: 210, localOnly: true))
        #expect(localOnlyDash.totals.tokens == 0)

        let valRecords = try await store.valuationUsageRecords(provider: "gemini", localOnly: false)
        let firstVal = try #require(valRecords.first)
        #expect(firstVal.tokens.input == 2000)
        #expect(firstVal.tokens.cached == 500)
        #expect(firstVal.tokens.cw == 100)
        #expect(firstVal.tokens.output == 400)
    }

    @Test
    func hubCryptoCommandDoesNotEmbedTokenInURL() {
        let rawToken = HubCrypto.randomToken(prefix: "cbw_")
        let key = HubCrypto.deriveSigningKey(rawWriteToken: rawToken)
        #expect(key.count == 64)

        let command = HubCrypto.probeInstallCommand(
            hubURL: "https://cn.example.com:65120",
            nodeID: "lan_node",
            rawWriteToken: rawToken,
            providers: ["codex", "claude", "gemini"],
            bridgeStatusLine: true
        )
        #expect(command.hasPrefix("env CODEXBAR_TOKEN="))
        #expect(command.contains("https://cn.example.com:65120/install.sh"))
        #expect(!command.contains("install.sh?token="))
        #expect(command.contains(#"--providers "codex,claude,gemini""#))
    }

    @MainActor
    @Test
    func probeSnapshotOverridesLegacyPausedProviderStateAndDeduplicatesEffortSuffix() throws {
        let suiteName = "ControlCenterProbeStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = RemoteActivityController(defaults: defaults)
        var legacySource = UsageSource(id: "ssh-sk203", name: "sk_203", transport: .ssh, address: "sk_203")
        legacySource.includesClaude = true
        controller.setSources([legacySource])
        controller.setConnectionAllowed(false, localAllowed: false)

        var upgradedProbe = legacySource
        upgradedProbe.transport = .probe
        upgradedProbe.isOnline = true
        controller.setSources([upgradedProbe])

        let now = Date().timeIntervalSince1970
        let taskData = try JSONSerialization.data(withJSONObject: [
            "id": String(repeating: "c", count: 64),
            "provider": "claude",
            "state": "running",
            "project": "YJOS",
            "startedAt": now - 120,
            "updatedAt": now,
            "stateChangedAt": now - 120,
            "modelName": "claude-opus-5-5",
            "stage": "background-shell",
            "eventName": "BackgroundShell"
        ])
        let task = try JSONDecoder().decode(RemoteActivityTask.self, from: taskData)
        controller.applyProbeSnapshot(sourceID: "ssh-sk203", tasks: [task], isOnline: true, emitLiveNotifications: false)

        let merged = ActivityPresentationModel.merge(
            local: .empty,
            tasks: controller.tasks,
            states: controller.states,
            enabled: controller.enabledSourceIDs,
            sources: [upgradedProbe],
            scope: .all,
            now: Date(timeIntervalSince1970: now)
        )
        #expect(merged.runningTasks.count == 1)
        #expect(merged.unconfirmedTasks.isEmpty)
        #expect(merged.runningTasks.first?.projectName == "YJOS")
        #expect(merged.runningTasks.first?.stageTitle == "后台 Shell 运行中")

        #expect(
            CodexActivityDisplayFormat.modelMetadata(
                modelName: "gemini-4-carbon-high",
                effort: "high",
                machineName: "sk_203"
            ) == "gemini-4-carbon-high • sk_203"
        )
        #expect(
            CodexActivityDisplayFormat.modelMetadata(
                modelName: "gpt-5.4",
                effort: "xhigh",
                machineName: "本机"
            ) == "gpt-5.4 • xhigh • 本机"
        )
    }
}
