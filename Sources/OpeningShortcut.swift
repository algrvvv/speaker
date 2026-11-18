import AppKit
import Carbon
import Observation

struct OpeningShortcut: Codable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let standard = OpeningShortcut(
        keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | shiftKey | cmdKey), keyLabel: "T"
    )

    private static let modifierKeys: [(flag: NSEvent.ModifierFlags, carbon: Int, symbol: String)] = [
        (.control, controlKey, "⌃"),
        (.option, optionKey, "⌥"),
        (.shift, shiftKey, "⇧"),
        (.command, cmdKey, "⌘")
    ]

    var display: String {
        Self.modifierKeys.filter { modifiers & UInt32($0.carbon) != 0 }.map(\.symbol).joined() + keyLabel
    }

    func matches(_ other: Self) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    static func recording(_ event: NSEvent) -> Self? {
        let modifiers = Self.modifierKeys.filter { event.modifierFlags.contains($0.flag) }
            .reduce(0) { $0 | $1.carbon }
        let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        if let value = characters.unicodeScalars.first?.value,
           (UInt32(NSF1FunctionKey)...UInt32(NSF20FunctionKey)).contains(value) {
            let number = value - UInt32(NSF1FunctionKey) + 1
            return Self(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), keyLabel: "F\(number)")
        }

        guard modifiers & (controlKey | optionKey | cmdKey) != 0 else { return nil }
        let label: String
        switch Int(event.keyCode) {
        case kVK_Space: label = "Пробел"
        case kVK_Tab: label = "⇥"
        case kVK_Return, kVK_ANSI_KeypadEnter: label = "↩"
        case kVK_Delete: label = "⌫"
        case kVK_ForwardDelete: label = "⌦"
        case kVK_LeftArrow: label = "←"
        case kVK_RightArrow: label = "→"
        case kVK_UpArrow: label = "↑"
        case kVK_DownArrow: label = "↓"
        case kVK_Home: label = "↖"
        case kVK_End: label = "↘"
        case kVK_PageUp: label = "⇞"
        case kVK_PageDown: label = "⇟"
        default:
            guard let character = characters.first, character.isLetter || character.isNumber ||
                    character.isPunctuation || character.isSymbol else { return nil }
            label = character.uppercased()
        }
        return Self(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), keyLabel: label)
    }
}

@MainActor @Observable
final class OpeningShortcutController {
    private static let storageKey = "openingShortcut"
    private nonisolated static let signature: OSType = 0x5350_4B52

    private(set) var shortcut: OpeningShortcut
    private(set) var isRegistered = false
    private(set) var message: String?
    private var monitor: Any?

    @ObservationIgnored private var registration: (reference: EventHotKeyRef, id: UInt32)?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var nextID: UInt32 = 0
    @ObservationIgnored private var onPress: (() -> Void)?

    var isRecording: Bool { monitor != nil }

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.storageKey)
        shortcut = stored.flatMap { try? JSONDecoder().decode(OpeningShortcut.self, from: $0) } ?? .standard
    }

    func start(onPress: @escaping () -> Void) {
        self.onPress = onPress
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(
                event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &key
            )
            guard status == noErr, key.signature == OpeningShortcutController.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = key.id
            let controller = Unmanaged<OpeningShortcutController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { controller.didPress(id) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)

        if status == noErr { apply(shortcut) }
    }

    func stop() {
        endRecording()
        if let registration { UnregisterEventHotKey(registration.reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    func beginRecording() {
        guard let window = NSApp.keyWindow, monitor == nil else { return }
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, NSApp.keyWindow === window else { return event }
            guard !event.isARepeat else { return nil }
            if event.keyCode == UInt16(kVK_Escape),
               event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty {
                self.endRecording()
            } else if let shortcut = OpeningShortcut.recording(event) {
                self.endRecording()
                self.apply(shortcut)
            } else {
                self.message = "Нажми сочетание с ⌘, ⌥ или ⌃ либо клавишу F1–F20."
            }
            return nil
        }
    }

    func endRecording() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        message = nil
    }

    func restoreDefault() {
        endRecording()
        apply(.standard)
    }

    private func didPress(_ id: UInt32) {
        guard registration?.id == id else { return }
        if isRecording, NSApp.isActive {
            endRecording()
        } else {
            onPress?()
        }
    }

    private func apply(_ choice: OpeningShortcut) {
        message = nil
        guard handler != nil else {
            message = "Не удалось подключить глобальные сочетания."
            return
        }
        if isRegistered, choice.matches(shortcut) { return }

        nextID &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            choice.keyCode, choice.modifiers, EventHotKeyID(signature: Self.signature, id: nextID),
            GetEventDispatcherTarget(), UInt32(kEventHotKeyExclusive), &reference
        )
        guard status == noErr, let reference else {
            message = "macOS не приняла сочетание \(choice.display). Выбери другое."
            return
        }

        // keep the current shortcut active until its replacement is registered.
        if let registration { UnregisterEventHotKey(registration.reference) }
        registration = (reference, nextID)
        isRegistered = true
        if !choice.matches(shortcut) {
            shortcut = choice
            UserDefaults.standard.set(try? JSONEncoder().encode(choice), forKey: Self.storageKey)
        }
    }
}
