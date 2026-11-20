import AppKit
import SwiftUI

enum ShortcutText {
    private static let modifiers: [(NSEvent.ModifierFlags, Character, String)] = [
        (.command, "@", "⌘"),
        (.option, "~", "⌥"),
        (.control, "^", "⌃"),
        (.shift, "$", "⇧")
    ]

    static func record(_ event: NSEvent) -> String? {
        guard let characters = event.characters(byApplyingModifiers: []),
              characters.unicodeScalars.count == 1,
              let codePoint = characters.unicodeScalars.first?.value,
              codePoint != 0
        else { return nil }

        let prefix = String(modifiers.compactMap { flag, symbol, _ in
            event.modifierFlags.contains(flag) ? symbol : nil
        })
        guard !prefix.isEmpty || (0xF704...0xF717).contains(codePoint) else { return nil }
        return prefix + characters
    }

    static func display(_ encoded: String) -> String {
        guard let key = encoded.last else { return "原有绑定" }
        let prefix = encoded.dropLast()
        let marks = ["^", "~", "$", "@"].compactMap { symbol in
            modifiers.first { String($0.1) == symbol && prefix.contains($0.1) }?.2
        }.joined()
        let label: String
        switch key {
        case " ": label = "空格"
        case "\t": label = "⇥"
        case "\r": label = "↩"
        case "\u{1B}": label = "⎋"
        case "\u{8}", "\u{7F}": label = "⌫"
        case "\u{F700}": label = "↑"
        case "\u{F701}": label = "↓"
        case "\u{F702}": label = "←"
        case "\u{F703}": label = "→"
        default:
            if let scalar = key.unicodeScalars.first, (0xF704...0xF726).contains(scalar.value) {
                label = "F\(scalar.value - 0xF703)"
            } else {
                label = key.uppercased()
            }
        }
        return marks + label
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: String

    func makeNSView(context: Context) -> RecordingButton {
        RecordingButton()
    }

    func updateNSView(_ button: RecordingButton, context: Context) {
        button.shortcut = value
        button.onRecord = { value = $0 }
    }
}

final class RecordingButton: NSButton {
    var shortcut = "" { didSet { updateTitle() } }
    var onRecord: ((String) -> Void)?
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("录制新快捷键")
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        guard monitor == nil, let window, window.makeFirstResponder(self) else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window, window.firstResponder === self else { return event }
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                endRecording()
            } else if let recorded = ShortcutText.record(event) {
                shortcut = recorded
                onRecord?(recorded)
                endRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
        updateTitle()
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        updateTitle()
    }

    private func updateTitle() {
        if monitor != nil {
            title = "请按下快捷键"
        } else {
            title = shortcut.isEmpty ? "录制快捷键…" : ShortcutText.display(shortcut)
        }
        invalidateIntrinsicContentSize()
    }
}
