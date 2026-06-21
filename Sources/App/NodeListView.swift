// NodeListView — a thin SwiftUI rendering of NodeListViewModel. Not unit-tested
// (UI); the presentation logic it renders is tested in the view model.

import SwiftUI

public struct NodeListView: View {
    @State private var viewModel: NodeListViewModel

    public init(viewModel: NodeListViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        List(viewModel.nodes) { node in
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).font(.headline)
                Text(node.hexID).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            try? await viewModel.load()
        }
    }
}
