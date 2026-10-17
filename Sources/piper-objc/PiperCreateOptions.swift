import Foundation

/// Options for creating a Piper synthesizer.
/// Mirrors `piper_create_options` versioning idea – future fields can be added without breaking call sites.
///
/// This is an `NSObject` subclass so it can be used from Objective-C the same way you would use a builder.
@objcMembers
public class PiperCreateOptions: NSObject {
    /// Path to ONNX voice model file. Required.
    public var modelPath: String

    /// Path to JSON voice config file, or nil to use modelPath + ".json"
    public var configPath: String?

    /// Path to espeak-ng data directory, or nil for auto-discovery / bundled data
    public var espeakDataPath: String?

    /// Optional root data directory that may contain espeak-ng-data/ and g2pw/
    /// If espeakDataPath or g2pwModelDir is nil, library searches inside dataDir.
    public var dataDir: String?

    /// Path to g2pw / pinyin dictionary directory for Chinese, or nil for auto-discovery.
    /// Directory should contain MONOPHONIC_CHARS.txt (Phase 1) and/or char_bopomofo_dict.json etc.
    public var g2pwModelDir: String?

    /// Path to OpenJTalk dictionary directory for Japanese, or nil for auto-discovery.
    /// Directory should contain sys.dic, matrix.bin, char.bin and unk.dic
    /// (the pyopenjtalk-plus dictionary the Japanese voices were trained with).
    public var openjtalkDictDir: String?

    @objc public init(modelPath: String,
                       configPath: String? = nil,
                       espeakDataPath: String? = nil,
                       dataDir: String? = nil,
                       g2pwModelDir: String? = nil,
                       openjtalkDictDir: String? = nil) {
        self.modelPath = modelPath
        self.configPath = configPath
        self.espeakDataPath = espeakDataPath
        self.dataDir = dataDir
        self.g2pwModelDir = g2pwModelDir
        self.openjtalkDictDir = openjtalkDictDir
        super.init()
    }

    /// Convenience for ObjC where you only have model + config
    @objc public convenience init(modelPath: String, configPath: String?) {
        self.init(modelPath: modelPath, configPath: configPath, espeakDataPath: nil, dataDir: nil, g2pwModelDir: nil, openjtalkDictDir: nil)
    }
}
