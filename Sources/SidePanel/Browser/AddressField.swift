import AppKit
import SidePanelCore
import SwiftUI

/// The address / search field. Built on NSTextField so it can select-all on
/// focus, drive the suggestion list with ↑/↓ and react to Return precisely.
struct AddressField: NSViewRepresentable {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var tab: BrowserTab
    @Binding var isEditing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusAwareTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5, weight: .regular)
        field.textColor = NSColor(hex: 0xE9EBF1)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: "Search or enter address",
            attributes: [.foregroundColor: NSColor(hex: 0x5D6476), .font: NSFont.systemFont(ofSize: 12.5)])
        field.delegate = context.coordinator
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.didFocus() }
        context.coordinator.field = field
        field.stringValue = AddressResolver.displayText(for: tab.isBlank ? nil : tab.url)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if !coordinator.isEditing {
            let display = AddressResolver.displayText(for: tab.isBlank ? nil : tab.url)
            if field.stringValue != display { field.stringValue = display }
        }
        if coordinator.lastFocusRequest != browser.addressFocusRequest {
            coordinator.lastFocusRequest = browser.addressFocusRequest
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        weak var field: NSTextField?
        var isEditing = false
        var lastFocusRequest = 0

        init(_ parent: AddressField) {
            self.parent = parent
            self.lastFocusRequest = parent.browser.addressFocusRequest
        }

        func didFocus() {
            isEditing = true
            parent.isEditing = true
            // Show the full URL while editing, all selected so typing replaces it.
            if let url = parent.tab.url, !parent.tab.isBlank {
                field?.stringValue = url.absoluteString
            }
            DispatchQueue.main.async { [weak self] in self?.field?.currentEditor()?.selectAll(nil) }
        }

        func controlTextDidChange(_ obj: Notification) {
            parent.browser.updateSuggestions(for: field?.stringValue ?? "")
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            parent.isEditing = false
            parent.browser.dismissSuggestions()
            field?.stringValue = AddressResolver.displayText(for: parent.tab.isBlank ? nil : parent.tab.url)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let browser = parent.browser
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                guard !browser.suggestions.isEmpty else { return false }
                browser.highlightedSuggestion = min(browser.highlightedSuggestion + 1, browser.suggestions.count - 1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard !browser.suggestions.isEmpty else { return false }
                browser.highlightedSuggestion = max(browser.highlightedSuggestion - 1, -1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                commit(openInNewTab: NSEvent.modifierFlags.contains(.command))
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if !browser.suggestions.isEmpty {
                    browser.dismissSuggestions()
                } else {
                    field?.window?.makeFirstResponder(parent.tab.isBlank ? nil : parent.tab.webView)
                }
                return true
            default:
                return false
            }
        }

        private func commit(openInNewTab: Bool) {
            let browser = parent.browser
            let text = field?.stringValue ?? ""
            if browser.suggestions.indices.contains(browser.highlightedSuggestion) {
                let suggestion = browser.suggestions[browser.highlightedSuggestion]
                browser.open(suggestion.url, inNewTab: openInNewTab)
            } else if let url = AddressResolver.resolve(text, engine: browser.settings.searchEngine) {
                browser.open(url, inNewTab: openInNewTab)
            }
            browser.dismissSuggestions()
        }
    }
}

/// NSTextField that reports when it becomes first responder.
final class FocusAwareTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}

/// Drop-down list of suggestions under the address bar.
struct SuggestionList: View {
    @ObservedObject var browser: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(browser.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                SuggestionRow(suggestion: suggestion, isHighlighted: index == browser.highlightedSuggestion)
                    .onTapGesture { browser.open(suggestion.url) }
                    .onHover { if $0 { browser.highlightedSuggestion = index } }
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.surfaceRaised)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.hairlineStrong, lineWidth: 0.5))
    }
}

private struct SuggestionRow: View {
    let suggestion: AddressSuggestion
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 9) {
            GlyphView(glyph: glyph, size: 12)
                .foregroundStyle(isHighlighted ? Theme.accent : Theme.textTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.kind == .search ? "Search for “\(suggestion.title)”" : (suggestion.title.isEmpty ? suggestion.url.absoluteString : suggestion.title))
                    .font(Theme.ui(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if suggestion.kind != .search {
                    Text(AddressResolver.displayText(for: suggestion.url))
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHighlighted ? Theme.surfaceHover : .clear))
        .contentShape(Rectangle())
    }

    private var glyph: Glyph {
        switch suggestion.kind {
        case .bookmark: return .bookmark
        case .history: return .history
        case .search: return .search
        }
    }
}
