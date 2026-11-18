import AppKit
import SwiftUI

@MainActor
final class SpeakerDelegate: NSObject, NSApplicationDelegate {
    private let model = TranslatorModel()
    private let shortcuts = OpeningShortcutController()
    private var statusItem: NSStatusItem!
    private lazy var panel = makePanel()
    private var selectionTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Speaker")
                ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Speaker")
            button.image?.isTemplate = true
            button.toolTip = "Speaker — переводчик"
            button.target = self
            button.action = #selector(togglePanel)
        }

        shortcuts.start { [weak self] in self?.handleHotKey() }

        Task { await model.loadLanguages() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    @objc private func togglePanel() {
        selectionTask?.cancel()
        model.needsAccessibilityPermission = false
        if panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func handleHotKey() {
        selectionTask?.cancel()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let trusted = SelectionAccess.isTrusted
        model.needsAccessibilityPermission = !trusted

        guard trusted, let pid = frontmost?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else {
            showPanel()
            return
        }

        // read the selection before the window takes focus.
        let readSelection = Task.detached(priority: .userInitiated) {
            SelectionAccess.selectedText(in: pid)
        }
        selectionTask = Task {
            let selection = await readSelection.value
            guard !Task.isCancelled else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let selection {
                model.translateSelection(selection)
            }
            showPanel()
        }
    }

    private func showPanel() {
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingController(rootView: TranslatorView(model: model, shortcuts: shortcuts))
        host.safeAreaRegions = []
        let panel = TranslatorPanel(
            contentRect: NSRect(origin: .zero, size: host.view.fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = "Speaker"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentViewController = host

        let autosaveName = "TranslatorWindow"
        if !panel.setFrameUsingName(autosaveName) {
            if let button = statusItem.button, let statusWindow = button.window, let screen = statusWindow.screen {
                let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
                var frame = panel.frame
                frame.origin = NSPoint(x: anchor.midX - frame.width / 2, y: anchor.minY - frame.height - 6)
                panel.setFrame(panel.constrainFrameRect(frame, to: screen), display: false)
            } else {
                panel.center()
            }
        }
        panel.setFrameAutosaveName(autosaveName)
        return panel
    }

    private func installEditMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(NSMenuItem())

        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

}

@MainActor
private final class TranslatorPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}

let application = NSApplication.shared
let delegate = SpeakerDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
