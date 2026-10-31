import XCTest
@testable import KapitsaApp

@MainActor
final class InstanceEditingTests: XCTestCase {
    private func config(id: String = "edit", name: String = "Original", port: Int = 8010) -> RuntimeConfiguration {
        RuntimeConfiguration(instanceId: id, name: name, model: "fake", port: port, context: nil, slots: nil)
    }

    private func fixture(_ config: RuntimeConfiguration, home: URL, legacy: Bool = false) throws -> Process {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent("build/runtime_test")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("Build the CPU runtime_test fixture first.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--fixture", home.appendingPathComponent("instances").path,
                             config.instanceId, String(decoding: try JSONEncoder().encode(config), as: UTF8.self)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if legacy { process.environment = ProcessInfo.processInfo.environment.merging(
            ["KAPITSA_FIXTURE_LEGACY": "1"], uniquingKeysWith: { _, new in new }) }
        try process.run()
        return process
    }

    private func waitForRecord(_ id: String, home: URL, excluding run: String? = nil) async throws -> RuntimeRecord {
        for _ in 0..<100 {
            if let record = Registry.records(in: home.appendingPathComponent("instances"))
                .first(where: { $0.instanceId == id && $0.runId != run }) { return record }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RuntimeFailure.message("CPU fixture did not publish its record.")
    }

    private func cleanup(_ processes: [Process], home: URL, preferences: UserDefaults, suite: String) {
        for process in processes {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }

    func testEditPreservesIdentityAutomaticValuesAndCustomDrafter() throws {
        var original = config()
        original.memBudgetGb = 24.5
        original.spec = 0
        original.dflash = "/models/custom-drafter"
        original.diskCache = "512m"
        original.prefillChunk = 512
        var draft = LaunchDefaults(configuration: original)
        XCTAssertEqual(try CapacityQuery(model: draft.model, defaults: draft, drafter: original.dflash)
            .configuration().dflash, original.dflash)
        XCTAssertEqual(draft.context, "")
        XCTAssertEqual(draft.slots, 0)
        XCTAssertEqual(try draft.configuration(name: original.name, model: draft.model, port: draft.port,
            context: draft.context, slots: draft.slots, editing: original), original)
        draft.model = "27b"
        draft.context = "90k"
        draft.port = 8012
        let edited = try draft.configuration(name: "Edited", model: draft.model, port: draft.port,
            context: draft.context, slots: draft.slots, editing: original)
        XCTAssertEqual(edited.instanceId, original.instanceId)
        XCTAssertEqual(edited.context, 92160)
        XCTAssertEqual(edited.dflash, original.dflash)
        XCTAssertEqual(edited.memBudgetGb, original.memBudgetGb)
        XCTAssertEqual(edited.spec, 0)
        draft.useDrafter = false
        XCTAssertEqual(try draft.configuration(name: "Edited", model: draft.model, port: draft.port,
            context: draft.context, slots: draft.slots, editing: original).dflash, "none")
    }

    func testStoppedEditPersistsWithoutLaunching() async throws {
        let suite = "kapitsa-edit-tests-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { cleanup([], home: home, preferences: preferences, suite: suite) }
        let original = config()
        preferences.set(try JSONEncoder().encode([original]), forKey: "runtimeProfiles")
        var launches = 0
        let store = InstanceStore(preferences: preferences, home: home, poll: false) { _ in
            launches += 1
            throw RuntimeFailure.message("Must not launch on save.")
        }
        await store.refresh()
        let row = try XCTUnwrap(store.selected)
        let edited = config(name: "Edited", port: 8011)
        try await store.save(edited, for: row, restart: false)
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(store.selectedId, original.instanceId)
        XCTAssertEqual(store.selected?.name, "Edited")
        XCTAssertEqual(store.selected?.profile, edited)
        let reloaded = InstanceStore(preferences: preferences, home: home, poll: false)
        await reloaded.refresh()
        XCTAssertEqual(reloaded.selected?.editableConfiguration, edited)
        do {
            try await store.save(config(id: "other"), for: row, restart: false)
            XCTFail("An edit must not replace the logical instance identity.")
        } catch {}
        XCTAssertEqual(store.selected?.profile, edited)
    }

    func testCLINativeSnapshotSaveIsDeferredAndRestartOnlyAffectsCapturedInstance() async throws {
        let suite = "kapitsa-edit-tests-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var processes: [Process] = []
        defer { cleanup(processes, home: home, preferences: preferences, suite: suite) }
        let original = config()
        processes.append(try fixture(original, home: home))
        processes.append(try fixture(config(id: "other", port: 8013), home: home))
        let first = try await waitForRecord("edit", home: home)
        let other = try await waitForRecord("other", home: home)
        var launches = 0
        let store = InstanceStore(preferences: preferences, home: home, poll: false) { config in
            launches += 1
            let child = try self.fixture(config, home: home)
            processes.append(child)
            return child
        }
        await store.refresh()
        let row = try XCTUnwrap(store.rows.first { $0.id == "edit" })
        XCTAssertNil(row.profile, "A CLI instance should be editable without an existing app profile.")
        XCTAssertEqual(row.editableConfiguration, original)
        XCTAssertNil(row.editableConfiguration?.context, "Auto must not become the effective 32768 tokens.")
        XCTAssertTrue(row.canRestart)
        let edited = config(name: "Edited", port: 8012)
        try await store.save(edited, for: row, restart: false)
        let pending = try XCTUnwrap(store.rows.first { $0.id == "edit" })
        XCTAssertTrue(pending.hasPendingChanges)
        XCTAssertEqual(pending.snapshot?.name, "Original")
        XCTAssertEqual(pending.snapshot?.apiUrl, "http://127.0.0.1:8010")
        XCTAssertEqual(pending.record?.runId, first.runId)
        XCTAssertEqual(launches, 0)
        // Reject another instance's port before sending stop.
        do {
            try await store.save(config(port: 8013), for: pending, restart: true)
            XCTFail("A busy port must not stop the original instance.")
        } catch {}
        _ = try await RuntimeClient().fetch(first)
        XCTAssertEqual(launches, 0)
        try await store.save(edited, for: pending, restart: true)
        let next = try await waitForRecord("edit", home: home, excluding: first.runId)
        await store.refresh()
        XCTAssertEqual(next.instanceId, first.instanceId)
        XCTAssertNotEqual(next.runId, first.runId)
        XCTAssertEqual(next.name, "Edited")
        XCTAssertEqual(store.rows.first { $0.id == "edit" }?.snapshot?.apiUrl, "http://127.0.0.1:8012")
        XCTAssertFalse(store.rows.first { $0.id == "edit" }?.hasPendingChanges ?? true)
        XCTAssertTrue(store.restartingIDs.isEmpty)
        XCTAssertEqual(launches, 1)
        let unaffected = try await RuntimeClient().fetch(other)
        XCTAssertEqual(unaffected.runId, other.runId)
        do {
            try await store.save(config(name: "Stale"), for: row, restart: true)
            XCTFail("The old form must not stop a newer execution.")
        } catch {}
        let stillRunning = try await RuntimeClient().fetch(next)
        XCTAssertEqual(stillRunning.runId, next.runId)
        XCTAssertEqual(launches, 1)
    }

    func testForegroundServeRequiresManualStopBeforeAppLaunch() async throws {
        let original = config()
        let data = """
        {"protocol":1,"instance_id":"edit","run_id":"run","name":"Original",
         "state":"ready","api_url":"http://127.0.0.1:8010","model":"fake",
         "context":32768,"slots":4,"managed":false,"requests":[],"cursor":0}
        """.data(using: .utf8)!
        let snapshot = try RuntimeClient.decode(RuntimeSnapshot.self, from: data)
        let record = try RuntimeClient.decode(RuntimeRecord.self, from: Data("""
        {"protocol":1,"instance_id":"edit","run_id":"run","name":"Original",
         "pid":1,"control_url":"http://127.0.0.1:12345","token":"token"}
        """.utf8))
        let row = InstanceRow(id: "edit", name: "Original", record: record,
                              snapshot: snapshot, profile: original, error: nil)
        XCTAssertFalse(row.canRestart, "Unsupported CLI options must not be silently discarded during restart.")
        XCTAssertEqual(row.editableConfiguration?.instanceId, "edit")
        let request = try XCTUnwrap(InstanceEditRequest(row))
        XCTAssertEqual(request.configuration, original)
    }

    func testPendingEditsForAlreadyRunningOlderBackendSurviveAppRelaunch() async throws {
        let suite = "kapitsa-edit-tests-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = config()
        let process = try fixture(original, home: home, legacy: true)
        defer { cleanup([process], home: home, preferences: preferences, suite: suite) }
        _ = try await waitForRecord(original.instanceId, home: home)
        preferences.set(try JSONEncoder().encode([original]), forKey: "runtimeProfiles")
        let store = InstanceStore(preferences: preferences, home: home, poll: false)
        await store.refresh()
        let row = try XCTUnwrap(store.selected)
        XCTAssertNil(row.snapshot?.configuration)
        XCTAssertTrue(row.canRestart)
        try await store.save(config(name: "Edited"), for: row, restart: false)
        XCTAssertTrue(store.selected?.hasPendingChanges ?? false)
        let reloaded = InstanceStore(preferences: preferences, home: home, poll: false)
        await reloaded.refresh()
        XCTAssertTrue(reloaded.selected?.hasPendingChanges ?? false)
        XCTAssertEqual(reloaded.selected?.editableConfiguration?.name, "Edited")
        XCTAssertEqual(reloaded.selected?.snapshot?.name, "Original")
    }

    func testImportingPartialLegacyCLISettingsDoesNotEnableAutomaticRestart() async throws {
        let suite = "kapitsa-edit-tests-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let process = try fixture(config(), home: home, legacy: true)
        defer { cleanup([process], home: home, preferences: preferences, suite: suite) }
        _ = try await waitForRecord("edit", home: home)
        let store = InstanceStore(preferences: preferences, home: home, poll: false)
        await store.refresh()
        let row = try XCTUnwrap(store.selected)
        XCTAssertNil(row.profile)
        XCTAssertFalse(row.canRestart, "Unknown original options must require a manual stop.")
        let imported = try XCTUnwrap(row.editableConfiguration)
        try await store.save(imported, for: row, restart: false)
        XCTAssertNotNil(store.selected?.profile)
        XCTAssertFalse(store.selected?.canRestart ?? true)
        let reloaded = InstanceStore(preferences: preferences, home: home, poll: false)
        await reloaded.refresh()
        XCTAssertFalse(reloaded.selected?.canRestart ?? true,
                       "Saving a partial profile must not silently make it a complete launch configuration.")
    }
}
