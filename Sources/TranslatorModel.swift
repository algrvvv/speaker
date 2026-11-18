import Foundation
import Observation
import Translation

struct TranslationJob: Identifiable {
    let id = UUID()
    let text: String
    let source: Locale.Language?
    let target: Locale.Language

    var configuration: TranslationSession.Configuration {
        if #available(macOS 26.4, *) {
            return .init(source: source, target: target, preferredStrategy: .lowLatency)
        }
        return .init(source: source, target: target)
    }
}

@MainActor @Observable
final class TranslatorModel {
    struct Language: Identifiable {
        let id: String
        let name: String
    }

    private static let displayLocale = Locale(identifier: "ru")
    private let defaults = UserDefaults.standard
    private(set) var languages: [Language] = []
    private(set) var job: TranslationJob?
    private(set) var output = ""
    private(set) var detectedSource: String?
    private(set) var message: String?
    var focusRequest = 0
    var needsAccessibilityPermission = false

    var input = "" {
        didSet { if oldValue != input { resetResult() } }
    }

    var sourceID = UserDefaults.standard.string(forKey: "sourceLanguage") ?? "" {
        didSet {
            guard oldValue != sourceID else { return }
            defaults.set(sourceID, forKey: "sourceLanguage")
            resetResult()
        }
    }

    var targetID = UserDefaults.standard.string(forKey: "targetLanguage") ?? "ru" {
        didSet {
            guard oldValue != targetID else { return }
            defaults.set(targetID, forKey: "targetLanguage")
            resetResult()
        }
    }

    var canTranslate: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSwap: Bool {
        let source = sourceID.isEmpty ? detectedSource : sourceID
        return source != nil && source != targetID
    }

    func loadLanguages() async {
        let ids = await Self.supportedLanguageIDs()
        languages = ids.map { Language(id: $0, name: Self.languageName($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !languages.isEmpty else { return }
        if !sourceID.isEmpty, !ids.contains(sourceID) { sourceID = "" }
        if !ids.contains(targetID) {
            targetID = ids.contains("ru") ? "ru" : languages[0].id
        }
    }

    private nonisolated static func supportedLanguageIDs() async -> Set<String> {
        let availability: LanguageAvailability
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        return Set(await availability.supportedLanguages.map(\.minimalIdentifier))
    }

    static func languageName(_ id: String) -> String {
        let name = displayLocale.localizedString(forIdentifier: id) ?? id
        return name.prefix(1).uppercased(with: displayLocale) + name.dropFirst()
    }

    func translateSelection(_ text: String) {
        input = text
        translate()
    }

    func translate() {
        guard canTranslate else { return }
        resetResult()
        if sourceID == targetID {
            message = "Выберите другой язык перевода."
            return
        }
        job = TranslationJob(
            text: input,
            source: sourceID.isEmpty ? nil : Locale.Language(identifier: sourceID),
            target: Locale.Language(identifier: targetID)
        )
    }

    func finish(_ response: TranslationSession.Response, for id: UUID) {
        guard job?.id == id else { return }
        output = response.targetText
        detectedSource = response.sourceLanguage.minimalIdentifier
        job = nil
    }

    func fail(_ error: Error, for id: UUID) {
        guard job?.id == id else { return }
        job = nil
        switch error {
        case TranslationError.unableToIdentifyLanguage:
            message = "Не удалось определить язык. Выберите его вручную."
        case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedTargetLanguage:
            message = "Эта пара языков недоступна. Проверьте выбранные языки."
        case TranslationError.unsupportedSourceLanguage:
            message = "Язык исходного текста недоступен для перевода."
        case is CancellationError:
            message = "Перевод отменён. Его можно запустить снова."
        default:
            message = "Не удалось перевести текст. Попробуйте ещё раз."
            NSLog("Speaker translation failed: %@", String(describing: type(of: error)))
        }
    }

    func swapLanguages() {
        let source = sourceID.isEmpty ? detectedSource : sourceID
        guard let source, source != targetID else { return }
        let previousOutput = output
        sourceID = targetID
        targetID = source
        if !previousOutput.isEmpty {
            input = previousOutput
            translate()
        }
    }

    func resetResult() {
        job = nil
        output = ""
        detectedSource = nil
        message = nil
    }
}
