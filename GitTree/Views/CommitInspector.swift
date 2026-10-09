import SwiftUI

/// The selected commit: message, author, links, where it shipped, family, branches and changed files.
struct CommitInspector: View {
    let graph: GraphViewModel

    var body: some View {
        if let commit = graph.selectedCommit, let commitGraph = graph.commitGraph, Int(commit) < commitGraph.count {
            CommitDetailView(graph: graph, commitGraph: commitGraph, commit: commit)
                .id(commitGraph.ids[Int(commit)])
        } else {
            ContentUnavailableView("No Commit Selected", systemImage: "smallcircle.filled.circle",
                                   description: Text("Select a commit to see its details."))
        }
    }
}

private struct InspectorLink: Identifiable {
    let title: String
    let systemImage: String
    let url: URL
    var id: String { url.absoluteString }
}

private struct CommitDetailView: View {
    let graph: GraphViewModel
    let commitGraph: CommitGraph
    let commit: Int32

    @State private var details: CommitDetails?
    @State private var containment: Containment?
    @State private var didLoad = false
    @State private var showAllBranches = false
    @State private var showAllFiles = false

    private var index: Int { Int(commit) }
    private var id: ObjectID { commitGraph.ids[index] }
    private var subject: String { commitGraph.subjects[index] }

    var body: some View {
        Form {
            Section {
                header
            }
            Section("Commit") {
                LabeledContent("Hash") {
                    HStack(spacing: 6) {
                        Text(id.short)
                            .monospaced()
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(id.hex, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy the full hash")
                    }
                }
                LabeledContent("Author") {
                    PersonView(name: commitGraph.authors[Int(commitGraph.authorOf[index])],
                               email: commitGraph.authorEmails[Int(commitGraph.authorOf[index])])
                }
                LabeledContent("Date") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(commitGraph.date(of: commit), format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        Text(commitGraph.date(of: commit), format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let details, details.committerEmail != details.authorEmail || details.committerName != details.authorName {
                    LabeledContent("Committer") {
                        PersonView(name: details.committerName, email: details.committerEmail)
                    }
                }
                LabeledContent("Kind", value: kind)
            }

            if !links.isEmpty {
                Section("Links") {
                    ForEach(links) { link in
                        Link(destination: link.url) {
                            Label(link.title, systemImage: link.systemImage)
                        }
                    }
                }
            }

            Section("Release") {
                if let containment {
                    if let release = containment.release {
                        LabeledContent("First release") { tagValue(release) }
                    } else if let tag = containment.firstTag {
                        LabeledContent("First tag") { tagValue(tag) }
                        Text("No tag containing this commit matches the release pattern.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not in any tag yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            let parents = commitGraph.parents(commit).filter { $0 >= 0 }
            if !parents.isEmpty {
                Section(parents.count > 1 ? "Parents" : "Parent") {
                    ForEach(Array(parents), id: \.self) { parent in
                        CommitLinkRow(commitGraph: commitGraph, commit: parent) { graph.select(parent) }
                    }
                }
            }

            let children = commitGraph.children(commit)
            if !children.isEmpty {
                Section(children.count > 1 ? "Children" : "Child") {
                    ForEach(Array(children.prefix(12)), id: \.self) { child in
                        CommitLinkRow(commitGraph: commitGraph, commit: child) { graph.select(child) }
                    }
                }
            }

            Section {
                if let containment {
                    let shown = showAllBranches ? containment.branches : Array(containment.branches.prefix(12))
                    ForEach(shown) { ref in
                        Button {
                            graph.reveal(refNamed: ref.fullName)
                        } label: {
                            Label(ref.name, systemImage: ref.kind == .remote ? "cloud" : "arrow.triangle.branch")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help("Go to \(ref.name)")
                    }
                    if containment.branches.count > shown.count {
                        Button("Show All \(containment.branches.count.formatted())") { showAllBranches = true }
                            .buttonStyle(.link)
                    }
                    if containment.branches.isEmpty {
                        Text("No branch contains this commit.").foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                HStack {
                    Text("Contained In")
                    Spacer()
                    if let containment {
                        Text("\(counted(containment.branches.count, "branch", "branches")) · \(counted(containment.tagCount, "tag", "tags"))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if let details {
                    let files = showAllFiles ? details.files : Array(details.files.prefix(60))
                    ForEach(files) { file in
                        ChangedFileRow(file: file)
                    }
                    if details.files.count > files.count {
                        Button("Show All \(details.files.count.formatted())") { showAllFiles = true }
                            .buttonStyle(.link)
                    }
                    if details.totalFiles > details.files.count {
                        Text("\((details.totalFiles - details.files.count).formatted()) more not listed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if details.totalFiles == 0 {
                        Text(commitGraph.isMerge(commit) ? "No changes compared to the first parent." : "No file changes.")
                            .foregroundStyle(.secondary)
                    }
                } else if didLoad {
                    Text("Couldn't read the changes.").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                HStack {
                    Text("Changed Files")
                    Spacer()
                    if let details {
                        Text(details.totalFiles.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } footer: {
                if commitGraph.isMerge(commit) {
                    Text("Compared to the first parent: what the merge brought in.")
                }
            }
        }
        .formStyle(.grouped)
        // Reload when the history does too: new branches may now contain this commit.
        .task(id: "\(id.hex) \(ObjectIdentifier(commitGraph).hashValue)") {
            async let loadedDetails = graph.model.details(for: commit, in: commitGraph)
            async let loadedContainment = graph.model.containment(of: commit, in: commitGraph)
            details = await loadedDetails
            containment = await loadedContainment
            didLoad = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subject)
                .font(.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let body = details?.body, !body.isEmpty {
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let refs = commitGraph.refs(at: commit)
            if !refs.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(refs) { RefBadge(ref: $0) }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var kind: String {
        let parents = commitGraph.parents(commit).count
        switch parents {
        case 0: return "Root commit"
        case 1: return "Commit"
        default: return "Merge of \(parents) parents"
        }
    }

    private var links: [InspectorLink] {
        var links: [InspectorLink] = []
        if let hosting = graph.model.hosting {
            links.append(InspectorLink(title: "Open Commit on \(hosting.displayName)", systemImage: "safari", url: hosting.commitURL(id.hex)))
            for number in PullRequestReferences.numbers(in: subject) {
                links.append(InspectorLink(title: "Pull Request #\(number)", systemImage: "arrow.triangle.pull", url: hosting.pullRequestURL(number)))
            }
        }
        let repository = graph.model.repository
        for key in commitGraph.ticketKeys(in: subject) {
            if let url = repository.issueURL(for: key) {
                links.append(InspectorLink(title: key, systemImage: "ticket", url: url))
            }
        }
        return links
    }

    private func tagValue(_ tag: GitRef) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(tag.name)
                .monospaced()
                .textSelection(.enabled)
            Text(commitGraph.date(of: tag.commit), format: .dateTime.day().month(.abbreviated).year())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PersonView: View {
    let name: String
    let email: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(name).textSelection(.enabled)
            if !email.isEmpty {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct CommitLinkRow: View {
    let commitGraph: CommitGraph
    let commit: Int32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(commitGraph.ids[Int(commit)].short)
                    .monospaced()
                    .foregroundStyle(.tint)
                Text(commitGraph.subjects[Int(commit)])
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Go to this commit")
    }
}

private struct ChangedFileRow: View {
    let file: ChangedFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(file.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

    private var color: Color {
        switch file.status {
        case "A": .green
        case "D": .red
        case "R", "C": .blue
        default: .orange
        }
    }
}

/// A branch or tag label for SwiftUI views.
struct RefBadge: View {
    let ref: GitRef

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(ref.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(foreground)
        .background(background, in: RoundedRectangle(cornerRadius: 4))
        .help(ref.isHead ? "Checked out: \(ref.name)" : ref.name)
    }

    private var icon: String {
        switch ref.kind {
        case .local: ref.isHead ? "checkmark.circle.fill" : "arrow.triangle.branch"
        case .remote: "cloud"
        case .tag: "tag.fill"
        }
    }

    private var foreground: AnyShapeStyle {
        ref.isHead ? AnyShapeStyle(.white) : (ref.kind == .tag ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
    }

    private var background: AnyShapeStyle {
        if ref.isHead { return AnyShapeStyle(.tint) }
        return ref.kind == .tag ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint.opacity(0.14))
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
