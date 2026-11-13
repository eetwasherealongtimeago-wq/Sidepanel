import AppKit
import SwiftUI

/// Click, then press a key combination. ⎋ cancels, ⌫ restores the default.
struct ShortcutRecorder: View {
    @Binding var hotKey: HotKey
    @State private var recording = false
    @State private var monitor: Any?
    @State private var invalidAttempt = false

    var body: some View {
        Button {
            if recording { stop() } else { start() }
        } label: {
            HStack(spacing: 6) {
                GlyphView(glyph: .keyboard, size: 12)
                Text(recording ? (invalidAttempt ? "Add ⌘, ⌥ or ⌃" : "Type shortcut…") : hotKey.displayString)
                    .font(recording ? Theme.ui(11.5, .medium) : Theme.mono(12, .semibold))
            }
            .foregroundStyle(recording ? Theme.accent : Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(minWidth: 120, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(recording ? Theme.accent.opacity(0.7) : Theme.hairlineStrong, lineWidth: recording ? 1 : 0.5))
        }
        .buttonStyle(PressableStyle())
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        invalidAttempt = false
        // Free the current shortcut so pressing it again can be recorded.
        HotKeyCenter.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 && flags.isEmpty { stop(); return }           // ⎋ cancel
        if event.keyCode == 51 && flags.isEmpty {                            // ⌫ default
            hotKey = .defaultToggle
            stop()
            return
        }
        let candidate = HotKey(event: event)
        guard candidate.isValid else {
            invalidAttempt = true
            NSSound.beep()
            return
        }
        hotKey = candidate
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            // Re-register whatever is current (unchanged keys don't trigger the settings observer).
            HotKeyCenter.shared.register(hotKey)
        }
    }
}
