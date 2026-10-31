import XCTest
@testable import KapitsaApp

final class ModelCapacityTests: XCTestCase {
    func testCapacityWarningsRespectBudgetPhysicalRAMAndOtherInstances() throws {
        func plan(startup: UInt64, conversation: UInt64, budget: UInt64 = 16_000_000_000) throws -> ModelCapacity {
            let data = try JSONSerialization.data(withJSONObject: ["protocol": 1, "type": "capacity",
                "capacity": ["status": "known", "budget_bytes": budget, "startup_bytes": startup,
                             "conversation_bytes": conversation, "context": 32768, "slots": 2]])
            return try XCTUnwrap(RuntimeClient.decode(ModelMessage.self, from: data).capacity)
        }
        let gb: UInt64 = 1_000_000_000
        XCTAssertNil(try plan(startup: 16 * gb, conversation: 16 * gb).warning(physicalBytes: 32 * gb))
        XCTAssertEqual(try plan(startup: 16 * gb + 1, conversation: 20 * gb)
            .warning(physicalBytes: 32 * gb), .model)
        XCTAssertEqual(try plan(startup: 40 * gb, conversation: 40 * gb, budget: 100 * gb)
            .warning(physicalBytes: 32 * gb), .model, "A custom budget cannot create physical RAM")
        XCTAssertEqual(try plan(startup: 8 * gb, conversation: 17 * gb)
            .warning(physicalBytes: 32 * gb), .context)
        let small = try plan(startup: 8 * gb, conversation: 10 * gb)
        XCTAssertEqual(small.warning(physicalBytes: 32 * gb, sharedBudgetBytes: 24 * gb,
                                     occupiedBytes: 20 * gb), .instances)
        XCTAssertNil(small.warning(physicalBytes: 32 * gb, sharedBudgetBytes: 24 * gb,
                                   occupiedBytes: 16 * gb), "The instance budget is separate from the shared limit")
        XCTAssertEqual(small.warning(physicalBytes: 32 * gb, occupiedBytes: 90 * gb), .instances)
        let unknown = try RuntimeClient.decode(ModelCapacity.self,
            from: Data(#"{"status":"unknown","budget_bytes":16000000000}"#.utf8))
        XCTAssertNil(unknown.warning(physicalBytes: 32 * gb, occupiedBytes: 90 * gb))
    }

    func testCapacityQueryTracksOnlyMemoryOptionsAndProducesNativeConfiguration() throws {
        var defaults = LaunchDefaults()
        let original = CapacityQuery(model: " 27b:4bit ", defaults: defaults)
        defaults.model = "another-default"
        defaults.port = 9010
        defaults.diskCache = "10g"
        XCTAssertEqual(original, CapacityQuery(model: "27b:4bit", defaults: defaults))
        defaults.context = "90k"
        defaults.slots = 3
        defaults.memory = "24,5"
        defaults.speculation = 0
        defaults.useDrafter = false
        defaults.prefillChunk = 512
        let changed = CapacityQuery(model: "27b:4bit", defaults: defaults)
        XCTAssertNotEqual(original, changed)
        let config = try changed.configuration()
        XCTAssertEqual(config.instanceId, "capacity")
        XCTAssertEqual(config.context, 92160)
        XCTAssertEqual(config.slots, 3)
        XCTAssertEqual(config.memBudgetGb, 24.5)
        XCTAssertEqual(config.spec, 0)
        XCTAssertEqual(config.dflash, "none")
        XCTAssertEqual(config.prefillChunk, 512)
    }

    func testNativeCapacityJobCanReportUnknownWithoutStartingAnEngine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"model_type":"unsupported_fixture"}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        let config = try CapacityQuery(model: directory.path, defaults: LaunchDefaults()).configuration()
        let job = try NativeModelJob(action: "capacity", configuration: config, budgetBytes: 16_000_000_000)
        let reply = try await job.read { _ in }
        XCTAssertEqual(reply.type, "capacity")
        XCTAssertEqual(reply.capacity?.status, "unknown")
        XCTAssertNil(reply.capacity?.startupBytes)
    }
}
