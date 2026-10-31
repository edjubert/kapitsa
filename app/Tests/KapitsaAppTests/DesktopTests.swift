import XCTest
@testable import KapitsaApp

final class DesktopTests: XCTestCase {
    @MainActor
    func testDefaultsPersistAndEnterTheNativeConfiguration() throws {
        let suite = "kapitsa-desktop-tests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let settings = AppSettings(preferences: preferences)
        var defaults = LaunchDefaults()
        defaults.model = "27b"
        defaults.context = "90k"
        defaults.slots = 2
        defaults.port = 8010
        defaults.memory = "24,5"
        defaults.diskCache = "1.5g"
        defaults.speculation = 3
        defaults.prefillChunk = 512
        defaults.useDrafter = false
        try settings.save(defaults)
        XCTAssertEqual(AppSettings(preferences: preferences).defaults, defaults)
        let config = try defaults.configuration(name: "Code", model: defaults.model,
            port: defaults.port, context: defaults.context, slots: defaults.slots)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertEqual(encoded["mem_budget_gb"] as? Double, 24.5)
        XCTAssertEqual(encoded["disk_cache"] as? String, "1.5g")
        XCTAssertEqual(encoded["prefill_chunk"] as? Int, 512)
        XCTAssertEqual(encoded["dflash"] as? String, "none")
        let process = Process()
        process.executableURL = try NativeHelper.executableURL()
        process.arguments = ["--check"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(config))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "The real native helper must accept desktop defaults")
        defaults.memory = "nan"
        XCTAssertThrowsError(try settings.save(defaults))
        XCTAssertEqual(settings.defaults.model, "27b")
        preferences.set(try JSONEncoder().encode(defaults), forKey: "launchDefaults")
        XCTAssertEqual(AppSettings(preferences: preferences).defaults, LaunchDefaults())
        for cache in ["", "auto", "0", "off", "1.5g", "512mib", ".5t"] {
            XCTAssertTrue(LaunchDefaults.validCache(cache), cache)
        }
        for cache in ["-1g", "nan", "1e99", "9999999999999999999999999999g", "512xyz"] {
            XCTAssertFalse(LaunchDefaults.validCache(cache), cache)
        }
    }

    func testTrashRejectsExternalFoldersTraversalAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("models")
        let model = root.appendingPathComponent("downloaded")
        let external = directory.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        XCTAssertEqual(try InstalledModel.trashCandidate(model.path, root: root).path, model.path)
        for invalid in [root.path, external.path, link.path, root.path + "/../external"] {
            XCTAssertThrowsError(try InstalledModel.trashCandidate(invalid, root: root), invalid)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    func testPreparingAliasAndEffectiveDirectoryProtectActiveModels() throws {
        let model = InstalledModel(id: "/models/qwen-4bit", name: "qwen:4bit", variant: "4bit",
            dir: "/models/qwen-4bit", repo: "", complete: true, managed: true, bytes: 100,
            total: 100, includes: [])
        let variant = CatalogVariant(id: "qwen:4bit", name: "4bit", quant: "4-bit", repo: "",
                                     downloadGb: 1, dir: model.dir)
        let catalog = [CatalogModel(id: "qwen", title: "Qwen", about: "", aliases: ["27b"],
                                    defaultVariant: "4bit", variants: [variant])]
        func row(model reference: String, dir: String? = nil) throws -> InstanceRow {
            var object: [String: Any] = ["protocol": 1, "instance_id": "code", "run_id": "run",
                "name": "Code", "state": "preparing", "api_url": "http://127.0.0.1:8010",
                "model": reference, "requests": [], "cursor": 0]
            if let dir { object["model_dir"] = dir }
            let state = try RuntimeClient.decode(RuntimeSnapshot.self,
                from: JSONSerialization.data(withJSONObject: object))
            return InstanceRow(id: "code", name: "Code", record: nil, snapshot: state, profile: nil, error: nil)
        }
        XCTAssertTrue(model.used(by: [try row(model: "27b")], catalog: catalog))
        XCTAssertTrue(model.used(by: [try row(model: "anything", dir: model.dir)], catalog: catalog))
        XCTAssertFalse(model.used(by: [try row(model: "another")], catalog: catalog))
    }
}
