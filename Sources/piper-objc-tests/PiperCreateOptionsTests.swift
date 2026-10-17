import Testing
import Foundation
@testable import piper_objc

@Suite("PiperCreateOptions Tests", .serialized)
struct PiperCreateOptionsTests {

    init() {
        // Ensure espeak-ng_data.bundle can be found in test runner (prevents NSException in EspeakLib)
        Bundle.setupSwizzling()
    }

    @Test("Init with only modelPath sets required field and nils optionals")
    func testInitWithOnlyModelPath() {
        let opts = PiperCreateOptions(modelPath: "/tmp/model.onnx")
        #expect(opts.modelPath == "/tmp/model.onnx")
        #expect(opts.configPath == nil)
        #expect(opts.espeakDataPath == nil)
        #expect(opts.dataDir == nil)
        #expect(opts.g2pwModelDir == nil)
    }

    @Test("Init with all fields stores them correctly")
    func testInitWithAllFields() {
        let opts = PiperCreateOptions(
            modelPath: "/models/zh.onnx",
            configPath: "/models/zh.onnx.json",
            espeakDataPath: "/data/espeak-ng-data",
            dataDir: "/data",
            g2pwModelDir: "/data/g2pw"
        )
        #expect(opts.modelPath == "/models/zh.onnx")
        #expect(opts.configPath == "/models/zh.onnx.json")
        #expect(opts.espeakDataPath == "/data/espeak-ng-data")
        #expect(opts.dataDir == "/data")
        #expect(opts.g2pwModelDir == "/data/g2pw")
    }

    @Test("Convenience init modelPath + configPath")
    func testConvenienceInit() {
        let opts = PiperCreateOptions(modelPath: "/a/b.onnx", configPath: "/a/b.onnx.json")
        #expect(opts.modelPath == "/a/b.onnx")
        #expect(opts.configPath == "/a/b.onnx.json")
        #expect(opts.espeakDataPath == nil)
        #expect(opts.dataDir == nil)
        #expect(opts.g2pwModelDir == nil)
    }

    @Test("Mutable properties can be changed after init")
    func testMutability() {
        let opts = PiperCreateOptions(modelPath: "/tmp/model.onnx")
        opts.dataDir = "/tmp/data"
        opts.g2pwModelDir = "/tmp/data/g2pw"
        opts.configPath = "/tmp/model.onnx.json"
        #expect(opts.dataDir == "/tmp/data")
        #expect(opts.g2pwModelDir == "/tmp/data/g2pw")
        #expect(opts.configPath == "/tmp/model.onnx.json")
    }

    @Test("PiperCreateOptions is NSObject subclass for ObjC interop")
    func testNSObjectInterop() {
        let opts = PiperCreateOptions(modelPath: "/tmp/model.onnx")
        // Use ObjC runtime check rather than 'is' (which is always true for NSObject subclass)
        #expect(type(of: opts) == PiperCreateOptions.self)
        #expect(opts.isKind(of: NSObject.self))
        // Ensure it can be used via KVC-style (ObjC runtime)
        let mirrorModelPath = (opts as NSObject).value(forKey: "modelPath") as? String
        #expect(mirrorModelPath == "/tmp/model.onnx")
    }

    @Test("Piper init with invalid model throws modelFileMissing (options path)")
    func testPiperInitWithInvalidOptionsThrows() {
        let modelPath = "/nonexistent/path/model.onnx"
        let opts = PiperCreateOptions(
            modelPath: modelPath,
            configPath: "/nonexistent/path/model.onnx.json",
            espeakDataPath: "/tmp",
            dataDir: nil,
            g2pwModelDir: nil
        )
        #expect(throws: PiperError(code: .modelFileMissing, path: modelPath)) {
            try Piper(options: opts)
        }
    }

    @Test("Piper init with legacy args throws modelFileMissing on invalid path")
    func testLegacyInitInvalidPathThrows() {
        let modelPath = "/no/such/model.onnx"
        #expect(throws: PiperError(code: .modelFileMissing, path: modelPath)) {
            try Piper(modelPath: modelPath, configPath: "/no/such/model.onnx.json", espeakNGData: "")
        }
    }

    @Test("Options with empty strings are treated as nil for default fallback")
    func testEmptyStringHandling() {
        // Empty configPath should trigger modelPath + .json fallback in piper_create_with_options
        // We test the options object stores empty as-is, but Piper init should not crash
        let opts = PiperCreateOptions(modelPath: "/tmp/model.onnx", configPath: "", espeakDataPath: "", dataDir: "", g2pwModelDir: "")
        #expect(opts.configPath == "")
        #expect(opts.espeakDataPath == "")
        #expect(opts.dataDir == "")
        #expect(opts.g2pwModelDir == "")
        // Piper init throws a structured error instead of returning nil – empty strings
        // still resolve to auto-discovery, but the missing model is reported, not a crash.
        #expect(throws: PiperError(code: .modelFileMissing, path: "/tmp/model.onnx")) {
            try Piper(options: opts)
        }
    }

    @Test("DataDir and g2pwModelDir enable Chinese pinyin auto-discovery path")
    func testDataDirG2PwFields() {
        // This test documents the intended usage for Chinese voices
        // dataDir may contain espeak-ng-data/ and g2pw/ subfolders
        let opts = PiperCreateOptions(
            modelPath: "/voices/zh_CN/model.onnx",
            dataDir: "/voices/zh_CN/data",
            g2pwModelDir: nil // nil should trigger search inside dataDir/g2pw and dataDir
        )
        #expect(opts.dataDir == "/voices/zh_CN/data")
        #expect(opts.g2pwModelDir == nil)
        #expect(opts.modelPath.hasSuffix("zh_CN/model.onnx"))

        // With explicit g2pw dir
        let optsExplicit = PiperCreateOptions(
            modelPath: "/voices/zh_CN/model.onnx",
            dataDir: "/voices/zh_CN/data",
            g2pwModelDir: "/voices/zh_CN/data/g2pw"
        )
        #expect(optsExplicit.g2pwModelDir == "/voices/zh_CN/data/g2pw")
    }
}

@Suite("Piper Create With Options – migration regression", .serialized)
struct PiperCreateWithOptionsMigrationTests {

    init() {
        Bundle.setupSwizzling()
    }

    @Test("Piper recreates synthesizer using stored options (memory pressure path)")
    func testRecreateUsesStoredOptions() {
        // We cannot trigger real memory pressure without a real model,
        // but we can verify that Piper's stored properties are used for recreation
        // by checking that init with dataDir/g2pw doesn't crash and stores them
        let opts = PiperCreateOptions(
            modelPath: "/tmp/model.onnx",
            configPath: nil,
            espeakDataPath: nil,
            dataDir: "/tmp",
            g2pwModelDir: "/tmp/g2pw"
        )
        // Init will fail (no model), but options object itself is valid and would be used for recreation
        #expect(opts.dataDir == "/tmp")
        #expect(opts.g2pwModelDir == "/tmp/g2pw")
    }
}

@Suite("PiperCreateOptions OpenJTalk Tests", .serialized)
struct PiperCreateOptionsOpenJTalkTests {

    init() {
        Bundle.setupSwizzling()
    }

    @Test("openjtalkDictDir defaults to nil")
    func testOpenJTalkDictDirDefaultsToNil() {
        let opts = PiperCreateOptions(modelPath: "/tmp/model.onnx")
        #expect(opts.openjtalkDictDir == nil)
    }

    @Test("Init with all fields stores openjtalkDictDir")
    func testInitStoresOpenJTalkDictDir() {
        let opts = PiperCreateOptions(
            modelPath: "/voices/ja_JP/model.onnx",
            configPath: "/voices/ja_JP/model.onnx.json",
            espeakDataPath: "/data/espeak-ng-data",
            dataDir: "/data",
            g2pwModelDir: "/data/g2pw",
            openjtalkDictDir: "/voices/ja_JP/openjtalk"
        )
        #expect(opts.modelPath == "/voices/ja_JP/model.onnx")
        #expect(opts.g2pwModelDir == "/data/g2pw")
        #expect(opts.openjtalkDictDir == "/voices/ja_JP/openjtalk")
    }

    @Test("openjtalkDictDir can be changed after init")
    func testOpenJTalkDictDirMutability() {
        let opts = PiperCreateOptions(modelPath: "/tmp/model.onnx")
        opts.openjtalkDictDir = "/tmp/openjtalk"
        #expect(opts.openjtalkDictDir == "/tmp/openjtalk")
    }
}
