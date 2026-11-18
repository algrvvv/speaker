import AppKit
import ServiceManagement
import SwiftUI
import Translation

struct TranslatorView: View {
    @Bindable var model: TranslatorModel
    let shortcuts: OpeningShortcutController
    @FocusState private var inputFocused: Bool
    @State private var copied = false
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if showSettings {
                TranslatorSettings(model: model, shortcuts: shortcuts) { showSettings = false }
            } else {
                inputCard
                swapButton
                outputCard
                if model.needsAccessibilityPermission {
                    permissionNotice
                }
                footer
            }
        }
        .padding(16)
        .frame(width: 410)
        .background {
            if let job = model.job {
                Color.clear
                    .translationTask(job.configuration, action: Self.translationAction(for: job, model: model))
                    .id(job.id)
            }
        }
        .onChange(of: model.focusRequest, initial: true) { _, _ in
            showSettings = false
            inputFocused = true
        }
        .onChange(of: showSettings) { _, isShown in inputFocused = !isShown }
        .onChange(of: model.output) { _, _ in copied = false }
    }

    private nonisolated static func translationAction(for job: TranslationJob, model: TranslatorModel)
        -> (TranslationSession) async -> Void {
        { session in
            do {
                let response = try await session.translate(job.text)
                await model.finish(response, for: job.id)
            } catch {
                await model.fail(error, for: job.id)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                Text("Speaker")
                    .font(.system(size: 19, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .overlay { WindowDragArea().accessibilityHidden(true) }
            if shortcuts.isRegistered {
                Text(shortcuts.shortcut.display)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                    .help("Перевести выделение или открыть Speaker")
                    .accessibilityLabel("Сочетание для открытия \(shortcuts.shortcut.display)")
            } else {
                Image(systemName: "keyboard.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .help("Сочетание \(shortcuts.shortcut.display) недоступно. Измени его в настройках.")
                    .accessibilityLabel("Глобальное сочетание недоступно")
            }
            Menu {
                Button("Настройки…") { showSettings = true }
                if !SelectionAccess.isTrusted {
                    Button("Разрешить чтение выделения…", action: requestPermission)
                }
                Button("Очистить текст") { model.input = "" }
                    .disabled(model.input.isEmpty)
                Divider()
                Button("Завершить Speaker") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Действия Speaker")
        }
        .padding(.leading, 24)
        .padding(.bottom, 2)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                LanguagePicker(
                    title: "Исходный язык", selection: $model.sourceID, languages: model.languages, allowsAuto: true
                )
                Spacer()
                Button {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        model.input = text
                    }
                    inputFocused = true
                } label: {
                    Label("Вставить", systemImage: "clipboard")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Вставить текст из буфера обмена")
            }
            ZStack(alignment: .topLeading) {
                if model.input.isEmpty {
                    Text("Введите или вставьте текст…")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $model.input)
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
                    .accessibilityLabel("Исходный текст")
            }
            .font(.system(size: 15))
            .frame(height: 90)
        }
        .modifier(TranslationCard())
    }

    private var swapButton: some View {
        Button(action: model.swapLanguages) {
            Label("Поменять языки", systemImage: "arrow.up.arrow.down")
        }
        .controlSize(.small)
        .disabled(!model.canSwap)
        .help("Поменять исходный язык и язык перевода местами")
        .frame(maxWidth: .infinity)
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                LanguagePicker(title: "Язык перевода", selection: $model.targetID, languages: model.languages)
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    copied = pasteboard.setString(model.output, forType: .string)
                } label: {
                    Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.output.isEmpty)
            }
            ScrollView {
                if model.output.isEmpty {
                    Text(model.job == nil ? "Здесь появится перевод" : "Переводим…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(model.output)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Перевод, \(model.output)")
                }
            }
            .padding(.horizontal, 5)
            .font(.system(size: 15))
            .frame(height: 90)
        }
        .modifier(TranslationCard(tinted: true))
    }

    private var permissionNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .accessibilityHidden(true)
            Text("Для перевода выделенного текста нужен универсальный доступ.")
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Разрешить…", action: requestPermission)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let source = model.resultSourceID, model.sourceID.isEmpty {
                let label = model.usedFallback ? "Резервный язык" : "Язык текста"
                Text("\(label) — \(TranslatorModel.languageName(source))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.job != nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Идёт перевод")
            }
            Button(action: model.translate) {
                Text("Перевести")
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Перевести · ⌘↩")
            .disabled(!model.canTranslate || model.job != nil)
        }
        .padding(.top, 2)
    }

    private func requestPermission() {
        SelectionAccess.requestPermission()
        model.needsAccessibilityPermission = false
    }
}

private struct LanguagePicker: View {
    let title: String
    @Binding var selection: String
    let languages: [TranslatorModel.Language]
    var allowsAuto = false

    var body: some View {
        let name = selection.isEmpty ? "Автоопределение" : TranslatorModel.languageName(selection)
        Menu {
            Picker(title, selection: $selection) {
                if allowsAuto {
                    Text("Автоопределение").tag("")
                    Divider()
                }
                ForEach(languages) { language in
                    Text(language.name).tag(language.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(languages.isEmpty)
        .help(title)
        .accessibilityLabel("\(title), \(name)")
    }
}

private struct TranslatorSettings: View {
    @Bindable var model: TranslatorModel
    let shortcuts: OpeningShortcutController
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Настройки")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            languageSettings
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Сочетание для открытия")
                    Spacer(minLength: 8)
                    Text(shortcuts.shortcut.display)
                        .font(.system(.body, design: .monospaced))
                    Button(shortcuts.isRecording ? "Отмена" : "Изменить…") {
                        if shortcuts.isRecording {
                            shortcuts.endRecording()
                        } else {
                            shortcuts.beginRecording()
                        }
                    }
                }
                if let message = shortcuts.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if shortcuts.isRecording {
                    Text("Нажми новое сочетание. Esc отменит запись.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .modifier(TranslationCard())
            LoginItemSetting()
            HStack {
                Button("По умолчанию", action: shortcuts.restoreDefault)
                    .disabled(shortcuts.isRegistered && shortcuts.shortcut.matches(.standard))
                Spacer()
                Button("Готово", action: done)
                    .buttonStyle(.borderedProminent)
            }
        }
        .onDisappear { shortcuts.endRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            shortcuts.endRecording()
        }
    }

    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Основной язык")
                Spacer(minLength: 8)
                LanguagePicker(
                    title: "Основной язык", selection: $model.primaryLanguageID,
                    languages: model.languages.filter { !TranslatorModel.sameLanguage($0.id, model.secondaryLanguageID) }
                )
            }
            HStack {
                Text("Второй основной")
                Spacer(minLength: 8)
                LanguagePicker(
                    title: "Второй основной", selection: $model.secondaryLanguageID,
                    languages: model.languages.filter { !TranslatorModel.sameLanguage($0.id, model.primaryLanguageID) }
                )
            }
            Text("Если не удаётся определить язык текста, Speaker берёт основной. Если переводишь на него, берёт второй.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .modifier(TranslationCard())
    }
}

private struct LoginItemSetting: View {
    @State private var status: SMAppService.Status = .notRegistered
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Запускать при входе", isOn: Binding(
                get: { isRegistered(status) }, set: { updateRegistration($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            if status == .requiresApproval {
                Text("Подтверди автозапуск Speaker в системных настройках.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Открыть системные настройки…") { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .modifier(TranslationCard())
        .onAppear { refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    private func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    private func refreshStatus() {
        let current = SMAppService.mainApp.status
        if current != status { errorMessage = nil }
        status = current
    }

    private func updateRegistration(_ enabled: Bool) {
        let service = SMAppService.mainApp
        errorMessage = nil
        defer { status = service.status }

        guard isRegistered(service.status) != enabled else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            guard isRegistered(service.status) != enabled else { return }
            let action = enabled ? "включить" : "отключить"
            errorMessage = "Не удалось \(action) автозапуск. \(error.localizedDescription)"
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        private var start: (pointer: NSPoint, origin: NSPoint)?

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let start else { return }
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(NSPoint(
                x: start.origin.x + pointer.x - start.pointer.x,
                y: start.origin.y + pointer.y - start.pointer.y
            ))
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

private struct TranslationCard: ViewModifier {
    var tinted = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tinted ? Color.accentColor.opacity(0.08) : Color(nsColor: .textBackgroundColor).opacity(0.68))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.primary.opacity(0.09))
                    .allowsHitTesting(false)
            }
    }
}
