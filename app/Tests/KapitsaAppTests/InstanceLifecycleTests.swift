import XCTest
import Darwin
@testable import KapitsaApp

@MainActor
final class InstanceLifecycleTests: XCTestCase {
    private var home: URL!
    private var suite: String!
    private var preferences: UserDefaults!
    private var processes: [Process] = []

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "kapitsa-lifecycle-tests-\(UUID())"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        for process in processes {
            if process.isRunning { process.terminate() }
            try await waitForExit(process)
        }
        processes = []
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }

    private func config(_ id: String, port: Int = 8000) -> RuntimeConfiguration {
        RuntimeConfiguration(instanceId: id, name: "Same name", model: "fake", port: port,
                             context: 92160, slots: 2, spec: 0, dflash: "none")
    }

    private func fixture(_ config: RuntimeConfiguration) throws -> Process {
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
        try process.run()
        processes.append(process)
        return process
    }

    private func record(_ id: String) async throws -> RuntimeRecord {
        for _ in 0..<100 {
            if let value = Registry.records(in: home.appendingPathComponent("instances"))
                .first(where: { $0.instanceId == id }) { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RuntimeFailure.message("CPU fixture did not publish its record.")
    }

    private func waitForExit(_ process: Process) async throws {
        for _ in 0..<100 {
            if !process.isRunning { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RuntimeFailure.message("CPU fixture did not exit.")
    }

    private func store() -> InstanceStore {
        InstanceStore(preferences: preferences, home: home, poll: false) { try self.fixture($0) }
    }

    func testCrashDoesNotPreventStartingSavedInstanceOrAffectOtherOwner() async throws {
        let configuration = config("first")
        preferences.set(try JSONEncoder().encode([configuration]), forKey: "runtimeProfiles")
        let crashed = try fixture(configuration)
        _ = try fixture(config("second", port: 8001))
        let first = try await record("first")
        let second = try await record("second")
        // Kill only this engine-free test child, leaving the real crash record.
        XCTAssertEqual(kill(crashed.processIdentifier, SIGKILL), 0)
        try await waitForExit(crashed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("instances/first.json").path))
        let instances = store()
        await instances.refresh()
        let stopped = try XCTUnwrap(instances.rows.first { $0.id == "first" })
        XCTAssertNil(stopped.record)
        XCTAssertEqual(stopped.lifecycle, "stopped")
        XCTAssertEqual(stopped.profile, configuration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("instances/first.lock").path))
        let started = await instances.start(configuration)
        XCTAssertTrue(started, instances.lastError ?? "")
        let next = try await record("first")
        XCTAssertEqual(next.instanceId, first.instanceId)
        XCTAssertNotEqual(next.runId, first.runId)
        XCTAssertTrue(instances.startingIDs.isEmpty)
        let other = try await RuntimeClient().status(second)
        XCTAssertEqual(other.runId, second.runId)
    }

    func testDeleteStoppedProfilePreservesModelsChatAndPersistsAcrossRelaunch() async throws {
        let configurations = [config("first"), config("second", port: 8001)]
        preferences.set(try JSONEncoder().encode(configurations), forKey: "runtimeProfiles")
        preferences.set(["first": "previous"], forKey: "runtimePendingEdits")
        preferences.set(["first"], forKey: "runtimeIncompleteProfiles")
        let models = home.appendingPathComponent("models/fake")
        let chat = home.appendingPathComponent("chats/first.json")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Saved chat".utf8).write(to: chat)
        let instances = store()
        await instances.refresh()
        let target = try XCTUnwrap(instances.rows.first { $0.id == "first" })
        instances.selectedId = target.id
        let deleted = await instances.delete(target)
        XCTAssertTrue(deleted, instances.lastError ?? "")
        XCTAssertEqual(instances.rows.map(\.id), ["second"])
        XCTAssertEqual(instances.selectedId, "second")
        XCTAssertTrue(instances.deletingIDs.isEmpty)
        XCTAssertNil(preferences.dictionary(forKey: "runtimePendingEdits")?["first"])
        XCTAssertEqual(preferences.stringArray(forKey: "runtimeIncompleteProfiles"), [])
        let reloaded = store()
        await reloaded.refresh()
        XCTAssertEqual(reloaded.rows.map(\.id), ["second"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: models.path))
        XCTAssertEqual(try Data(contentsOf: chat), Data("Saved chat".utf8))
    }

    func testDeleteStopsOnlyCapturedInstanceAndPreventsConcurrentStart() async throws {
        let configuration = config("first")
        preferences.set(try JSONEncoder().encode([configuration]), forKey: "runtimeProfiles")
        _ = try fixture(configuration)
        _ = try fixture(config("second", port: 8001))
        _ = try await record("first")
        let second = try await record("second")
        let instances = store()
        await instances.refresh()
        let target = try XCTUnwrap(instances.rows.first { $0.id == "first" })
        let deletion = Task { await instances.delete(target) }
        for _ in 0..<50 where !instances.deletingIDs.contains("first") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(instances.deletingIDs.contains("first"))
        let attemptedStart = await instances.start(configuration)
        XCTAssertFalse(attemptedStart)
        let deleted = await deletion.value
        XCTAssertTrue(deleted, instances.lastError ?? "")
        XCTAssertNil(instances.rows.first { $0.id == "first" })
        XCTAssertEqual(processes.count, 2)
        let unaffected = try await RuntimeClient().status(second)
        XCTAssertEqual(unaffected.runId, second.runId)
        let reloaded = store()
        await reloaded.refresh()
        XCTAssertNil(reloaded.rows.first { $0.id == "first" })
    }

    func testDeletionConfirmationCannotRemoveReplacementExecution() async throws {
        let configuration = config("first")
        preferences.set(try JSONEncoder().encode([configuration]), forKey: "runtimeProfiles")
        let instances = store()
        await instances.refresh()
        let stoppedTarget = try XCTUnwrap(instances.selected)
        _ = try fixture(configuration)
        let first = try await record("first")
        await instances.refresh()
        let liveTarget = try XCTUnwrap(instances.selected)
        try await RuntimeClient().stop(first)
        try await waitForExit(processes[0])
        _ = try fixture(configuration)
        let next = try await record("first")
        XCTAssertNotEqual(next.runId, first.runId)
        for target in [stoppedTarget, liveTarget] {
            let deleted = await instances.delete(target)
            XCTAssertFalse(deleted)
            XCTAssertTrue(instances.lastError?.contains("redémarré") == true)
            let state = try await RuntimeClient().status(next)
            XCTAssertEqual(state.runId, next.runId)
            XCTAssertEqual(instances.selected?.profile, configuration)
        }
    }

    func testUnreachableOwnerIsNotPrunedStartedOverOrForgotten() async throws {
        let configuration = config("first")
        preferences.set(try JSONEncoder().encode([configuration]), forKey: "runtimeProfiles")
        _ = try fixture(configuration)
        let owner = try await record("first")
        let file = home.appendingPathComponent("instances/first.json")
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        values["control_url"] = "http://127.0.0.1:1"
        try JSONSerialization.data(withJSONObject: values).write(to: file)
        let instances = store()
        await instances.refresh()
        let target = try XCTUnwrap(instances.selected)
        XCTAssertNil(target.snapshot)
        XCTAssertEqual(target.lifecycle, "unreachable")
        XCTAssertNotNil(target.record)
        let started = await instances.start(configuration)
        XCTAssertFalse(started)
        let deleted = await instances.delete(target)
        XCTAssertFalse(deleted)
        XCTAssertTrue(instances.lastError?.contains("conservée") == true)
        instances.forget(target)
        XCTAssertNotNil(instances.selected?.profile)
        let state = try await RuntimeClient().status(owner)
        XCTAssertEqual(state.runId, owner.runId)
        XCTAssertTrue(processes[0].isRunning)
    }

    func testOrphanCleanupRefusesChangedRunAndUnsafeLock() async throws {
        let process = try fixture(config("first"))
        let owner = try await record("first")
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        try await waitForExit(process)
        let directory = home.appendingPathComponent("instances")
        let file = directory.appendingPathComponent("first.json")
        let lock = directory.appendingPathComponent("first.lock")
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        values["run_id"] = "replacement"
        try JSONSerialization.data(withJSONObject: values).write(to: file)
        XCTAssertFalse(Registry.removeOrphan(owner, in: directory))
        let replacement = try XCTUnwrap(Registry.records(in: directory).first)
        try FileManager.default.removeItem(at: lock)
        XCTAssertFalse(Registry.removeOrphan(replacement, in: directory))
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: file)
        XCTAssertFalse(Registry.removeOrphan(replacement, in: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testNativeLaunchTransportAndImmediateFailureUseCurrentDiagnostics() async throws {
        let configuration = config("first")
        let valid = try NativeHelper.launch(configuration, home: home, arguments: ["--check"])
        processes.append(valid)
        try await waitForExit(valid)
        XCTAssertEqual(valid.terminationStatus, 0)
        let log = home.appendingPathComponent("logs/instance-first.log")
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("\"status\":\"valid\""))
        let instances = InstanceStore(preferences: preferences, home: home, poll: false) { configuration in
            var invalid = configuration
            invalid.protocolVersion = 2
            let failed = try NativeHelper.launch(invalid, home: self.home, arguments: ["--check"])
            self.processes.append(failed)
            return failed
        }
        let started = await instances.start(configuration)
        XCTAssertFalse(started)
        XCTAssertTrue(instances.lastError?.contains("protocol") == true, instances.lastError ?? "")
        XCTAssertTrue(instances.lastError?.contains("code 2") == true)
        XCTAssertEqual(instances.selected?.profile, configuration)
        XCTAssertTrue(instances.startingIDs.isEmpty)
        XCTAssertTrue(Registry.records(in: home.appendingPathComponent("instances")).isEmpty)
    }
}
