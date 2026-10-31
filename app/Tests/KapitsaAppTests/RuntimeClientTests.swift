import XCTest
@testable import KapitsaApp

final class RuntimeClientTests: XCTestCase {
    private func record(_ url: String = "http://127.0.0.1:12345", run: String = "run") throws -> RuntimeRecord {
        let values: [String: Any] = ["protocol": 1, "instance_id": "code", "run_id": run,
            "name": "Code", "pid": 42, "control_url": url, "token": "private-token"]
        return try RuntimeClient.decode(RuntimeRecord.self, from: JSONSerialization.data(withJSONObject: values))
    }

    func testControlRecordsCannotRedirectCredentials() throws {
        XCTAssertTrue(try record().valid)
        for url in ["https://example.com:12345", "http://example.com:12345", "http://127.0.0.1:12345/path",
                    "http://secret@127.0.0.1:12345", "http://127.0.0.1:12345?other=1",
                    "http://127.0.0.1:0", "http://127.0.0.1:65536"] {
            XCTAssertFalse(try record(url).valid, url)
        }
    }

    func testPrivateRegistryAndSymlinkRefusal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("code.json")
        let data = """
        {"protocol":1,"instance_id":"code","run_id":"run","name":"Code","pid":42,
         "control_url":"http://127.0.0.1:12345","token":"private-token"}
        """.data(using: .utf8)!
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: data,
                                                     attributes: [.posixPermissions: 0o600]))
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(Registry.records(in: directory).count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertTrue(Registry.records(in: directory).isEmpty)
    }

    func testNativeConfigurationMatchesBackendProtocol() throws {
        let config = RuntimeConfiguration(instanceId: "code", name: "Code", model: "27b", port: 8000,
                                          context: 90 * 1024, slots: nil)
        let data = try JSONEncoder().encode(config)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(encoded["instance_id"] as? String, "code")
        XCTAssertEqual(encoded["protocol"] as? Int, 1)
        XCTAssertNil(encoded["slots"])
        XCTAssertEqual(try JSONDecoder().decode(RuntimeConfiguration.self, from: data).instanceId, "code")
        XCTAssertEqual(try RuntimeConfiguration.contextTokens("90k"), 90 * 1024)
        XCTAssertEqual(try RuntimeConfiguration.contextTokens("1M"), 1_048_576)
        XCTAssertNil(try RuntimeConfiguration.contextTokens(""))
        for invalid in ["0", "-1", "1.5k", "max", "2m", "999999999999999999999999"] {
            XCTAssertThrowsError(try RuntimeConfiguration.contextTokens(invalid))
        }
    }

    func testSwiftClientAttachesToNativeControlPlane() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("build/runtime_test")
        guard FileManager.default.isExecutableFile(atPath: fixture.path) else {
            throw XCTSkip("Build the CPU runtime_test target to run the native integration check.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let process = Process()
        process.executableURL = fixture
        process.arguments = ["--fixture", directory.path, "swift"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: directory)
        }
        var records: [RuntimeRecord] = []
        for _ in 0..<50 {
            records = Registry.records(in: directory)
            if !records.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let record = try XCTUnwrap(records.first)
        let client = RuntimeClient()
        let first = try await client.fetch(record)
        XCTAssertEqual(first.instanceId, "swift")
        XCTAssertEqual(first.state, "ready")
        XCTAssertEqual(first.requests.first?.phase, "writing")
        try await Task.sleep(for: .milliseconds(100))
        let second = try await client.fetch(record, cursor: first.cursor)
        XCTAssertGreaterThan(second.requests[0].completionTokens, first.requests[0].completionTokens)
        XCTAssertTrue(second.events?.isEmpty == true)
        let stale = try RuntimeClient.decode(RuntimeRecord.self,
            from: JSONSerialization.data(withJSONObject: [
                "protocol": 1, "instance_id": record.instanceId, "run_id": "stale",
                "name": record.name, "pid": record.pid, "control_url": record.controlUrl, "token": record.token]))
        do {
            try await client.stop(stale)
            XCTFail("A stale execution must not stop the instance")
        } catch {}
        _ = try await client.fetch(record)
        try await client.stop(record)
        for _ in 0..<50 where process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(process.isRunning)
    }
}
