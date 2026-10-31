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
