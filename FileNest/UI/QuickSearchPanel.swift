import AppKit
import Carbon
import SwiftUI

@MainActor
final class QuickSearchPanelController: NSObject, NSWindowDelegate {
    fileprivate final class Model: ObservableObject {
        @Published var query = ""
        @Published var focusRequest = UUID()
    }

    private let model = Model()
    private let settings: AppSettings
    private let submitSearch: (String) -> Void
    private lazy var panel = makePanel()

    init(settings: AppSettings, submitSearch: @escaping (String) -> Void) {
        self.settings = settings
        self.submitSearch = submitSearch
        super.init()
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.query = ""
        positionPanelOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.model.focusRequest = UUID()
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func makePanel() -> NSPanel {
        let content = QuickSearchPanelView(
            model: model,
            settings: settings,
            submit: { [weak self] query in
                self?.hide()
                self?.submitSearch(query)
            },
            dismiss: { [weak self] in self?.hide() }
        )
        let hostingView = NSHostingView(rootView: content.fileNestEnvironment(settings))
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 18
        hostingView.layer?.masksToBounds = true

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 126),
            styleMask: [.titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = settings.localized("Quick Search")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.delegate = self
        return panel
    }

    private func positionPanelOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = activeScreen?.visibleFrame else {
            panel.center()
            return
        }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

private struct QuickSearchPanelView: View {
    @ObservedObject var model: QuickSearchPanelController.Model
    @ObservedObject var settings: AppSettings
    let submit: (String) -> Void
    let dismiss: () -> Void

    private var trimmedQuery: String {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)

                QuickSearchTextField(
                    text: $model.query,
                    placeholder: settings.localized("Search file names, titles, or contents…"),
                    focusRequest: model.focusRequest,
                    submit: submitIfPossible,
                    dismiss: dismiss
                )
                .frame(height: 26)

                Button(action: submitIfPossible) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(trimmedQuery.isEmpty ? Color.secondary : Color.white)
                        .frame(width: 30, height: 30)
                        .background(
                            trimmedQuery.isEmpty ? Color.secondary.opacity(0.12) : FileNestTheme.accent,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(trimmedQuery.isEmpty)
                .accessibilityLabel(Text(settings.localized("Search")))
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(FileNestTheme.strongBorder, lineWidth: 1)
            }

            HStack {
                Text(settings.localized("Search FileNest"))
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(settings.localized("Press Return to search · Esc to close"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .background(.ultraThickMaterial)
        .onExitCommand(perform: dismiss)
    }

    private func submitIfPossible() {
        guard !trimmedQuery.isEmpty else { return }
        submit(trimmedQuery)
    }
}

private struct QuickSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: UUID
    let submit: () -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, submit: submit, dismiss: dismiss)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submitField(_:))
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 17)
        textField.lineBreakMode = .byTruncatingTail
        textField.placeholderString = placeholder
        textField.setAccessibilityLabel(placeholder)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.submit = submit
        context.coordinator.dismiss = dismiss
        textField.placeholderString = placeholder
        textField.setAccessibilityLabel(placeholder)
        if textField.stringValue != text { textField.stringValue = text }

        guard context.coordinator.focusRequest != focusRequest else { return }
        context.coordinator.focusRequest = focusRequest
        DispatchQueue.main.async { [weak textField] in
            guard let textField, textField.window?.isKeyWindow == true else { return }
            textField.window?.makeFirstResponder(textField)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var submit: () -> Void
        var dismiss: () -> Void
        var focusRequest: UUID?

        init(text: Binding<String>, submit: @escaping () -> Void, dismiss: @escaping () -> Void) {
            self.text = text
            self.submit = submit
            self.dismiss = dismiss
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        @objc func submitField(_ sender: NSTextField) {
            text.wrappedValue = sender.stringValue
            submit()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                submit()
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                submit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                dismiss()
                return true
            default:
                return false
            }
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: QuickSearchShortcut
    let recordingTitle: String
    let accessibilityLabel: String
    let onChange: (QuickSearchShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.recordingTitle = recordingTitle
        button.shortcut = shortcut
        button.onChange = onChange
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.recordingTitle = recordingTitle
        button.shortcut = shortcut
        button.onChange = onChange
        button.setAccessibilityLabel(accessibilityLabel)
        button.refreshTitle()
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut = QuickSearchShortcut.defaultValue
    var recordingTitle = "Press a shortcut…"
    var onChange: ((QuickSearchShortcut) -> Void)?
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = recordingTitle
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            finishRecording()
            return
        }

        let candidate = QuickSearchShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: QuickSearchShortcut.carbonModifiers(from: event.modifierFlags)
        )
        guard candidate.isValid else {
            NSSound.beep()
            return
        }
        shortcut = candidate
        onChange?(candidate)
        finishRecording()
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    func refreshTitle() {
        guard !isRecording else { return }
        title = shortcut.displayName
    }

    private func finishRecording() {
        isRecording = false
        refreshTitle()
    }
}
