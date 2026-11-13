import SwiftUI
import UniformTypeIdentifiers

/// Data for one tab pill; shared by browser tabs and terminal sessions so both
/// halves of the app look and behave the same.
struct TabPillModel: Identifiable, Equatable {
    let id: UUID
    var title: String
    var avatarSeed: String
    var isLoading = false
    var hasBadge = false
    var monospaced = false
}

struct TabStrip: View {
    let tabs: [TabPillModel]
    let selectedID: UUID?
    var leadingGlyph: Glyph? = nil
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void
    var onMove: ((UUID, UUID) -> Void)? = nil

    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(tabs) { tab in
                            TabPill(model: tab,
                                    isSelected: tab.id == selectedID,
                                    namespace: selectionNamespace,
                                    onSelect: { onSelect(tab.id) },
                                    onClose: { onClose(tab.id) })
                                .id(tab.id)
                                .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
                                .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                    guard let onMove, let provider = providers.first else { return false }
                                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                                        guard let s = object as? String, let source = UUID(uuidString: s) else { return }
                                        DispatchQueue.main.async { withAnimation(Theme.snappy) { onMove(source, tab.id) } }
                                    }
                                    return true
                                }
                        }
                    }
                    .padding(.horizontal, 2)
                    .animation(Theme.snappy, value: tabs.map(\.id))
                }
                .onChange(of: selectedID) { id in
                    guard let id else { return }
                    withAnimation(Theme.gentle) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            GlyphButton(glyph: .plus, size: 24, iconSize: 12, help: "New tab (⌘T)", action: onNew)
        }
        .frame(height: 30)
        .padding(.horizontal, 8)
    }
}

private struct TabPill: View {
    let model: TabPillModel
    let isSelected: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                LetterAvatar(text: model.avatarSeed, size: 14)
                if model.isLoading {
                    LoadingRing().frame(width: 18, height: 18)
                }
            }
            Text(model.title)
                .font(model.monospaced ? Theme.mono(11, .medium) : Theme.ui(11.5, .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            if model.hasBadge && !isSelected {
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                GlyphView(glyph: .close, size: 10, weight: 1.2)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Theme.surfaceHover.opacity(hovering ? 1 : 0)))
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(minWidth: 96, maxWidth: 180, minHeight: 26, maxHeight: 26)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.hairlineStrong, lineWidth: 0.5))
                    .matchedGeometryEffect(id: "selected-tab", in: namespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(Theme.gentle, value: hovering)
    }
}

/// A small rotating arc used as the loading indicator.
struct LoadingRing: View {
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}
