// SPDX-License-Identifier: GPL-3.0-only
import Testing
import Foundation
@testable import piper_objc

@Suite("Piper creation errors", .serialized)
struct PiperErrorTests {

    init() {
        Bundle.setupSwizzling()
    }

    @Test("Empty model path throws modelPathMissing")
    func emptyModelPathThrows() {
        let opts = PiperCreateOptions(modelPath: "")
        #expect(throws: PiperError(code: .modelPathMissing)) {
            try Piper(options: opts)
        }
    }

    @Test("Legacy init with empty model path throws modelPathMissing")
    func legacyEmptyModelPathThrows() {
        #expect(throws: PiperError(code: .modelPathMissing)) {
            try Piper(modelPath: "", configPath: "", espeakNGData: "")
        }
    }

    @Test("Missing model file throws modelFileMissing with path")
    func missingModelFileThrows() {
        let missing = "/nonexistent/path/model.onnx"
        let opts = PiperCreateOptions(modelPath: missing)
        #expect(throws: PiperError(code: .modelFileMissing, path: missing)) {
            try Piper(options: opts)
        }
    }

    @Test("Convenience init with missing model throws modelFileMissing")
    func convenienceMissingModelThrows() {
        let missing = "/nonexistent/path/model.onnx"
        #expect(throws: PiperError(code: .modelFileMissing, path: missing)) {
            try Piper(modelPath: missing, andConfigPath: "/nonexistent/path/model.onnx.json")
        }
    }

    @Test("Missing model file with both split parts passes the model check")
    func missingModelWithSplitPartsPassesModelCheck() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piper-splits-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["model.encoder.onnx", "model.decoder.onnx"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path,
                                           contents: Data("dummy".utf8))
        }
        let modelPath = dir.appendingPathComponent("model.onnx").path
        let missingConfig = dir.appendingPathComponent("model.onnx.json").path
        let opts = PiperCreateOptions(modelPath: modelPath, configPath: missingConfig)
        // Splits-only voice (issue #94): libpiper loads the split parts
        // derived from the model path, so validation must not throw
        // modelFileMissing for the absent anchor. The next check in
        // line - the missing config - is what must throw instead, which
        // also keeps this test away from the native engine.
        #expect(throws: PiperError(code: .configFileMissing, path: missingConfig)) {
            try Piper(options: opts)
        }
    }

    @Test("Missing model file with only one split part throws modelFileMissing")
    func missingModelWithOneSplitPartThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piper-splits-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("model.encoder.onnx").path,
                                       contents: Data("dummy".utf8))
        let modelPath = dir.appendingPathComponent("model.onnx").path
        let opts = PiperCreateOptions(modelPath: modelPath)
        #expect(throws: PiperError(code: .modelFileMissing, path: modelPath)) {
            try Piper(options: opts)
        }
    }

    @Test("Missing config file throws configFileMissing")
    func missingConfigFileThrows() throws {
        let modelURL = FileManager.default.temporaryDirectory.appendingPathComponent("piper-error-test-model.onnx")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data("dummy".utf8))
        defer { try? FileManager.default.removeItem(at: modelURL) }

        let missingConfig = modelURL.path + ".json"
        let opts = PiperCreateOptions(modelPath: modelURL.path, configPath: missingConfig)
        // Validation must reject the missing config before touching the engine,
        // so a dummy model file is safe here.
        #expect(throws: PiperError(code: .configFileMissing, path: missingConfig)) {
            try Piper(options: opts)
        }
    }

    @Test("Empty config file throws configFileInvalid")
    func emptyConfigFileThrows() throws {
        let dir = FileManager.default.temporaryDirectory
        let modelURL = dir.appendingPathComponent("piper-error-test-model2.onnx")
        let configURL = dir.appendingPathComponent("piper-error-test-model2.onnx.json")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data("dummy".utf8))
        FileManager.default.createFile(atPath: configURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: modelURL)
            try? FileManager.default.removeItem(at: configURL)
        }

        let opts = PiperCreateOptions(modelPath: modelURL.path, configPath: configURL.path)
        #expect(throws: PiperError(code: .configFileInvalid, path: configURL.path)) {
            try Piper(options: opts)
        }
    }

    @Test("PiperError bridges to NSError with domain, code and path")
    func nsErrorBridging() {
        let path = "/nonexistent/path/model.onnx"
        let error = PiperError(code: .modelFileMissing, path: path)
        let nsError = error as NSError
        #expect(nsError.domain == PiperError.domain)
        #expect(nsError.code == PiperErrorCode.modelFileMissing.rawValue)
        #expect(nsError.userInfo[PiperError.pathKey] as? String == path)
        let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String
        #expect(message?.isEmpty == false)
    }

    @Test("PiperError without path omits the path key")
    func nsErrorBridgingWithoutPath() {
        let nsError = PiperError(code: .engineCreationFailed) as NSError
        #expect(nsError.domain == PiperError.domain)
        #expect(nsError.code == PiperErrorCode.engineCreationFailed.rawValue)
        #expect(nsError.userInfo[PiperError.pathKey] == nil)
    }

    @Test("Error codes are stable")
    func errorCodesStable() {
        #expect(PiperErrorCode.modelPathMissing.rawValue == 1)
        #expect(PiperErrorCode.modelFileMissing.rawValue == 2)
        #expect(PiperErrorCode.configFileMissing.rawValue == 3)
        #expect(PiperErrorCode.configFileInvalid.rawValue == 4)
        #expect(PiperErrorCode.engineCreationFailed.rawValue == 5)
    }

    @Test("Every error code has a description")
    func everyCodeHasDescription() {
        let codes: [PiperErrorCode] = [
            .modelPathMissing, .modelFileMissing, .configFileMissing, .configFileInvalid, .engineCreationFailed
        ]
        for code in codes {
            #expect(!PiperError(code: code).description.isEmpty)
        }
    }

    @Test("Thrown error carries the failing path")
    func thrownErrorCarriesPath() {
        let missing = "/nonexistent/path/model.onnx"
        do {
            _ = try Piper(options: PiperCreateOptions(modelPath: missing))
            Issue.record("Expected PiperError to be thrown")
        } catch let error as PiperError {
            #expect(error.code == .modelFileMissing)
            #expect(error.path == missing)
        } catch {
            Issue.record("Expected PiperError, got \(type(of: error))")
        }
    }
}
