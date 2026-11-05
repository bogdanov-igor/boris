import AppKit
import BorisCore
import SwiftUI

/// The tabs sit in the page's own header, next to its title.
struct WalrusPageTabs: View {
    @Bindable var model: AppModel

    private var tab: Binding<WalrusPageState.Tab> {
        Binding { model.walrusPage.tab } set: { model.walrusPage.tab = $0 }
    }

    var body: some View {
        ChoiceBar(options: [(WalrusPageState.Tab.outfits, L("Outfits")), (.themes, L("Themes")), (.packs, L("Packs"))], selection: tab, label: L("Gallery"))
            .fixedSize()
            .padding(.leading, 4)
    }
}

/// At the far end of the same header.
struct WalrusImportButton: View {
    @Bindable var model: AppModel

    var body: some View {
        Button(L("Import a pack…"), action: choose)
            .buttonStyle(PlainActionStyle(height: 26))
            .disabled(model.walrusPage.importing)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L("Choose the folder of a pack")
        panel.prompt = L("Import")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { model.importPack(from: url) }
        }
    }
}

struct WalrusPage: View {
    @Bindable var model: AppModel

    private var page: WalrusPageState { model.walrusPage }

    var body: some View {
        HStack(spacing: 0) {
            WalrusPreview(model: model)
                .frame(width: 390)
            Rectangle().fill(Palette.separator).frame(width: 1)
            ScrollView {
                Group {
                    switch page.tab {
                    case .outfits: WalrusOutfitsTab(model: model)
                    case .themes: WalrusThemesTab(model: model)
                    case .packs: WalrusPacksTab(model: model)
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay {
            if let rejection = page.rejection {
                WalrusPackErrorSheet(rejection: rejection) { page.rejection = nil }
            }
        }
        .onAppear {
            page.prepare()
            model.refreshPacks()
        }
    }
}

/// The big walrus with a choice of state and line. He loops here whatever the state, because that is what the person came to see.
private struct WalrusPreview: View {
    @Bindable var model: AppModel

    private var page: WalrusPageState { model.walrusPage }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Preview")).font(.system(size: 13, weight: .semibold))
            stage
            Text(L("State")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.text2)
            WalrusChipFlow {
                ForEach(WalrusPageState.PreviewState.allCases, id: \.self) { state in
                    WalrusChip(title: WalrusPageText.name(state), selected: state == page.state) { page.choose(state: state) }
                }
            }
            Text(L("Line for")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.text2)
            WalrusChipFlow {
                ForEach(WalrusCue.allCases, id: \.self) { cue in
                    WalrusChip(title: WalrusPageText.name(cue), selected: cue == page.cue) { page.choose(cue: cue) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
    }

    private var stage: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: DesignMetrics.radiusLarge).fill(Palette.fill1)
            WalrusView(pose: page.state.pose, outfit: model.outfit, size: 170, loops: true, stage: page.stage) {
                _ = page.stage.poke(pose: page.state.pose, reduceMotion: reduceMotion)
                page.choose(cue: .poke)
            }
            .padding(16)
            if let line = page.line {
                WalrusBubble(text: line, maxWidth: 150)
                    .padding(EdgeInsets(top: 34, leading: 196, bottom: 0, trailing: 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Text(reduceMotion ? L("movement is reduced, so he stands still") : L("the animation runs in a loop"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.text3)
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(height: 270)
    }
}

struct WalrusChip: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .foregroundStyle(selected ? Palette.window : Palette.text1)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(selected ? Palette.text1 : Palette.button))
                .overlay {
                    if !selected { Capsule().strokeBorder(Palette.buttonBorder, lineWidth: 0.5) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Chips in rows, as many in a row as fit.
struct WalrusChipFlow: Layout {
    var spacing: CGFloat = 5

    private func rows(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = rows(subviews, width: bounds.width).origins
        for (view, origin) in zip(subviews, origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }
}
