import AppKit
import SidePanelCore
import SwiftUI
import WebKit

/// Settings live inside the panel as a card, rather than in a separate window.
struct SettingsOverlay: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var tab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General", browser = "Browser", terminal = "Terminal", about = "About"
        var id: String { rawValue }
        var glyph: Glyph {
            switch self {
            case .general: return .edge
            case .browser: return .browser
            case .terminal: return .terminal
            case .about: return .sparkle
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(Theme.ui(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    GlyphButton(glyph: .close, size: 24, iconSize: 11, help: "Close (⎋)") { close() }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                HStack(spacing: 2) {
                    ForEach(SettingsTab.allCases) { t in
                        Button {
                            withAnimation(Theme.snappy) { tab = t }
                        } label: {
                            HStack(spacing: 5) {
                                GlyphView(glyph: t.glyph, size: 11)
                                Text(t.rawValue).font(Theme.ui(11.5, .medium))
                            }
                            .foregroundStyle(t == tab ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(t == tab ? Theme.surfaceRaised : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider().overlay(Theme.hairline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch tab {
                        case .general: GeneralSettings()
                        case .browser: BrowserSettings()
                        case .terminal: TerminalSettings()
                        case .about: AboutSettings()
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: 460, maxHeight: 600)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairlineStrong, lineWidth: 0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 50)
        }
    }

    private func close() {
        withAnimation(Theme.gentle) { state.showSettings = false }
        state.focusActiveSection()
    }
}

// MARK: - Building blocks

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.ui(10, .semibold))
                .kerning(0.8)
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.canvas.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui(12, .medium)).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail).font(Theme.ui(10.5)).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct SettingsToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
                .labelsHidden()
        }
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 12) }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var launchAtLogin = AppSettings.shared.launchAtLogin

    var body: some View {
        SettingsGroup(title: "Activation") {
            SettingsRow(title: "Keyboard shortcut",
                        detail: state.hotKeyConflict ? "That shortcut is taken by another app — pick another." : "Shows or hides SidePanel from anywhere.") {
                ShortcutRecorder(hotKey: $settings.hotKey)
            }
            RowDivider()
            SettingsToggle(title: "Reveal at screen edge",
                           detail: "Rest the pointer against the docked edge to slide the panel in.",
                           isOn: $settings.edgeActivation)
            if settings.edgeActivation {
                RowDivider()
                SettingsRow(title: "Edge delay", detail: String(format: "%.2f s", settings.edgeDelay)) {
                    Slider(value: $settings.edgeDelay, in: 0...1, step: 0.05).frame(width: 150).tint(Theme.accent)
                }
            }
        }

        SettingsGroup(title: "Panel") {
            SettingsRow(title: "Position") {
                Picker("", selection: $settings.placement) {
                    ForEach(PanelPlacement.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            RowDivider()
            SettingsRow(title: "Width", detail: "\(Int(settings.panelWidth)) pt") {
                Slider(value: Binding(get: { settings.panelWidth },
                                      set: { settings.panelWidth = $0; state.panel?.reposition(animated: false) }),
                       in: 380...1400).frame(width: 150).tint(Theme.accent)
            }
            RowDivider()
            SettingsRow(title: "Height", detail: "\(Int(settings.panelHeightFraction * 100))% of the screen") {
                Slider(value: Binding(get: { settings.panelHeightFraction },
                                      set: { settings.panelHeightFraction = $0; state.panel?.reposition(animated: false) }),
                       in: 0.4...1).frame(width: 150).tint(Theme.accent)
            }
            RowDivider()
            SettingsToggle(title: "Always on top", detail: "Float above other windows.", isOn: $settings.alwaysOnTop)
            RowDivider()
            SettingsToggle(title: "Hide when I switch apps", isOn: $settings.hideWhenInactive)
            RowDivider()
            SettingsToggle(title: "Escape hides the panel", detail: "⇧⎋ always hides, even inside terminal programs.",
                           isOn: $settings.escapeHides)
            RowDivider()
            SettingsToggle(title: "Animations", detail: "Follows the system Reduce Motion setting too.", isOn: $settings.animations)
            RowDivider()
            SettingsRow(title: "Reset size and position") {
                PillButton(title: "Reset") {
                    settings.resetPanelGeometry()
                    state.panel?.reposition(animated: true)
                }
            }
        }

        SettingsGroup(title: "Background") {
            SettingsToggle(title: "Open at login", isOn: Binding(get: { launchAtLogin }, set: {
                settings.launchAtLogin = $0
                launchAtLogin = settings.launchAtLogin
            }))
            RowDivider()
            SettingsToggle(title: "Menu bar icon", detail: "Click to toggle, right-click for options.",
                           isOn: $settings.showMenuBarIcon)
        }
    }
}

// MARK: - Browser

private struct BrowserSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var browser: BrowserModel
    @State private var clearedData = false

    var body: some View {
        SettingsGroup(title: "Search & start") {
            SettingsRow(title: "Search engine") {
                Picker("", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            RowDivider()
            SettingsRow(title: "New tabs open", detail: "Leave empty for the SidePanel start page.") {
                TextField("Start page", text: $settings.homePage)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
        }

        SettingsGroup(title: "Privacy") {
            SettingsRow(title: "Browsing history", detail: "\(browser.library.history.entries.count) pages") {
                PillButton(title: "Clear") { browser.library.clearHistory() }
            }
            RowDivider()
            SettingsRow(title: "Cookies & website data", detail: clearedData ? "Cleared." : "Signs you out of websites.") {
                PillButton(title: "Clear") {
                    let store = WKWebsiteDataStore.default()
                    store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                        clearedData = true
                    }
                }
            }
        }
    }
}

// MARK: - Terminal

private struct TerminalSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        SettingsGroup(title: "Appearance") {
            SettingsRow(title: "Font size", detail: String(format: "%.1f pt  ·  ⌘+ / ⌘− to adjust", settings.terminalFontSize)) {
                Stepper("", value: $settings.terminalFontSize, in: 8...28, step: 0.5).labelsHidden()
            }
            RowDivider()
            SettingsToggle(title: "Blinking cursor", isOn: $settings.cursorBlink)
        }

        SettingsGroup(title: "Behaviour") {
            SettingsToggle(title: "Use ⌥ as Meta", detail: "Sends Esc+key, for Emacs and readline. Off keeps ⌥ for typing special characters.",
                           isOn: $settings.optionAsMeta)
            RowDivider()
            SettingsToggle(title: "Escape hides the panel at the prompt",
                           detail: "Full-screen programs like vim always receive Escape.",
                           isOn: $settings.terminalEscapeHides)
            RowDivider()
            SettingsRow(title: "Scrollback", detail: "\(settings.scrollbackLines) lines") {
                Stepper("", value: $settings.scrollbackLines, in: 1_000...100_000, step: 1_000).labelsHidden()
            }
        }

        SettingsGroup(title: "Shell") {
            SettingsRow(title: "Shell", detail: "Empty uses your login shell (\(PTYProcessInfo.defaultShell)). Applies to new sessions.") {
                TextField("/bin/zsh", text: $settings.shellPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
        }
    }
}

enum PTYProcessInfo {
    static var defaultShell: String { PTYProcess.defaultShell() }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 52, height: 52)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("SidePanel").font(Theme.ui(16, .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Version \(version)").font(Theme.ui(11)).foregroundStyle(Theme.textSecondary)
                }
            }
            Text("A browser and a terminal that live at the edge of your screen. Built with Swift, SwiftUI, WebKit and a native PTY terminal engine.")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                PillButton(title: "Quit SidePanel", glyph: .close) { NSApp.terminate(nil) }
            }
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}
