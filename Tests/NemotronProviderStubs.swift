import Foundation
struct ASRTranscriptionResult { let text: String }
struct ModelPreparationProgress { static let loading = ModelPreparationProgress() }
@MainActor protocol TranscriptionProvider {}
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var selectedWhisperLanguageCode: String? = "pl"
}
enum CPUArchitecture { static let isAppleSilicon = true }
