import Foundation
import NaturalLanguage
import Observation
import Translation

struct TranslationJob: Identifiable {
    let id = UUID()
    let text: String
    let sourceID: String
    let targetID: String
    let retrySourceID: String?
    let usesFallback: Bool

    var configuration: TranslationSession.Configuration {
        let source = Locale.Language(identifier: sourceID)
        let target = Locale.Language(identifier: targetID)
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
    private let defaults: UserDefaults
    private(set) var languages: [Language] = []
    private(set) var job: TranslationJob?
    private(set) var output = ""
    private(set) var resultSourceID: String?
    private(set) var usedFallback = false
    private(set) var message: String?
    var focusRequest = 0
    var needsAccessibilityPermission = false

    var input = "" {
        didSet { if oldValue != input { resetResult() } }
    }

    var sourceID: String {
        didSet {
            guard oldValue != sourceID else { return }
            defaults.set(sourceID, forKey: "sourceLanguage")
            resetResult()
        }
    }

    var targetID: String {
        didSet {
            guard oldValue != targetID else { return }
            defaults.set(targetID, forKey: "targetLanguage")
            resetResult()
        }
    }

    var primaryLanguageID: String {
        didSet { defaults.set(primaryLanguageID, forKey: "primaryLanguage") }
    }

    var secondaryLanguageID: String {
        didSet { defaults.set(secondaryLanguageID, forKey: "secondaryLanguage") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceID = defaults.string(forKey: "sourceLanguage") ?? ""
        targetID = defaults.string(forKey: "targetLanguage") ?? "ru"
        primaryLanguageID = defaults.string(forKey: "primaryLanguage") ?? "en"
        secondaryLanguageID = defaults.string(forKey: "secondaryLanguage") ?? "ru"
    }

    var canTranslate: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSwap: Bool {
        if sourceID.isEmpty { return alternateLanguage(to: targetID) != nil }
        return !Self.sameLanguage(sourceID, targetID)
    }

    func loadLanguages() async {
        let ids = await Self.supportedLanguageIDs()
        languages = ids.map { Language(id: $0, name: Self.languageName($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !languages.isEmpty else { return }
        if !ids.contains(primaryLanguageID) {
            primaryLanguageID = ids.contains("en") ? "en" : languages[0].id
        }
        if !ids.contains(secondaryLanguageID) || Self.sameLanguage(primaryLanguageID, secondaryLanguageID) {
            if ids.contains("ru"), !Self.sameLanguage(primaryLanguageID, "ru") {
                secondaryLanguageID = "ru"
            } else if let alternative = languages.first(where: { !Self.sameLanguage(primaryLanguageID, $0.id) }) {
                secondaryLanguageID = alternative.id
            }
        }
        if !sourceID.isEmpty, !ids.contains(sourceID) { sourceID = "" }
        if !ids.contains(targetID) {
            targetID = ids.contains(secondaryLanguageID) ? secondaryLanguageID : primaryLanguageID
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

    static func sameLanguage(_ firstID: String, _ secondID: String) -> Bool {
        let first = Locale.Language(identifier: firstID)
        let second = Locale.Language(identifier: secondID)
        return first.languageCode == second.languageCode && first.script == second.script
    }

    private func recognizeSource() -> String? {
        guard canTranslate else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(input.prefix(2_000)))

        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            .sorted { $0.value > $1.value }
        for (language, confidence) in hypotheses where confidence >= 0.4 {
            let id = Locale.Language(identifier: language.rawValue).minimalIdentifier
            if languages.isEmpty || languages.contains(where: { $0.id == id }) { return id }
            if let match = languages.first(where: { Self.sameLanguage($0.id, id) }) { return match.id }
        }
        return nil
    }

    private func alternateLanguage(to id: String) -> String? {
        [primaryLanguageID, secondaryLanguageID].first { !Self.sameLanguage($0, id) }
    }

    func translateSelection(_ text: String) {
        input = text
        translate()
    }

    func translate() {
        guard canTranslate else { return }
        resetResult()
        if !sourceID.isEmpty {
            guard !Self.sameLanguage(sourceID, targetID) else {
                message = "Выберите другой язык перевода."
                return
            }
            job = TranslationJob(
                text: input, sourceID: sourceID, targetID: targetID, retrySourceID: nil, usesFallback: false
            )
            return
        }

        let recognized = recognizeSource()
        if let recognized, Self.sameLanguage(recognized, targetID) {
            output = input
            resultSourceID = recognized
            message = "Текст уже на выбранном языке."
            return
        }

        let fallback = alternateLanguage(to: targetID)
        guard let source = recognized ?? fallback else {
            message = "Выберите исходный язык вручную."
            return
        }
        // retry once when the engine rejects the recognized source language.
        let retry = fallback.flatMap { alternative in
            Self.sameLanguage(source, alternative) ? nil : alternative
        }
        job = TranslationJob(
            text: input, sourceID: source, targetID: targetID, retrySourceID: retry, usesFallback: recognized == nil
        )
    }

    func finish(_ response: TranslationSession.Response, for id: UUID) {
        guard let job, job.id == id else { return }
        output = response.targetText
        resultSourceID = response.sourceLanguage.minimalIdentifier
        usedFallback = job.usesFallback
        self.job = nil
    }

    func fail(_ error: Error, for id: UUID) {
        guard let job, job.id == id else { return }
        switch error {
        case TranslationError.unableToIdentifyLanguage, TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedLanguagePairing:
            if let retry = job.retrySourceID {
                self.job = TranslationJob(
                    text: job.text, sourceID: retry, targetID: job.targetID, retrySourceID: nil, usesFallback: true
                )
                return
            }
        default:
            break
        }
        self.job = nil
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
        guard canSwap else { return }
        let wasAutomatic = sourceID.isEmpty
        let source = wasAutomatic ? resultSourceID ?? recognizeSource() : sourceID
        let alternate = alternateLanguage(to: targetID)
        let newTarget = source.flatMap { Self.sameLanguage($0, targetID) ? nil : $0 } ?? alternate
        guard let newTarget else { return }
        let previousOutput = output
        sourceID = targetID
        targetID = newTarget
        if !previousOutput.isEmpty {
            input = previousOutput
            translate()
        } else if wasAutomatic, let source, Self.sameLanguage(source, sourceID) {
            translate()
        }
    }

    func resetResult() {
        job = nil
        output = ""
        resultSourceID = nil
        usedFallback = false
        message = nil
    }
}
