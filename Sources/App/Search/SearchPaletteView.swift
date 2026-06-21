// SearchPaletteView — the ⌘K command palette UI (G10). A bespoke dark overlay
// (no stock List/sheet chrome) so it renders deterministically headless; bound to
// a `SearchViewModel`. Use `.commandPalette(_:)` on the root view to layer it over
// any section and bind ⌘K + Esc.

import SwiftUI

/// The palette overlay: a search field row + ranked results. Selecting a result
/// (click or Return) records the target on the view model for the lead to route.
public struct SearchPaletteView: View {
    @Bindable private var viewModel: SearchViewModel
    @FocusState private var fieldFocused: Bool

    public init(viewModel: SearchViewModel) {
        _viewModel = Bindable(viewModel)
    }

    public var body: some View {
        VStack(spacing: 0) {
            queryRow
            Divider().overlay(Color.white.opacity(0.08))
            resultsList
        }
        .frame(width: 560)
        .frame(maxHeight: 420)
        .background(SearchTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .onAppear { fieldFocused = true }
    }

    private var queryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search nodes, packets, channels…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit {
                    if let first = viewModel.results.first { viewModel.select(first) }
                }
            Text("⌘K").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var resultsList: some View {
        if viewModel.query.isEmpty {
            placeholder("Type to search the fleet")
        } else if viewModel.results.isEmpty {
            placeholder("No matches")
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(viewModel.results) { result in
                        Button {
                            viewModel.select(result)
                        } label: {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 28)
    }
}

/// One result row: a kind glyph, title + subtitle, and the kind label.
private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 13))
                .foregroundStyle(SearchTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.item.title).font(.system(size: 14)).foregroundStyle(.white)
                Text(result.item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(result.item.kind.rawValue.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private var glyph: String {
        switch result.item.kind {
        case .node: "dot.radiowaves.left.and.right"
        case .packet: "doc.text.magnifyingglass"
        case .channel: "number"
        }
    }
}

enum SearchTheme {
    static let panel = Color(red: 0.08, green: 0.09, blue: 0.15)
    static let accent = Color.cyan
}

public extension View {
    /// Layer the ⌘K command palette over this view. Binds ⌘K to open it and Esc to
    /// dismiss; the palette appears centred with a dimmed backdrop when presented.
    func commandPalette(_ viewModel: SearchViewModel) -> some View {
        modifier(CommandPaletteModifier(viewModel: viewModel))
    }
}

/// Adds an invisible ⌘K button (so the shortcut works without a menu command) and
/// the palette overlay.
private struct CommandPaletteModifier: ViewModifier {
    @Bindable var viewModel: SearchViewModel

    func body(content: Content) -> some View {
        content
            .background(
                // A zero-size button carrying the global shortcut.
                Button("Search") { viewModel.open() }
                    .keyboardShortcut("k", modifiers: .command)
                    .hidden()
            )
            .overlay {
                if viewModel.isPresented {
                    paletteOverlay
                }
            }
    }

    private var paletteOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { viewModel.isPresented = false }
            SearchPaletteView(viewModel: viewModel)
                .background(
                    Button("Dismiss") { viewModel.isPresented = false }
                        .keyboardShortcut(.cancelAction)
                        .hidden()
                )
        }
        .transition(.opacity)
    }
}

#if DEBUG
    #Preview("Command palette — results") {
        SearchPaletteView(viewModel: SearchPreviewData.viewModel(query: "base"))
            .padding(40)
            .frame(width: 680, height: 520)
            .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }
#endif
