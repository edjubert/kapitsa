import XCTest
import AppIntents
@testable import KapitsaApp

@MainActor
final class WidgetTests: XCTestCase {
    private var processes: [Process] = []
    private var home: URL!
    private var suite: String!
    private var preferences: UserDefaults!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "kapitsa-widget-tests-\(UUID())"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        WidgetActionRouter.perform = nil
        for process in processes {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        processes = []
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
    }

    private func config(_ id: String, port: Int) -> RuntimeConfiguration {
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

    private func record(_ id: String, excluding run: String? = nil) async throws -> RuntimeRecord {
        for _ in 0..<100 {
            if let value = Registry.records(in: home.appendingPathComponent("instances"))
                .first(where: { $0.instanceId == id && $0.runId != run }) { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RuntimeFailure.message("CPU fixture did not publish its record.")
    }

    private func store() -> InstanceStore {
        InstanceStore(preferences: preferences, home: home, poll: false) { try self.fixture($0) }
    }

    func testPickerKeepsDuplicateNamesDistinctAndDoesNotChooseBetweenSeveralInstances() async throws {
        let storage = WidgetSharedStorage(directory: home.appendingPathComponent("shared"))
        var first = WidgetInstance.example
        first.name = "Same name"
        let second = WidgetInstance(id: "second", name: first.name, model: "4b",
            state: .stopped, canStart: true)
        let query = KapitsaInstanceQuery(storage: storage)
        try storage.publish(WidgetInventory(updatedAt: Date(), instances: [first]), connections: [])
        let single = await query.defaultResult()
        XCTAssertEqual(single?.id, first.id)
        try storage.publish(WidgetInventory(updatedAt: Date(), instances: [first, second]), connections: [])
        let ambiguous = await query.defaultResult()
        XCTAssertNil(ambiguous)
        let candidates = try await query.suggestedEntities()
        XCTAssertEqual(candidates.count, 2)
        let selected = try await query.entities(for: ["second"])
        XCTAssertEqual(selected.map(\.id), ["second"])
        let removed = try await query.entities(for: ["removed"])
        XCTAssertEqual(removed.map(\.id), ["removed"], "Keep the missing selection so its widget can show an error.")
        let invalid = try await query.entities(for: ["../second"])
        XCTAssertTrue(invalid.isEmpty)
    }

    func testSharedDisplayHasNoCredentialsAndRequiresPrivateFiles() async throws {
        _ = try fixture(config("first", port: 8000))
        let connection = try await record("first")
        let snapshot = try await RuntimeClient().fetch(connection)
        let storage = WidgetSharedStorage(directory: home.appendingPathComponent("shared"))
        let display = WidgetInstance.live(snapshot, canStart: true)
        let inventory = WidgetInventory(updatedAt: Date(), instances: [display])
        try storage.publish(inventory, connections: [connection])
        XCTAssertEqual(storage.inventory(), inventory)
        XCTAssertEqual(storage.connections(), [connection])
        let data = try Data(contentsOf: storage.directory.appendingPathComponent("instances.json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(connection.token))
        XCTAssertFalse(text.contains(connection.controlUrl))
        XCTAssertFalse(text.contains("token\""))
        let privateFile = storage.directory.appendingPathComponent("connections.json")
        XCTAssertTrue(Registry.privatePath(privateFile, directory: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: privateFile.path)
        XCTAssertTrue(storage.connections().isEmpty)
        try FileManager.default.removeItem(at: privateFile)
        let other = home.appendingPathComponent("copy.json")
        try JSONEncoder().encode([connection]).write(to: other)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: other.path)
        try FileManager.default.createSymbolicLink(at: privateFile, withDestinationURL: other)
        XCTAssertTrue(storage.connections().isEmpty)
    }

    func testWidgetReadsLiveTargetWithoutAppAndNeverFallsBackToOtherInstance() async throws {
        _ = try fixture(config("first", port: 8000))
        _ = try fixture(config("second", port: 8001))
        let first = try await record("first")
        let second = try await record("second")
        let storage = WidgetSharedStorage(directory: home.appendingPathComponent("shared"))
        let snapshot = try await RuntimeClient().fetch(first)
        let original = WidgetInstance.live(snapshot, canStart: true)
        try storage.publish(WidgetInventory(updatedAt: Date(), instances: [original]),
                            connections: [first, second])
        try await Task.sleep(for: .milliseconds(150))
        let liveValue = await WidgetStatusReader.read(id: "first", storage: storage)
        let live = try XCTUnwrap(liveValue)
        XCTAssertEqual(live.id, "first")
        XCTAssertEqual(live.state, .busy)
        XCTAssertEqual(live.context, 92160)
        XCTAssertGreaterThan(live.completionTokens ?? 0, original.completionTokens ?? 0)
        let missing = await WidgetStatusReader.read(id: "second", storage: storage)
        XCTAssertNil(missing, "A missing configured target must not use a different instance.")
        try await RuntimeClient().stop(first)
        processes[0].waitUntilExit()
        let unreachableValue = await WidgetStatusReader.read(id: "first", storage: storage)
        let unreachable = try XCTUnwrap(unreachableValue)
        XCTAssertEqual(unreachable.state, .unreachable)
        XCTAssertFalse(unreachable.canLaunch, "An unreachable execution must not be presented as stopped.")
        XCTAssertFalse(unreachable.canStop)
        _ = try await RuntimeClient().fetch(second)
    }

    func testWidgetIntentsKeepCLIIdentityOptionsAndDoNotStopAnotherInstance() async throws {
        let configuration = config("first", port: 8000)
        _ = try fixture(configuration)
        _ = try fixture(config("second", port: 8001))
        let first = try await record("first")
        let second = try await record("second")
        let instances = store()
        WidgetActionRouter.perform = { try await instances.handleWidget($0) }
        // Exercise the same AppIntent entry points used by WidgetKit.
        _ = try await StopKapitsaInstanceIntent(id: "first", run: first.runId).perform()
        processes[0].waitUntilExit()
        await instances.refresh()
        XCTAssertEqual(instances.selected?.profile, configuration)
        XCTAssertNil(instances.selected?.record)
        _ = try await RuntimeClient().fetch(second)
        _ = try await StartKapitsaInstanceIntent(id: "first").perform()
        let next = try await record("first", excluding: first.runId)
        XCTAssertEqual(next.instanceId, first.instanceId)
        XCTAssertNotEqual(next.runId, first.runId)
        let live = try await RuntimeClient().fetch(next)
        XCTAssertEqual(live.configuration?.value, configuration)
        do {
            _ = try await StopKapitsaInstanceIntent(id: "first", run: first.runId).perform()
            XCTFail("A stale widget must not stop a newer execution.")
        } catch {}
        _ = try await RuntimeClient().fetch(next)
        let other = try await RuntimeClient().fetch(second)
        XCTAssertEqual(other.runId, second.runId)
        XCTAssertEqual(instances.selectedId, "first")
    }

    func testInvalidRemovedAndAlreadyRunningTargetsCannotLaunch() async throws {
        let configuration = config("first", port: 8000)
        preferences.set(try JSONEncoder().encode([configuration]), forKey: "runtimeProfiles")
        let instances = store()
        for id in ["../first", "removed"] {
            do {
                try await instances.handleWidget(.start(id))
                XCTFail("Unknown or invalid IDs cannot start anything.")
            } catch {}
        }
        XCTAssertTrue(processes.isEmpty)
        try await instances.handleWidget(.start("first"))
        let live = try await record("first")
        do {
            try await instances.handleWidget(.start("first"))
            XCTFail("Repeated start cannot create a second execution.")
        } catch {}
        XCTAssertEqual(processes.count, 1)
        _ = try await RuntimeClient().fetch(live)
        await instances.refresh()
        instances.forget(try XCTUnwrap(instances.selected))
        XCTAssertNotNil(instances.selected, "A running profile must not be forgotten.")
    }
}
