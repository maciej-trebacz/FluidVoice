import CNemotron
import Foundation

nonisolated enum NemotronTranscribeFiles {
    static let directoryKey = "NemotronTranscribeModelDirectory"
    // Keep calls well within the C ABI's 4 x 8192-token pool and limit reset delays.
    static let chunkSeconds = 300
    // Language hints understood by this pinned runtime's salm_policy.cpp.
    static let languageCodes: Set<String> = Set("en ar zh fr de hi it ja es ko pt ru th hy nn nb no bg hr cs da nl et fi el he hu id lv lt mt ta bn pl ro sk sl sv tr tl fil uk vi".split(separator: " ").map(String.init))

    struct Pair: Sendable {
        let decoder: URL
        let encoder: URL
    }

    static func resolve(directory: URL) throws -> Pair {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let decoders = files.filter { $0.lastPathComponent.lowercased().hasSuffix("iq4_nl.gguf") }
        let encoders = files.filter { $0.lastPathComponent.lowercased().hasSuffix("-encoder-f16.gguf") }
        guard decoders.count == 1, encoders.count == 1 else {
            throw failure("Select a folder with one Nemotron 3.5 Transcribe IQ4_NL decoder and its Encoder-F16 GGUF file.")
        }
        for url in [decoders[0], encoders[0]] {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            guard try file.read(upToCount: 4) == Data("GGUF".utf8) else {
                throw failure("\(url.lastPathComponent) is not a GGUF file.")
            }
        }
        return Pair(decoder: decoders[0], encoder: encoders[0])
    }

    static func selected(defaults: UserDefaults = .standard) throws -> Pair {
        guard let path = defaults.string(forKey: directoryKey) else {
            throw failure("Select the Nemotron 3.5 Transcribe model folder in Voice Engine settings.")
        }
        return try resolve(directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    static func forgetSelection(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: directoryKey)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "NemotronTranscribe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Complete-audio transcription with NVIDIA's speech LLM, not the 0.6B CoreML ASR.
final class NemotronTranscribeProvider: TranscriptionProvider {
    let name = "Nemotron 3.5 Transcribe"
    private let engine = NemotronTranscribeEngine()
    var isAvailable: Bool { CPUArchitecture.isAppleSilicon }
    var isReady: Bool { self.engine.isReady }
    var shouldClearCacheAfterCancellation: Bool { false }

    func modelsExistOnDisk() -> Bool { (try? NemotronTranscribeFiles.selected()) != nil }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        try Task.checkCancellation()
        guard self.isAvailable else { throw NemotronTranscribeFiles.failure("This model requires Apple silicon.") }
        let pair = try NemotronTranscribeFiles.selected()
        guard let frameworks = Bundle.main.privateFrameworksURL else {
            throw NemotronTranscribeFiles.failure("The bundled Nemotron runtime is missing. Rebuild FluidVoice with its Nemotron build phase.")
        }
        progressHandler?(.loading)
        do {
            try await self.engine.load(library: frameworks.appendingPathComponent("NeMoSpeech/libnemo_speech_asr_c.1.dylib"), pair: pair)
        } catch is CancellationError {
            await self.engine.unload()
            throw CancellationError()
        }
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try Task.checkCancellation()
        guard samples.count >= 320 else { return ASRTranscriptionResult(text: "") }
        // Split long dictation too: file imports are not the only source of long audio.
        let size = NemotronTranscribeFiles.chunkSeconds * 16_000
        let language = SettingsStore.shared.selectedWhisperLanguageCode
        if let language, !NemotronTranscribeFiles.languageCodes.contains(language) {
            throw NemotronTranscribeFiles.failure("Select a supported language for Nemotron 3.5 Transcribe.")
        }
        var parts: [String] = []
        for start in stride(from: 0, to: samples.count, by: size) {
            try Task.checkCancellation()
            let chunk = Array(samples[start..<min(start + size, samples.count)])
            if chunk.count >= 320 { parts.append(try await self.engine.transcribe(chunk, language: language)) }
        }
        return ASRTranscriptionResult(text: parts.joined(separator: " "))
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NemotronTranscribeFiles.failure("Nemotron 3.5 Transcribe processes audio after recording stops.")
    }

    func clearCache() async throws {
        await self.engine.unload()
        try Task.checkCancellation()
        // These files belong to the user. Removing the selection must never delete them.
        NemotronTranscribeFiles.forgetSelection()
    }
}

/// A native call cannot be interrupted. Keep its handle alive and drain it before unload.
final nonisolated class NemotronTranscribeEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FluidVoice.NemotronTranscribe", qos: .userInitiated)
    private let lock = NSLock()
    private var ready = false
    private var handle: OpaquePointer?
    private var loadedDecoder: URL?
    private var loadedEncoder: URL?

    var isReady: Bool { self.lock.withLock { self.ready } }
    deinit { fv_nemotron_destroy(self.handle) }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: T = try await withCheckedThrowingContinuation { continuation in
                self.queue.async {
                    do {
                        try cancellation.check()
                        let result = try operation()
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: { cancellation.cancel() }
    }

    func load(library: URL, pair: NemotronTranscribeFiles.Pair) async throws {
        try await self.perform {
            if self.handle != nil, self.loadedDecoder == pair.decoder, self.loadedEncoder == pair.encoder { return }
            self.lock.withLock { self.ready = false }
            fv_nemotron_destroy(self.handle)
            self.handle = nil
            self.loadedDecoder = nil
            self.loadedEncoder = nil
            var error = [CChar](repeating: 0, count: 2048)
            self.handle = fv_nemotron_create(library.path, pair.decoder.path, pair.encoder.path, &error, error.count)
            guard self.handle != nil else { throw NemotronTranscribeFiles.failure(String(cString: error)) }
            self.loadedDecoder = pair.decoder
            self.loadedEncoder = pair.encoder
            self.lock.withLock { self.ready = true }
        }
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        try await self.perform {
            guard let handle = self.handle else { throw NemotronTranscribeFiles.failure("Prepare the Nemotron model first.") }
            var text: UnsafeMutablePointer<CChar>?
            var error = [CChar](repeating: 0, count: 2048)
            let call: (UnsafePointer<CChar>?) -> Bool = { languagePointer in
                fv_nemotron_transcribe(handle, samples, samples.count, languagePointer, &text, &error, error.count)
            }
            let success = language.map { $0.withCString(call) } ?? call(nil)
            defer { fv_nemotron_free_text(text) }
            guard success, let text else { throw NemotronTranscribeFiles.failure(String(cString: error)) }
            return String(cString: text)
        }
    }

    func unload() async {
        // Cleanup must drain even when the caller has already been cancelled.
        await withCheckedContinuation { continuation in
            self.queue.async {
                self.lock.withLock { self.ready = false }
                fv_nemotron_destroy(self.handle)
                self.handle = nil
                self.loadedDecoder = nil
                self.loadedEncoder = nil
                continuation.resume()
            }
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { self.lock.withLock { self.cancelled = true } }
        func check() throws {
            if self.lock.withLock({ self.cancelled }) { throw CancellationError() }
        }
    }
}
