import SwiftUI

/// ⌘K: type part of a repository's name or path and press Return to switch to it.
/// Without a query, repositories are listed most recently opened first.
struct RepositorySwitcher: View {
    let state: WindowState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var searchFocused: Bool
    private let library = RepositoryLibrary.shared

    private var results: [Repository] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = library.byRecency
        guard !needle.isEmpty else { return candidates }
        return candidates
            .compactMap { repository -> (Repository, Int)? in
                let score = Self.score(repository, needle)
                return score > 0 ? (repository, score) : nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Switch to Repository", text: $query, prompt: Text("Switch to repository"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { open(selection) }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            }
            .padding(12)

            Divider()

            if results.isEmpty {
                Text("No repository matches “\(query)”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    List(results, selection: $selection) { repository in
                        HStack(spacing: 10) {
                            Image(systemName: repository.kind == .remote ? "globe" : "folder")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(repository.name)
                                    .fontWeight(repository.id == state.repositoryID ? .semibold : .regular)
                                Text(repository.fullLocation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer()
                            if let opened = repository.lastOpenedAt {
                                Text(opened, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(repository.id)
                        .id(repository.id)
                    }
                    .listStyle(.plain)
                    .contextMenu(forSelectionType: UUID.self, menu: { _ in }, primaryAction: { ids in open(ids.first) })
                    .onChange(of: selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                .frame(height: 340)
            }
        }
        .frame(width: 580)
        .onAppear {
            searchFocused = true
            selection = results.first?.id
        }
        .onChange(of: query) {
            selection = results.first?.id
        }
        .onExitCommand { dismiss() }
    }

    private func moveSelection(_ delta: Int) {
        let list = results
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selection } ?? -1
        selection = list[max(0, min(list.count - 1, current + delta))].id
    }

    private func open(_ id: UUID?) {
        guard let id else { return }
        state.open(id)
        dismiss()
    }

    /// Name prefix beats name match beats path match; letters in order ("aand" → acme-android) count too.
    private static func score(_ repository: Repository, _ needle: String) -> Int {
        let name = repository.name.lowercased()
        if name.hasPrefix(needle) { return 400 }
        if name.contains(needle) { return 300 }
        if repository.fullLocation.lowercased().contains(needle) { return 200 }
        var remaining = Substring(needle)
        for character in name where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 100 }
        }
        return 0
    }
}
