import Foundation

// Standalone test executable compiled with the production provider and its C bridge.
@main struct NemotronEngineChecks {
    static func main() async throws {
        let library = URL(fileURLWithPath: CommandLine.arguments[1])
        let pair = NemotronTranscribeFiles.Pair(decoder: URL(fileURLWithPath: "/decoder"), encoder: URL(fileURLWithPath: "/encoder"))
        let engine = NemotronTranscribeEngine()
        try await engine.load(library: library, pair: pair)
        precondition(engine.isReady)
        let samples = [Float](repeating: 0.1, count: 16000)
        let polish = try await engine.transcribe(samples, language: "pl")
        precondition(polish == "pl", "Language must reach the C ABI and text must outlive the native result")
        let automatic = try await engine.transcribe(samples, language: nil)
        precondition(automatic == "default")

        let pending = Task { try await engine.transcribe(samples, language: "pl") }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        // The test runtime aborts if destroy races a native call.
        await engine.unload()
        do { _ = try await pending.value; preconditionFailure("Cancelled result escaped") }
        catch is CancellationError {}
        precondition(!engine.isReady)

        let missing = NemotronTranscribeFiles.Pair(decoder: URL(fileURLWithPath: "/missing"), encoder: pair.encoder)
        do { try await engine.load(library: library, pair: missing); preconditionFailure("Missing model accepted") }
        catch { precondition(error.localizedDescription == "Missing decoder fixture") }
        try await engine.load(library: library, pair: pair)
        let cleanup = Task { await engine.unload() }
        cleanup.cancel()
        await cleanup.value
        precondition(!engine.isReady, "Cleanup must run even for a cancelled caller")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("GGUFtest".utf8).write(to: directory.appendingPathComponent("model-IQ4_NL.gguf"))
        do { _ = try NemotronTranscribeFiles.resolve(directory: directory); preconditionFailure("Incomplete pair accepted") }
        catch {}
        let encoder = directory.appendingPathComponent("model-Encoder-F16.gguf")
        try Data("HTML".utf8).write(to: encoder)
        do { _ = try NemotronTranscribeFiles.resolve(directory: directory); preconditionFailure("Non-GGUF accepted") }
        catch {}
        try Data("GGUFtest".utf8).write(to: encoder)
        _ = try NemotronTranscribeFiles.resolve(directory: directory)
        let defaults = UserDefaults(suiteName: "NemotronTests.\(UUID().uuidString)")!
        defaults.set(directory.path, forKey: NemotronTranscribeFiles.directoryKey)
        _ = try NemotronTranscribeFiles.selected(defaults: defaults)
        NemotronTranscribeFiles.forgetSelection(defaults: defaults)
        precondition(defaults.string(forKey: NemotronTranscribeFiles.directoryKey) == nil)
        precondition(FileManager.default.fileExists(atPath: encoder.path), "Removing a selection must preserve external files")
        try Data("GGUFtest".utf8).write(to: directory.appendingPathComponent("other-IQ4_NL.gguf"))
        do { _ = try NemotronTranscribeFiles.resolve(directory: directory); preconditionFailure("Ambiguous pair accepted") }
        catch {}
        let provider = NemotronTranscribeProvider()
        let short = try await provider.transcribe([Float](repeating: 0, count: 319))
        precondition(short.text.isEmpty)
        do { _ = try await provider.transcribeStreaming(samples); preconditionFailure("Streaming accepted") }
        catch {}
        print("Passed: language, result ownership, cancellation drain, cancelled cleanup, native error, model folder validation")
    }
}
