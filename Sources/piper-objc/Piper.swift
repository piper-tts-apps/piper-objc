import Foundation
import piper_utils
import piper
import libespeak_ng

@objc public protocol PiperDelegate: AnyObject {
    func piperDidReceiveSamples(_ samples: UnsafePointer<Float>, withSize count: Int)
    func piperDidGenerateMarkers(_ markers: [PiperSpeechMarker])
}

// Swift-only extension – alignment callback is optional via default impl (keeps @objc compat)
public extension PiperDelegate {
    func piperDidReceiveAlignment(groups: [PiperAlignmentParser.PhonemeGroup]) {
        // default no-op; implementors can override for highlighting
    }
}

@objc public enum PiperStatus: Int {
    case created
    case rendering
    case completed
    case error
    case canceled
}

@objcMembers
public class Piper: NSObject {
    private var synthesizer: OpaquePointer?
    private let modelPath: String
    private let configPath: String
    private let espeakData: String
    private let dataDir: String?
    private let g2pwModelDir: String?
    private let openjtalkDictDir: String?

    private let dispatchQueue: DispatchQueue = {
        DispatchQueue(label: "\(Piper.self).main", qos: .userInteractive)
    }()
    private lazy var operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        queue.underlyingQueue = self.dispatchQueue
        return queue
    }()
    public var memoryThresholdBytes: UInt64? = nil
    private var totalSSMLBytesGenerated = 0
    private let ssmlParser = SSMLParser()
    private var _status: PiperStatus = .created
    private let statusLock = NSLock()
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    public weak var delegate: PiperDelegate?

    public var status: PiperStatus {
        get {
            statusLock.lock()
            defer { statusLock.unlock() }
            return _status
        }
        set {
            statusLock.lock()
            defer { statusLock.unlock() }
            _status = newValue
        }
    }

    private static let espeakOnce: Void = {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let root = URL(fileURLWithPath: documentsPath)
        let fm = FileManager.default
        let dataRoot = root.appendingPathComponent("espeak-ng-data")
        // If already installed, nothing to do
        if fm.fileExists(atPath: dataRoot.path) { return }

        // EspeakLib only searches bundleWithPath:@"espeak-ng_data.bundle" and mainBundle.
        // If those fail it throws NSException (bundleWithURL:nil). We must not call it in that case.
        let espeakLibWillFind: Bool = {
            if fm.fileExists(atPath: "espeak-ng_data.bundle") { return true }
            if Bundle.main.url(forResource: "espeak-ng_data", withExtension: "bundle") != nil { return true }
            return false
        }()

        guard espeakLibWillFind else {
            // Bundle may exist in test bundle / allBundles but EspeakLib wouldn't find it.
            // Skip calling it to avoid crash – Piper init will fail gracefully later if data needed,
            // or integration tests will have swizzled mainBundle to make the above true.
            return
        }

        // EspeakLib.ensureBundleInstalled can still throw NSException if its internal lookup fails
        // despite our check (race / swizzle timing). try? doesn't catch NSException, but the pre-check
        // above prevents the known nil-URL throw. If it still throws, the process would abort – we
        // accept that as a bug in EspeakLib, but our guard makes it extremely unlikely.
        _ = try? EspeakLib.ensureBundleInstalled(inRoot: root)
    }()

    private static func ensureEspeakLibDataInstalled() -> String {
        _ = espeakOnce
        return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
    }

    /// Validates creation inputs before touching the native engine.
    /// Throws ``PiperError`` describing the first problem found.
    private static func validateCreationInputs(modelPath: String, configPath: String?) throws {
        if modelPath.isEmpty {
            throw PiperError(code: .modelPathMissing)
        }
        if !FileManager.default.fileExists(atPath: modelPath) {
            throw PiperError(code: .modelFileMissing, path: modelPath)
        }
        guard let configPath, !configPath.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: configPath) {
            throw PiperError(code: .configFileMissing, path: configPath)
        }
        // Guard against empty config – piper C++ throws on empty config
        // (nlohmann::json parse_error) and would abort the process.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: configPath),
           let size = attrs[.size] as? UInt64, size == 0 {
            throw PiperError(code: .configFileInvalid, path: configPath)
        }
    }

    private static func makeSynthesizer(modelPath: String, configPath: String?, espeakData: String, dataDir: String? = nil, g2pwDir: String? = nil, openjtalkDir: String? = nil) throws -> OpaquePointer {
        try validateCreationInputs(modelPath: modelPath, configPath: configPath)

        var opts = piper_create_options()
        opts.struct_size = MemoryLayout<piper_create_options>.size
        opts.model_path = nil
        opts.config_path = nil
        opts.espeak_data_path = nil
        opts.g2pw_model_dir = nil
        opts.data_dir = nil
        opts.openjtalk_dict_dir = nil

        func withOptionalCString<T>(_ str: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
            guard let s = str, !s.isEmpty else { return body(nil) }
            return s.withCString { body($0) }
        }

        let synthesizer = withOptionalCString(modelPath) { modelC in
            withOptionalCString(configPath) { configC in
                withOptionalCString(espeakData) { espeakC in
                    withOptionalCString(dataDir) { dataDirC in
                        withOptionalCString(g2pwDir) { g2pwC in
                            withOptionalCString(openjtalkDir) { openjtalkC in
                                var mutableOpts = opts
                                mutableOpts.model_path = modelC
                                mutableOpts.config_path = configC
                                mutableOpts.espeak_data_path = espeakC
                                mutableOpts.data_dir = dataDirC
                                mutableOpts.g2pw_model_dir = g2pwC
                                mutableOpts.openjtalk_dict_dir = openjtalkC
                                return piper_create_with_options(&mutableOpts)
                            }
                        }
                    }
                }
            }
        }
        guard let synthesizer else {
            throw PiperError(code: .engineCreationFailed, path: modelPath)
        }
        return synthesizer
    }

    private static func makeSynthesizer(options: PiperCreateOptions) throws -> OpaquePointer {
        // Early exit for missing model – avoid triggering espeak bundle installation (which can
        // throw NSException in test runners) when we already know we will fail.
        try validateCreationInputs(modelPath: options.modelPath, configPath: options.configPath)

        // Resolve espeak path via same logic as init – ensure bundled data if nil/empty
        let espeakPath: String
        if let p = options.espeakDataPath, !p.isEmpty {
            espeakPath = p
        } else {
            espeakPath = Piper.ensureEspeakLibDataInstalled()
        }
        let configPath = options.configPath?.isEmpty == false ? options.configPath : nil
        return try makeSynthesizer(modelPath: options.modelPath,
                                   configPath: configPath,
                                   espeakData: espeakPath,
                                   dataDir: options.dataDir,
                                   g2pwDir: options.g2pwModelDir,
                                   openjtalkDir: options.openjtalkDictDir)
    }

    func recreateSynthesizer() {
        dispatchPrecondition(condition: .onQueue(dispatchQueue))
        releaseSynthesizer()
        synthesizer = try? Self.makeSynthesizer(modelPath: modelPath,
                                                configPath: configPath.isEmpty ? nil : configPath,
                                                espeakData: espeakData,
                                                dataDir: dataDir,
                                                g2pwDir: g2pwModelDir,
                                                openjtalkDir: openjtalkDictDir)
    }
    
    private func releaseSynthesizer() {
        dispatchPrecondition(condition: .onQueue(dispatchQueue))

        guard let syn = synthesizer else { return }

        piper_free(syn)
        synthesizer = nil
    }

    public convenience init(modelPath: String, andConfigPath modelConfigPath: String) throws {
        try self.init(modelPath: modelPath,
                      configPath: modelConfigPath,
                      espeakNGData: "",
                      dataDir: nil,
                      g2pwModelDir: nil)
    }

    /// Designated initializer using options object – preferred path for piper_create_with_options migration.
    /// This is the ObjC-friendly entry point that mirrors piper_create_options versioning.
    /// Throws ``PiperError`` (bridged to `NSError` with domain `PiperError/domain`) on failure.
    /// In Objective-C this imports as `initWithOptions:error:`.
    @objc public init(options: PiperCreateOptions) throws {
        // Fail fast for missing model – avoids triggering espeak bundle installation (which can
        // throw NSException in test runners) when we know init will fail anyway.
        try Self.validateCreationInputs(modelPath: options.modelPath, configPath: options.configPath)

        let espeakResolved = options.espeakDataPath?.isEmpty == false ? options.espeakDataPath! : Piper.ensureEspeakLibDataInstalled()
        self.modelPath = options.modelPath
        self.configPath = options.configPath ?? ""
        self.espeakData = espeakResolved
        self.dataDir = options.dataDir
        self.g2pwModelDir = options.g2pwModelDir
        self.openjtalkDictDir = options.openjtalkDictDir
        super.init()
        self.operationQueue.name = "\(type(of: self))Queue"

        self.synthesizer = try Self.makeSynthesizer(options: options)
        self.status = .created
        setupMemoryPressureMonitoring()
    }

    public init(modelPath: String, configPath: String, espeakNGData: String, dataDir: String? = nil, g2pwModelDir: String? = nil, openjtalkDictDir: String? = nil) throws {
        // Fail fast for missing model – mirrors options path and avoids espeak bundle work when doomed
        try Self.validateCreationInputs(modelPath: modelPath, configPath: configPath.isEmpty ? nil : configPath)

        let opts = PiperCreateOptions(modelPath: modelPath,
                                      configPath: configPath.isEmpty ? nil : configPath,
                                      espeakDataPath: espeakNGData.isEmpty ? nil : espeakNGData,
                                      dataDir: dataDir,
                                      g2pwModelDir: g2pwModelDir,
                                      openjtalkDictDir: openjtalkDictDir)
        self.modelPath = modelPath
        self.configPath = configPath
        self.espeakData = espeakNGData.isEmpty ? Piper.ensureEspeakLibDataInstalled() : espeakNGData
        self.dataDir = dataDir
        self.g2pwModelDir = g2pwModelDir
        self.openjtalkDictDir = openjtalkDictDir
        super.init()
        self.operationQueue.name = "\(type(of: self))Queue"

        self.synthesizer = try Self.makeSynthesizer(options: opts)
        self.status = .created
        setupMemoryPressureMonitoring()
    }

    deinit {
        cancel()
        if let syn = synthesizer {
            piper_free(syn)
            synthesizer = nil
        }
        memoryPressureSource?.cancel()
    }

    public func completed() -> Bool {
        return status == .completed
    }

    public func cancel() {
        status = .canceled
        totalSSMLBytesGenerated = 0
        operationQueue.cancelAllOperations()
        // Don't block if we're already on the queue – avoids potential deadlock
        if OperationQueue.current != operationQueue {
            operationQueue.waitUntilAllOperationsAreFinished()
        }
    }

    // MARK: - Synthesis

    public func synthesize(_ text: String) {
        addClearBeforeStartingOperation()
        totalSSMLBytesGenerated = 0
        
        operationQueue.addOperation { [weak self] in
            guard let self = self else { return }
            let options = piper_default_synthesize_options(self.synthesizer)
            // Create a dummy SSMLNode to represent the plain text.
            // This unifies the synthesis pipeline for marker generation.
            let ssmlFragment = SSMLNode(text: text, lengthScale: options.length_scale, ssmlRange: NSRange(location: 0, length: (text as NSString).length))
            self.doSynthesize(text: text, options: options, ssmlFragment: ssmlFragment, onChunkReady: { chunk in
                self.delegate?.piperDidReceiveSamples(chunk.samples, withSize: Int(chunk.num_samples))
            }, onMarkers: { markers in
                if !markers.isEmpty {
                    self.delegate?.piperDidGenerateMarkers(markers)
                }
            })
        }
        addMarkAsCompleteOperation(nil)
    }

    public func synthesize(_ text: String, toFileAtPath path: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.synthesize(text, toFileAtPath: path) {
                continuation.resume()
            }
        }
    }

    public func synthesize(_ text: String, toFileAtPath path: String, completion: (() -> Void)? = nil) {
        addClearBeforeStartingOperation()
        
        operationQueue.addOperation { [weak self] in
            guard let self = self, let syn = self.synthesizer else { return }
            let options = piper_default_synthesize_options(syn)
            let pathURL = URL(fileURLWithPath: path)
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let fileHandle = try? FileHandle(forWritingTo: pathURL) else { return }
            defer { try? fileHandle.close() }
            
            var isHeaderWritten = false
            self.doSynthesize(text: text, options: options, ssmlFragment: nil, onChunkReady: { chunk in
                self.writeWavChunk(to: fileHandle, chunk: chunk, isHeaderWritten: &isHeaderWritten)
            })
        }
        addMarkAsCompleteOperation(completion)
    }

    public func synthesizeSSML(_ ssml: String, speakerId: Int32) {
        addClearBeforeStartingOperation()
        totalSSMLBytesGenerated = 0
        
        operationQueue.addOperation { [weak self] in
            guard let self = self else { return }
            self.ssmlParser.parse(ssml: ssml) { [weak self] fragment in
                guard let self = self, self.status == .rendering else { return }
                autoreleasepool {
                    let options = self.getOptions(for: fragment, speakerId: speakerId)
                    self.doSynthesize(text: fragment.text, options: options, ssmlFragment: fragment, onChunkReady: { chunk in
                        self.delegate?.piperDidReceiveSamples(chunk.samples, withSize: Int(chunk.num_samples))
                    }, onMarkers: { markers in
                        if !markers.isEmpty {
                            self.delegate?.piperDidGenerateMarkers(markers)
                        }
                    })
                }
            }
        }
        
        addMarkAsCompleteOperation(nil)
    }

    public func synthesizeSSML(_ ssml: String, speakerId: Int32, toFileAtPath path: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.synthesizeSSML(ssml, speakerId: speakerId, toFileAtPath: path) {
                continuation.resume()
            }
        }
    }

    public func synthesizeSSML(_ ssml: String, speakerId: Int32, toFileAtPath path: String, completion: (() -> Void)? = nil) {
        addClearBeforeStartingOperation()
        
        operationQueue.addOperation { [weak self] in
            guard let self = self else { return }
            
            let pathURL = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: pathURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: nil)
            
            guard let fileHandle = try? FileHandle(forWritingTo: pathURL) else { return }
            defer { try? fileHandle.close() }

            var isHeaderWritten = false
            self.parseAndSynthesizeSSML(ssml: ssml, speakerId: speakerId) { [weak self] chunk in
                self?.writeWavChunk(to: fileHandle, chunk: chunk, isHeaderWritten: &isHeaderWritten)
            }
        }
        
        addMarkAsCompleteOperation(completion)
    }
    
    public static var piperVersion: String? {
        return piper_version().map { String(cString: $0) }
    }

    // MARK: - Private

    func getMemoryUsage() -> UInt64? {
        return MemoryInfo.getMemoryUsage()
    }

    private func setupMemoryPressureMonitoring() {
        // This works in both the main app and app extensions.
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: dispatchQueue)
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self = self else { return }

            guard let event = self.memoryPressureSource?.data else {
                return
            }
            if event.contains(.critical) {
                self.releaseSynthesizer()
            } else if event.contains(.warning) {
                self.recreateSynthesizer()
            }
        }
        memoryPressureSource?.resume()
    }

    private static let speedCurve: [(rate: Float, speed: Float)] = [
        (0.20, 0.5001928457),
        (0.25, 0.5550218062),
        (0.30, 0.6285364609),
        (0.35, 0.7189278745),
        (0.40, 0.8310849027),
        (0.45, 0.9119920277),
        (0.50, 1.0000000000),
        (0.55, 1.2926956961),
        (0.60, 1.5843505525),
        (0.65, 1.8302883372),
        (0.70, 2.0000000000),
        (0.75, 2.1000000000),
        (0.80, 2.1500000000),
        (0.85, 2.1800000000),
        (0.90, 2.2000000000),
        (0.95, 2.2000000000),
        (1.00, 2.2000000000)
    ]

    internal static func speedRatio(for rate: Float) -> Float {
        if rate <= speedCurve[0].rate {
            return speedCurve[0].speed
        }

        let lastIndex = speedCurve.count - 1

        if rate >= speedCurve[lastIndex].rate {
            // Clamp – do not extrapolate beyond 1.0. 1.0 = 3.944 is max.
            // Extrapolation made 2.0 => 7.88x super fast (bug). Multiplier path handles >1.0.
            return speedCurve[lastIndex].speed
        }

        var low = 0
        var high = lastIndex

        while low <= high {
            let mid = (low + high) / 2
            let point = speedCurve[mid]

            if point.rate < rate {
                low = mid + 1
            } else if point.rate > rate {
                high = mid - 1
            } else {
                return point.speed
            }
        }

        let lower = speedCurve[high]
        let upper = speedCurve[low]

        let progress = (rate - lower.rate) / (upper.rate - lower.rate)
        return lower.speed + progress * (upper.speed - lower.speed)
    }
    private func getOptions(for fragment: SSMLNode, speakerId: Int32) -> piper_synthesize_options {
        var options = piper_default_synthesize_options(synthesizer)

        let rate = fragment.lengthScale
        let lengthScale: Float

        // Distinguish AV rate (0.2-1.0, 0.5 normal) vs multiplier (0.5-2.0, 1.0 normal)
        // 1.0 is ambiguous: AV fastest (0.253) vs multiplier normal (1.0).
        // Since Apple normal is 0.5, 1.0 as AV fastest is rare; treat 1.0 as multiplier normal for UI safety.
        // AV path: 0.2 <= rate < 1.0  (0.5 -> 1.0 speed -> length 1.0)
        // Multiplier path: rate ==1.0, rate <0.2, rate >1.0  (1/rate)
        if rate >= 0.2 && rate < 1.0 {
            let speedRatio = Piper.speedRatio(for: rate)
            lengthScale = max(0.1, min(1.0 / speedRatio, 10.0))
        } else if rate == 1.0 {
            lengthScale = 1.0
        } else {
            // Multiplier path: 0.5 slow => 2.0, 1.5 fast => 0.666, 2.0 double => 0.5
            // Also handles <0.2 and >1.0
            if rate <= 0 {
                lengthScale = 1.0
            } else {
                lengthScale = max(0.1, min(1.0 / rate, 10.0))
            }
        }

        options.length_scale = lengthScale
        options.speaker_id = speakerId

        return options
    }

    private func doSynthesize(text: String, options: piper_synthesize_options, ssmlFragment: SSMLNode? = nil, onChunkReady: (piper_audio_chunk) -> Void, onMarkers: (([PiperSpeechMarker]) -> Void)? = nil) {
        let sentences = PiperSentencesExtractor.extract(from: text)
        var currentOptions = options
        
        var searchStartIndex = text.startIndex

        for sentence in sentences {
            autoreleasepool {
                if let memoryThresholdBytes,
                   let memory = getMemoryUsage(),
                   memory > memoryThresholdBytes {
                    recreateSynthesizer()
                }
                
                if synthesizer == nil {
                    synthesizer = try? Self.makeSynthesizer(modelPath: modelPath,
                                                            configPath: configPath.isEmpty ? nil : configPath,
                                                            espeakData: espeakData,
                                                            dataDir: dataDir,
                                                            g2pwDir: g2pwModelDir,
                                                            openjtalkDir: openjtalkDictDir)
                }

                guard synthesizer != nil else {
                    status = .error
                    return
                }
                if status != .rendering { return }

                let nsRange: NSRange
                if let ssmlFragment, ssmlFragment.ssmlRange.location != NSNotFound {
                    if let sentenceRange = text.range(of: sentence, options: [], range: searchStartIndex..<text.endIndex) {
                        let locationInFragment = text.distance(from: text.startIndex, to: sentenceRange.lowerBound)
                        let length = text.distance(from: sentenceRange.lowerBound, to: sentenceRange.upperBound)
                        nsRange = NSRange(location: ssmlFragment.ssmlRange.location + locationInFragment, length: length)
                        searchStartIndex = sentenceRange.upperBound
                    } else {
                        nsRange = NSRange(location: NSNotFound, length: 0)
                    }
                } else {
                    nsRange = NSRange(location: NSNotFound, length: 0)
                }

                let sentenceStartByteOffset = self.totalSSMLBytesGenerated
                
                if piper_synthesize_start(synthesizer, sentence, &currentOptions) == PIPER_ERR_GENERIC {
                    // Sawyer 1.0.12 YouTube long post: one bad sentence (emoji/URL) aborted remaining 10+ sentences.
                    // Skip failed sentence instead of aborting entire long utterance.
                    // NOTE: inside autoreleasepool closure, `return` exits closure and for-loop proceeds to next sentence
                    return
                }
                
                var sentenceTotalBytes = 0
                var sentenceAlignmentGroups: [PiperAlignmentParser.PhonemeGroup] = []
                var chunk = piper_audio_chunk()
                var piperStatus = PIPER_OK
                repeat {
                    piperStatus = piper_synthesize_next(synthesizer, &chunk)
                    if piperStatus == PIPER_ERR_GENERIC {
                        // Skip this sentence's remainder, continue to next sentence for long utterance resilience
                        break
                    }
                    if status != .rendering { return }
                    if chunk.num_samples == 0 {
                        // Even if no samples, we may still have alignments for punctuation handling?
                        // Break but keep any previously collected groups
                        if chunk.num_alignments == 0 { break }
                    }
                    
                    onChunkReady(chunk)

                    // ---- Alignment grouping (piper.h rule) ----
                    // Groups of repeated codepoints separated by 0 -> N ids & N alignments per phoneme
                    // BOS=1,PAD=0,EOS=2 are special and ignored for highlighting but kept for cumulative offset
                    if let phonemesPtr = chunk.phonemes, let idsPtr = chunk.phoneme_ids, let alignPtr = chunk.alignments,
                       chunk.num_phonemes > 0, chunk.num_phoneme_ids > 0, chunk.num_alignments > 0 {
                        let groups = PiperAlignmentParser.group(
                            phonemesPtr: phonemesPtr,
                            numPhonemes: Int(chunk.num_phonemes),
                            idsPtr: idsPtr,
                            numIds: Int(chunk.num_phoneme_ids),
                            alignmentsPtr: alignPtr,
                            numAlignments: Int(chunk.num_alignments)
                        )
                        if !groups.isEmpty {
                            sentenceAlignmentGroups.append(contentsOf: groups)
                            // Notify delegate incrementally (optional)
                            self.delegate?.piperDidReceiveAlignment(groups: groups)
                        }
                    }
                    
                    let chunkBytes = Int(chunk.num_samples) * MemoryLayout<Float>.size
                    sentenceTotalBytes += chunkBytes
                } while piperStatus == PIPER_OK
                
                self.totalSSMLBytesGenerated += sentenceTotalBytes
                
                if nsRange.location != NSNotFound, let onMarkers {
                    if !sentenceAlignmentGroups.isEmpty {
                        let markers = PiperSpeechMarker.generateMarkersWithAlignment(
                            for: sentence,
                            sentenceNSRange: nsRange,
                            startByteOffset: sentenceStartByteOffset,
                            groups: sentenceAlignmentGroups
                        )
                        onMarkers(markers)
                    } else {
                        let markers = PiperSpeechMarker.generateMarkers(for: sentence, sentenceNSRange: nsRange, startByteOffset: sentenceStartByteOffset, totalBytes: sentenceTotalBytes)
                        onMarkers(markers)
                    }
                }
            }
        }
    }

    private func parseAndSynthesizeSSML(ssml: String, speakerId: Int32, onChunkReady: @escaping (piper_audio_chunk) -> Void) {
        self.ssmlParser.parse(ssml: ssml) { [weak self] fragment in
            guard let self = self, self.status == .rendering else { return }
            autoreleasepool {
                let options = self.getOptions(for: fragment, speakerId: speakerId)
                self.doSynthesize(text: fragment.text, options: options, ssmlFragment: fragment, onChunkReady: onChunkReady)
            }
        }
    }
    
    private func writeWavChunk(to fileHandle: FileHandle, chunk: piper_audio_chunk, isHeaderWritten: inout Bool) {
        if !isHeaderWritten {
            try? self.writeWavHeader(to: fileHandle, sampleRate: Int32(chunk.sample_rate))
            isHeaderWritten = true
        }
        // Avoid Data copy – write directly from synthesizer's buffer
        let numBytes = Int(chunk.num_samples) * MemoryLayout<Float>.size
        if numBytes > 0, let samples = chunk.samples {
            // FileHandle.write(Data) copies; using raw fd avoids extra allocation
            _ = Darwin.write(fileHandle.fileDescriptor, samples, numBytes)
        }
    }

    private func addClearBeforeStartingOperation() {
        cancel()
        status = .rendering
    }

    private func addMarkAsCompleteOperation(_ completion: (() -> Void)?) {
        operationQueue.addOperation { [weak self] in
            guard let self = self else { return }
            self.statusLock.lock()
            if self._status == .rendering {
                self._status = .completed
            }
            self.statusLock.unlock()
            completion?()
        }
    }

    private func writeWavHeader(to fileHandle: FileHandle, sampleRate: Int32) throws {
        let unspecCount: UInt32 = 0x7ffff000
        var data = Data()
        
        func writeString(_ string: String) {
            data.append(contentsOf: string.utf8)
        }
        func writeValue<T>(_ value: T) {
            var val = value
            withUnsafeBytes(of: &val) { data.append(contentsOf: $0) }
        }
        
        writeString("RIFF")
        writeValue(unspecCount + 36)
        writeString("WAVE")
        writeString("fmt ")
        writeValue(UInt32(16))
        writeValue(UInt16(3)) // AudioFormat = 3 (IEEE float)
        writeValue(UInt16(1)) // NumChannels = 1 (mono)
        writeValue(UInt32(sampleRate))
        writeValue(UInt32(sampleRate * 4)) // ByteRate
        writeValue(UInt16(4)) // BlockAlign
        writeValue(UInt16(32)) // BitsPerSample
        writeString("data")
        writeValue(unspecCount)
        
        fileHandle.write(data)
    }
}
