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

    @Environment(\.openWindow) private var openWindow
    @State private var details: CommitDetails?
    @State private var containment: Containment?
    @State private var didLoad = false
    @State private var showAllBranches = false
    @State private var showAllFiles = false
    @State private var showFullMessage = false

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
                Button("Copy GitTree Link") {
                    let repository = graph.model.repository
                    let spec = repository.kind == .local ? repository.path : (repository.remoteURL ?? repository.name)
                    guard let url = DeepLink.url(repository: spec, commit: id.hex) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                .buttonStyle(.link)
                .help("Copy a gittree:// link that opens this commit")
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

            let ticketKeys = commitGraph.ticketKeys(in: subject)
            if !ticketKeys.isEmpty, let jira = JiraStore.shared.connection(for: graph.model.repository) {
                Section(ticketKeys.count > 1 ? "Tickets" : "Ticket") {
                    ForEach(ticketKeys, id: \.self) { key in
                        TicketRow(key: key, url: jira.browseURL(key))
                    }
                    JiraProblemNote()
                }
            }

            let pullRequests = relatedPullRequests
            if !pullRequests.isEmpty, let index = graph.model.pullRequests {
                Section(pullRequests.count > 1 ? "Pull Requests" : "Pull Request") {
                    ForEach(pullRequests) { pullRequest in
                        PullRequestRow(pullRequest: pullRequest, stack: index.stack(containing: pullRequest)) { branch in
                            graph.revealBranch(named: branch)
                        }
                    }
                }
            } else if let problem = graph.model.pullRequestProblem, graph.model.hosting?.provider == .github {
                Section("Pull Requests") {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Button {
                            openWindow(id: "diff", value: DiffTarget(repositoryID: graph.model.id, commit: id.hex, path: file.path, line: nil))
                        } label: {
                            ChangedFileRow(file: file)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
            if let jira = JiraStore.shared.connection(for: graph.model.repository) {
                let keys = commitGraph.ticketKeys(in: subject)
                if !keys.isEmpty { JiraStore.shared.request(keys, connection: jira) }
            }
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
            if let details, !details.body.isEmpty {
                // Always three lines, so the sections below stay put; the full message opens on click.
                Button {
                    showFullMessage = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(details.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Show Full Message")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the whole commit message")
                .popover(isPresented: $showFullMessage, arrowEdge: .leading) {
                    ScrollView {
                        Text(details.message)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .frame(width: 480)
                    .frame(maxHeight: 560)
                    .fixedSize(horizontal: false, vertical: true)
                }
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

    /// The pull request that merged this commit, the ones its subject mentions, and open ones from
    /// branches pointing at it.
    private var relatedPullRequests: [PullRequest] {
        guard let index = graph.model.pullRequests else { return [] }
        var result: [PullRequest] = []
        func add(_ pullRequest: PullRequest?) {
            guard let pullRequest, !result.contains(where: { $0.number == pullRequest.number }) else { return }
            result.append(pullRequest)
        }
        add(index.byMergeCommit[id])
        for number in PullRequestReferences.numbers(in: subject) { add(index.byNumber[number]) }
        for ref in commitGraph.refs(at: commit) where ref.kind != .tag {
            add(index.openPullRequest(forBranch: ref.remoteParts?.branch ?? ref.name))
        }
        return result
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
            // With pull requests loaded they get their own section; otherwise link the numbers in the subject.
            let known = Set(relatedPullRequests.map(\.number))
            for number in PullRequestReferences.numbers(in: subject) where !known.contains(number) {
                links.append(InspectorLink(title: "Pull Request #\(number)", systemImage: "arrow.triangle.pull", url: hosting.pullRequestURL(number)))
            }
        }
        // With Jira connected, tickets get their own section.
        let repository = graph.model.repository
        if JiraStore.shared.connection(for: repository) == nil {
            for key in commitGraph.ticketKeys(in: subject) {
                if let url = JiraSettings.issueURL(for: key, in: repository) {
                    links.append(InspectorLink(title: key, systemImage: "ticket", url: url))
                }
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

/// A Jira ticket mentioned in the commit: its status and details. Reads the store itself so it
/// updates when the status arrives.
private struct TicketRow: View {
    let key: String
    let url: URL
    private let store = JiraStore.shared

    var body: some View {
        let _ = store.version
        let issue = store.issue(key)
        let isMissing = store.isMissing(key)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Link(destination: url) {
                    Text(verbatim: key)
                        .font(.body.monospaced().weight(.medium))
                }
                .help("Open \(key) in Jira")
                if let issue {
                    Text(issue.status)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(Color(nsColor: issue.color))
                        .background(Color(nsColor: issue.color).opacity(0.15), in: Capsule())
                } else if isMissing {
                    Text("Not found in Jira")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            if let issue {
                Text(issue.summary)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                let details = [issue.type, issue.assignee, issue.fixVersions.isEmpty ? nil : issue.fixVersions.joined(separator: ", ")]
                    .compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct JiraProblemNote: View {
    private let store = JiraStore.shared

    var body: some View {
        if let problem = store.problem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A pull request with its state, branches, review and checks, and its stack when it's stacked.
private struct PullRequestRow: View {
    let pullRequest: PullRequest
    let stack: [PullRequest]
    let revealBranch: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Link(destination: pullRequest.url) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PullRequestStateLabel(pullRequest: pullRequest)
                    Text(verbatim: "#\(pullRequest.number) \(pullRequest.title)")
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .help(Text(verbatim: "Open #\(pullRequest.number) on GitHub"))
            Text("\(pullRequest.base) ← \(pullRequest.head)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if pullRequest.state == .open {
                HStack(spacing: 10) {
                    if let review = pullRequest.reviewTitle {
                        Label(review, systemImage: pullRequest.reviewDecision == "APPROVED" ? "checkmark.seal" : "person.badge.clock")
                    }
                    if let readiness = pullRequest.readiness {
                        Label {
                            Text(readiness.explanation)
                        } icon: {
                            ReadinessMark(readiness: readiness)
                        }
                    }
                    if let author = pullRequest.author {
                        Label(author, systemImage: "person")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !stack.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stack of \(stack.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(stack.enumerated()), id: \.element.number) { position, member in
                        Button {
                            revealBranch(member.head)
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(position + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 14, alignment: .trailing)
                                Image(systemName: member.number == pullRequest.number ? "largecircle.fill.circle" : "circle")
                                    .font(.caption2)
                                    .foregroundStyle(member.number == pullRequest.number ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                Text(verbatim: "#\(member.number) \(member.title)")
                                    .font(.caption)
                                    .fontWeight(member.number == pullRequest.number ? .semibold : .regular)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Go to \(member.head)")
                    }
                    Text("Based on \(stack.first?.base ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
    }
}

struct PullRequestStateLabel: View {
    let pullRequest: PullRequest

    var body: some View {
        Text(pullRequest.stateTitle)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(.white)
            .background(color, in: Capsule())
    }

    private var color: Color {
        if pullRequest.state == .open && pullRequest.isDraft { return .gray }
        switch pullRequest.state {
        case .open: return .green
        case .merged: return .purple
        case .closed: return .red
        }
    }
}

/// Filled check: CI passed and approved. Outlined check: CI passed, waiting for approval.
struct ReadinessMark: View {
    let readiness: PullRequest.Readiness

    var body: some View {
        Image(systemName: readiness.symbol)
            .foregroundStyle(Color(nsColor: readiness.color))
            .imageScale(.small)
            .help(readiness.explanation)
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
            Spacer(minLength: 0)
        }
        .help((file.oldPath.map { "\($0) → \(file.path)" } ?? file.path) + "\nClick to see the changes")
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
