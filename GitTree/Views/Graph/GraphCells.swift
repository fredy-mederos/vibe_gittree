import AppKit

enum GraphMetrics {
    static let rowHeight: CGFloat = 24
    static let laneWidth: CGFloat = 12
    static let lanePadding: CGFloat = 8
    static let lineWidth: CGFloat = 1.6
    static let dotRadius: CGFloat = 3.8

    static func x(forLane lane: Int) -> CGFloat {
        lanePadding + CGFloat(lane) * laneWidth + laneWidth / 2
    }

    static func width(forLanes lanes: Int) -> CGFloat {
        lanePadding * 2 + CGFloat(lanes) * laneWidth
    }
}

/// System colors, so lanes adapt to light, dark and increased-contrast appearances.
enum LanePalette {
    static let colors: [NSColor] = [
        .systemBlue, .systemGreen, .systemPink, .systemTeal,
        .systemPurple, .systemOrange, .systemRed, .systemIndigo,
    ]

    static func color(_ index: UInt8) -> NSColor {
        colors[Int(index) % colors.count]
    }
}

/// A row that tints itself when it matches the search or the highlighted feature.
final class GraphRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("GraphRow")

    var isMatch = false {
        didSet { if isMatch != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // In dark mode the table draws the stripes, on a darker background (`GraphNSTableView`).
        if effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua {
            super.drawBackground(in: dirtyRect)
        }
        guard isMatch, !isSelected else { return }
        NSColor.findHighlightColor.withAlphaComponent(0.16).setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// Draws one row of the commit graph: the lines crossing the row and the commit's dot.
final class GraphCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GraphCell")

    private var layout: GraphLayout?
    private var row = 0
    private var isHead = false
    private var isMerge = false
    /// The row above the history for uncommitted changes.
    private var isWorkingRow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        // Its own layer, so a merge dot's hollow centre can be punched through to the row background.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Since macOS 14 views don't clip their drawing by default; busy rows have more lanes than
        // the column is wide and must not spill into the description.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(layout: GraphLayout, row: Int, isHead: Bool, isMerge: Bool) {
        self.layout = layout
        self.row = row
        self.isHead = isHead
        self.isMerge = isMerge
        isWorkingRow = false
        needsDisplay = true
    }

    /// The row for uncommitted changes: a dashed ring, and a dashed line down toward HEAD.
    func configureWorkingRow(layout: GraphLayout) {
        self.layout = layout
        row = 0
        isHead = false
        isMerge = false
        isWorkingRow = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let context = NSGraphicsContext.current?.cgContext else { return }
        if isWorkingRow {
            if let workingRow = layout.workingRow { drawWorkingRow(workingRow, in: context) }
            return
        }
        guard row < layout.rowCount else { return }
        let height = bounds.height
        let middle = height / 2
        context.clip(to: bounds)

        context.setLineWidth(GraphMetrics.lineWidth)
        context.setLineCap(.round)
        for segment in layout.segments(inRow: row) {
            let a = GraphMetrics.x(forLane: Int(segment.from))
            let b = GraphMetrics.x(forLane: Int(segment.to))
            setStroke(for: segment, in: context)
            context.beginPath()
            switch segment.kind {
            case .through:
                context.move(to: CGPoint(x: a, y: 0))
                context.addLine(to: CGPoint(x: a, y: height))
            case .incoming:
                context.move(to: CGPoint(x: a, y: 0))
                if a == b {
                    context.addLine(to: CGPoint(x: b, y: middle))
                } else {
                    context.addQuadCurve(to: CGPoint(x: b, y: middle), control: CGPoint(x: a, y: middle))
                }
            case .outgoing:
                context.move(to: CGPoint(x: a, y: middle))
                if a == b {
                    context.addLine(to: CGPoint(x: b, y: height))
                } else {
                    context.addQuadCurve(to: CGPoint(x: b, y: height), control: CGPoint(x: b, y: middle))
                }
            }
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])

        let center = CGPoint(x: GraphMetrics.x(forLane: Int(layout.column[row])), y: middle)
        let laneColor = LanePalette.color(layout.color[row]).cgColor
        let emphasized = backgroundStyle == .emphasized
        func circle(_ radius: CGFloat) -> CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }

        if isHead {
            // The checked-out commit: an accent ring around a dot.
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fillEllipse(in: circle(6.2))
            context.setBlendMode(.clear)
            context.fillEllipse(in: circle(4.2))
            context.setBlendMode(.normal)
            context.fillEllipse(in: circle(2.6))
        } else if isMerge {
            context.setFillColor(laneColor)
            context.fillEllipse(in: circle(GraphMetrics.dotRadius + 0.6))
            context.setBlendMode(.clear)
            context.fillEllipse(in: circle(GraphMetrics.dotRadius - 1.4))
            context.setBlendMode(.normal)
        } else {
            context.setFillColor(laneColor)
            context.fillEllipse(in: circle(GraphMetrics.dotRadius))
        }
        if emphasized {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.2)
            context.strokeEllipse(in: circle(isHead ? 6.8 : GraphMetrics.dotRadius + 1.2))
        }
    }

    /// Lane colors solid; the line from uncommitted changes dashed, in a quiet gray. The dashes
    /// repeat every 6 points, so they run on from one row (24 points) to the next.
    private func setStroke(for segment: LaneSegment, in context: CGContext) {
        if segment.color == LaneSegment.uncommittedColor {
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.setLineCap(.butt)
        } else {
            context.setStrokeColor(LanePalette.color(segment.color).cgColor)
            context.setLineDash(phase: 0, lengths: [])
            context.setLineCap(.round)
        }
    }

    private func drawWorkingRow(_ workingRow: WorkingRow, in context: CGContext) {
        let middle = bounds.height / 2
        let x = GraphMetrics.x(forLane: Int(workingRow.column))
        let radius: CGFloat = 4.6
        context.clip(to: bounds)
        context.setLineWidth(GraphMetrics.lineWidth)
        for segment in workingRow.segments {
            setStroke(for: segment, in: context)
            context.beginPath()
            context.move(to: CGPoint(x: x, y: middle + radius + 1))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            context.strokePath()
        }
        let emphasized = backgroundStyle == .emphasized
        context.setStrokeColor((emphasized ? NSColor.white : NSColor.secondaryLabelColor).cgColor)
        context.setLineDash(phase: 0, lengths: [2.4, 1.6])
        context.setLineWidth(1.6)
        context.strokeEllipse(in: CGRect(x: x - radius, y: middle - radius, width: radius * 2, height: radius * 2))
    }
}

/// Branch and tag labels followed by the commit subject, drawn in one pass.
final class DescriptionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("DescriptionCell")

    struct Badge {
        enum Style {
            case head, branch, remote, tag, overflow, pullRequest
        }

        let style: Style
        let text: String
        var prefix = ""
        var color: NSColor = .secondaryLabelColor
        /// A local branch at the same commit as its remote counterpart.
        var synced = false
        /// For pull requests: a checks indicator after the number.
        var trailingSymbol: String?
        var trailingColor: NSColor?
    }

    private var badges: [Badge] = []
    private var subject = ""
    private var isMerge = false
    private var ticketRegex: NSRegularExpression?
    private var highlight: String?
    /// For the row of uncommitted changes: what changed, after its title.
    private var detail: String?

    private static let subjectFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let workingFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    private static let ticketFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
    private static let badgeFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let badgePrefixFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let tagFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: subjectFont))
    private static let badgeLineHeight = ceil(NSLayoutManager().defaultLineHeight(for: badgeFont))
    private static let pullRequestRegex = try! NSRegularExpression(pattern: #"\(#\d+\)"#)

    private static let tailTruncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private static let middleTruncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(badges: [Badge], subject: String, isMerge: Bool, ticketRegex: NSRegularExpression?, highlight: String?) {
        self.badges = badges
        self.subject = subject
        self.isMerge = isMerge
        self.ticketRegex = ticketRegex
        self.highlight = highlight
        detail = nil
        let labels = badges.map { $0.prefix + $0.text }
        setAccessibilityLabel((labels + [subject]).joined(separator: ", "))
        toolTip = labels.isEmpty ? nil : labels.joined(separator: "  ·  ")
        needsDisplay = true
    }

    /// The row above the history: "Uncommitted Changes", then what changed ("2 staged · 3 changed").
    func configureWorkingRow(summary: String) {
        badges = []
        subject = "Uncommitted Changes"
        isMerge = false
        ticketRegex = nil
        highlight = nil
        detail = summary
        setAccessibilityLabel("Uncommitted changes: \(summary)")
        toolTip = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let emphasized = backgroundStyle == .emphasized
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var x: CGFloat = 4
        let badgeLimit = bounds.width * 0.6
        for badge in badges {
            let room = badgeLimit - x
            guard room > 36 else { break }
            x += drawBadge(badge, x: x, maxWidth: min(260, room), emphasized: emphasized, isDark: isDark) + 4
        }
        if !badges.isEmpty { x += 2 }
        let rect = NSRect(x: x, y: floor((bounds.height - Self.lineHeight) / 2),
                          width: max(0, bounds.width - x - 4), height: Self.lineHeight)
        attributedSubject(emphasized: emphasized).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func attributedSubject(emphasized: Bool) -> NSAttributedString {
        let base: NSColor = emphasized ? .alternateSelectedControlTextColor : (isMerge ? .secondaryLabelColor : .labelColor)
        let text = NSMutableAttributedString(string: subject, attributes: [
            .font: detail == nil ? Self.subjectFont : Self.workingFont, .foregroundColor: base, .paragraphStyle: Self.tailTruncating,
        ])
        if let detail, !detail.isEmpty {
            text.append(NSAttributedString(string: "   " + detail, attributes: [
                .font: Self.subjectFont, .paragraphStyle: Self.tailTruncating,
                .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : NSColor.secondaryLabelColor,
            ]))
        }
        let full = NSRange(location: 0, length: (subject as NSString).length)
        if let ticketRegex {
            for match in ticketRegex.matches(in: subject, range: full) {
                text.addAttribute(.font, value: Self.ticketFont, range: match.range)
            }
        }
        let dim: NSColor = emphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7) : .tertiaryLabelColor
        for match in Self.pullRequestRegex.matches(in: subject, range: full) {
            text.addAttribute(.foregroundColor, value: dim, range: match.range)
        }
        if let highlight, !highlight.isEmpty {
            let string = subject as NSString
            var searchRange = full
            while searchRange.length > 0 {
                let found = string.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                text.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], range: found)
                let next = found.location + found.length
                searchRange = NSRange(location: next, length: full.length - next)
            }
        }
        return text
    }

    /// Returns the badge's width.
    private func drawBadge(_ badge: Badge, x: CGFloat, maxWidth: CGFloat, emphasized: Bool, isDark: Bool) -> CGFloat {
        var textColor: NSColor
        var fill: NSColor?
        var stroke: NSColor?
        var dashed = false
        var symbol: String?
        switch badge.style {
        case .head:
            fill = .controlAccentColor
            textColor = .white
        case .branch:
            fill = badge.color.withAlphaComponent(isDark ? 0.24 : 0.13)
            stroke = badge.color.withAlphaComponent(0.55)
            textColor = Self.readable(badge.color, isDark: isDark)
        case .remote:
            stroke = badge.color.withAlphaComponent(0.7)
            dashed = true
            textColor = Self.readable(badge.color, isDark: isDark)
        case .tag:
            fill = .quaternaryLabelColor
            textColor = .secondaryLabelColor
            symbol = "tag.fill"
        case .overflow:
            stroke = .separatorColor
            textColor = .secondaryLabelColor
        case .pullRequest:
            fill = badge.color.withAlphaComponent(isDark ? 0.26 : 0.15)
            textColor = Self.readable(badge.color, isDark: isDark)
            symbol = "arrow.triangle.pull"
        }
        if emphasized {
            textColor = .white
            fill = .white.withAlphaComponent(badge.style == .head ? 0.32 : 0.16)
            if stroke != nil { stroke = .white.withAlphaComponent(0.55) }
        }

        let label = NSMutableAttributedString()
        if !badge.prefix.isEmpty {
            label.append(NSAttributedString(string: badge.prefix, attributes: [
                .font: Self.badgePrefixFont, .foregroundColor: textColor.withAlphaComponent(0.65), .paragraphStyle: Self.middleTruncating,
            ]))
        }
        label.append(NSAttributedString(string: badge.text, attributes: [
            .font: badge.style == .tag ? Self.tagFont : Self.badgeFont, .foregroundColor: textColor, .paragraphStyle: Self.middleTruncating,
        ]))

        let padding: CGFloat = 5
        let leadingSymbolWidth: CGFloat = symbol == nil ? 0 : 11
        let trailingSymbolWidth: CGFloat = (badge.synced || badge.trailingSymbol != nil) ? 12 : 0
        let textWidth = min(ceil(label.size().width), max(16, maxWidth - padding * 2 - leadingSymbolWidth - trailingSymbolWidth))
        let width = textWidth + padding * 2 + leadingSymbolWidth + trailingSymbolWidth
        let height: CGFloat = 16
        let rect = NSRect(x: x, y: floor((bounds.height - height) / 2), width: width, height: height)

        // Pull requests are capsules so they read differently from branch labels.
        let radius: CGFloat = badge.style == .pullRequest ? height / 2 : 4
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if let fill {
            fill.setFill()
            path.fill()
        }
        if let stroke {
            stroke.setStroke()
            path.lineWidth = 1
            if dashed { path.setLineDash([3, 2], count: 2, phase: 0) }
            path.stroke()
        }

        var cursor = rect.minX + padding
        if let symbol {
            drawSymbol(symbol, color: textColor, leadingX: cursor, midY: rect.midY)
            cursor += leadingSymbolWidth
        }
        label.draw(with: NSRect(x: cursor, y: rect.minY + floor((height - Self.badgeLineHeight) / 2), width: textWidth, height: Self.badgeLineHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if badge.synced {
            drawSymbol("cloud.fill", color: textColor.withAlphaComponent(0.75), leadingX: rect.maxX - padding - 10, midY: rect.midY)
        } else if let trailing = badge.trailingSymbol {
            let color = emphasized ? NSColor.white : (badge.trailingColor ?? textColor)
            drawSymbol(trailing, color: color, leadingX: rect.maxX - padding - 10, midY: rect.midY)
        }
        return width
    }

    private func drawSymbol(_ name: String, color: NSColor, leadingX: CGFloat, midY: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let rect = NSRect(x: leadingX, y: midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Lane colors are tuned for lines; text needs a little more contrast against the tinted fill.
    private static func readable(_ color: NSColor, isDark: Bool) -> NSColor {
        isDark ? (color.blended(withFraction: 0.25, of: .white) ?? color) : (color.blended(withFraction: 0.3, of: .black) ?? color)
    }
}

/// The first ticket in the commit's subject: a bug glyph when it's a bug, its Jira status as a
/// colored capsule, and its fix version.
final class TicketStatusCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TicketStatusCell")
    private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))

    private var issue: JiraIssue?
    /// Its status category's color, its project's Definition of Done counting as done.
    private var color: NSColor = .systemGray

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    func configure(key: String?, issue: JiraIssue?, epic: JiraLink? = nil, category: JiraIssue.Category? = nil) {
        self.issue = issue
        color = (category ?? issue?.category ?? .unknown).color
        if let issue {
            let versions = issue.fixVersions.isEmpty ? "" : " · fix version \(issue.fixVersions.joined(separator: ", "))"
            let epicLine = epic.map { $0.key == issue.key ? "" : "\nEpic: \($0.key) \($0.summary)" } ?? ""
            let type = issue.type.map { " · \($0)" } ?? ""
            toolTip = "\(issue.key)\(type) · \(issue.status)\(versions)\n\(issue.summary)\(epicLine)"
            setAccessibilityLabel("\(issue.key) \(issue.type ?? "") \(issue.status)")
        } else {
            toolTip = key
            setAccessibilityLabel(key)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let issue else { return }
        let emphasized = backgroundStyle == .emphasized
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let textColor: NSColor = emphasized ? .white
            : (isDark ? (color.blended(withFraction: 0.25, of: .white) ?? color)
                      : (color.blended(withFraction: 0.3, of: .black) ?? color))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: issue.status, attributes: [.font: Self.font, .foregroundColor: textColor, .paragraphStyle: style])
        if issue.isBug { drawBugSymbol(emphasized: emphasized) }
        let leading = 2 + Self.symbolWidth + 4
        let height: CGFloat = 16
        let width = max(0, min(ceil(text.size().width) + 14, bounds.width - 2 - leading))
        let rect = NSRect(x: leading, y: floor((bounds.height - height) / 2), width: width, height: height)
        let fill = emphasized ? NSColor.white.withAlphaComponent(0.2) : color.withAlphaComponent(isDark ? 0.26 : 0.15)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        text.draw(with: NSRect(x: rect.minX + 7, y: rect.minY + floor((height - Self.lineHeight) / 2), width: rect.width - 14, height: Self.lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        // The fix version after the status, in the remaining width.
        guard !issue.fixVersions.isEmpty, bounds.width - rect.maxX > 20 else { return }
        let version = NSAttributedString(string: issue.fixVersions.joined(separator: ", "), attributes: [
            .font: Self.versionFont,
            .foregroundColor: emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        version.draw(with: NSRect(x: rect.maxX + 6, y: floor((bounds.height - Self.lineHeight) / 2), width: bounds.width - rect.maxX - 8, height: Self.lineHeight),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static let versionFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// Draws the sidebar's bug glyph in the slot before the status, white on a selected row. Other
    /// types leave the slot empty, so the statuses line up.
    private func drawBugSymbol(emphasized: Bool) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [emphasized ? .white : .systemRed]))
        guard let image = NSImage(systemSymbolName: "ladybug.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let rect = NSRect(x: 2 + floor((Self.symbolWidth - size.width) / 2), y: floor((bounds.height - size.height) / 2),
                          width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static let symbolWidth: CGFloat = 14
}

/// A plain text column (author, date, hash).
final class TextCellView: NSTableCellView {
    convenience init(identifier: NSUserInterfaceItemIdentifier, font: NSFont, color: NSColor) {
        self.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
