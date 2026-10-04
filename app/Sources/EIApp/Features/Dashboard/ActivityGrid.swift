import SwiftUI

/// GitHub-style activity grid for today: one row per selected tag, one cell per time bucket
/// from midnight, shaded by how much of that bucket the tag held for.
struct ActivityGrid: View {
    @Environment(AppModel.self) private var model
    @AppStorage("dashboard.gridTags") private var tagsRaw = "hands=face,posture=slouched,expression=frowning"
    @AppStorage("dashboard.gridBucketMinutes") private var bucketMinutes = 15

    private var tags: [FactTag] { tagsRaw.split(separator: ",").compactMap { FactTag(String($0)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SectionTitle(title: "Today")
                Picker("Resolution", selection: $bucketMinutes) {
                    Text("1 hour").tag(60)
                    Text("15 min").tag(15)
                    Text("5 min").tag(5)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                tagMenu
            }
            Group {
                if tags.isEmpty {
                    EmptyStateView(icon: "square.grid.3x3", title: "No tags selected",
                                   message: "Add a tag to see when it showed up today.")
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        GridBody(spans: model.store.todaySpans, tags: tags,
                                 bucket: TimeInterval(bucketMinutes * 60), now: context.date,
                                 remove: remove)
                    }
                }
            }
            .appCard()
        }
    }

    private var tagMenu: some View {
        let vocab = model.store.vocab
        let selected = Set(tags)
        return Menu {
            ForEach(orderedKeys(vocab.keys), id: \.self) { key in
                Section(FactStyle.label(for: key)) {
                    ForEach(vocab[key] ?? [], id: \.self) { value in
                        let tag = FactTag(key: key, value: value)
                        Button {
                            selected.contains(tag) ? remove(tag) : add(tag)
                        } label: {
                            if selected.contains(tag) {
                                Label(tag.label, systemImage: "checkmark")
                            } else {
                                Text(tag.label)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Tags", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(vocab.isEmpty)
    }

    private func add(_ tag: FactTag) {
        tagsRaw = (tags + [tag]).map(\.id).joined(separator: ",")
    }

    private func remove(_ tag: FactTag) {
        tagsRaw = tags.filter { $0 != tag }.map(\.id).joined(separator: ",")
    }
}

// MARK: - Grid

private struct Cell {
    var observed: TimeInterval = 0  // seconds of this bucket covered by any observation
    var held: TimeInterval = 0      // seconds the tag held
    var captures = 0                // captures that recorded the tag
    var elapsed: TimeInterval = 0   // seconds of this bucket that have happened so far
}

private struct GridBody: View {
    let spans: [FactSpan]
    let tags: [FactTag]
    let bucket: TimeInterval
    let now: Date
    let remove: (FactTag) -> Void

    @State private var hover: (row: Int, col: Int)?

    private let labelWidth: CGFloat = 130
    private let rowHeight: CGFloat = 18
    private let gap: CGFloat = 2
    private let minCell: CGFloat = 4
    private let maxCell: CGFloat = 26

    private var dayStart: Date { Calendar.current.startOfDay(for: now) }

    /// Buckets from midnight through the end of the current hour, so the grid grows through the day.
    private var columns: Int {
        let endOfHour = ceil(max(now.timeIntervalSince(dayStart), 1) / 3600) * 3600
        return Int(endOfHour / bucket)
    }

    var body: some View {
        let cells = tags.map { bucketed($0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(tags) { tag in RowLabel(tag: tag, height: rowHeight) { remove(tag) } }
                }
                .frame(width: labelWidth, alignment: .leading)
                GeometryReader { geo in
                    let cell = min(max((geo.size.width + gap) / CGFloat(columns) - gap, minCell), maxCell)
                    let width = CGFloat(columns) * (cell + gap) - gap
                    ScrollView(.horizontal, showsIndicators: width > geo.size.width) {
                        VStack(alignment: .leading, spacing: 4) {
                            canvas(cells, cell: cell).frame(width: width, height: gridHeight)
                            axis(cell: cell).frame(width: width, height: 12)
                        }
                    }
                    .defaultScrollAnchor(.trailing)
                }
                .frame(height: gridHeight + 16 + 8)
            }
            footer(cells)
        }
    }

    private var gridHeight: CGFloat { CGFloat(tags.count) * (rowHeight + gap) - gap }

    private func canvas(_ cells: [[Cell]], cell: CGFloat) -> some View {
        Canvas { ctx, _ in
            for (r, row) in cells.enumerated() {
                for (c, item) in row.enumerated() where item.elapsed > 0 {
                    let rect = CGRect(x: CGFloat(c) * (cell + gap), y: CGFloat(r) * (rowHeight + gap),
                                      width: cell, height: rowHeight)
                    let path = Path(roundedRect: rect, cornerRadius: min(3, cell / 3))
                    ctx.fill(path, with: .color(Self.color(item)))
                    if hover?.row == r && hover?.col == c {
                        ctx.stroke(path, with: .color(.primary.opacity(0.6)), lineWidth: 1)
                    }
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let r = Int(p.y / (rowHeight + gap)), c = Int(p.x / (cell + gap))
                hover = r < tags.count && c < columns && cells[r][c].elapsed > 0 ? (r, c) : nil
            case .ended:
                hover = nil
            }
        }
    }

    /// Hour marks, thinned so labels never collide.
    private func axis(cell: CGFloat) -> some View {
        let perHour = Int(3600 / bucket)
        let hourWidth = CGFloat(perHour) * (cell + gap)
        let step = [1, 2, 3, 4, 6].first { CGFloat($0) * hourWidth >= 34 } ?? 6
        let hours = columns / perHour
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: 0, to: hours, by: step)), id: \.self) { h in
                Text(hourLabel(h)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: CGFloat(h) * hourWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func footer(_ cells: [[Cell]]) -> some View {
        HStack(spacing: 4) {
            if let hover {
                Text(describe(tags[hover.row], cells[hover.row][hover.col], col: hover.col))
                    .font(.system(size: 11.5)).foregroundStyle(.primary)
            } else {
                Text("Shade = share of each \(bucketName) the tag held. Hover a cell for details.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("Less").font(.system(size: 10.5)).foregroundStyle(.secondary)
            ForEach(0..<Self.levels.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2).fill(Self.levels[i]).frame(width: 10, height: 10)
            }
            Text("More").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private var bucketName: String { bucket >= 3600 ? "hour" : "\(Int(bucket / 60)) minutes" }

    private func describe(_ tag: FactTag, _ cell: Cell, col: Int) -> String {
        let start = dayStart.addingTimeInterval(Double(col) * bucket)
        let range = start.formatted(date: .omitted, time: .shortened) + "–"
            + start.addingTimeInterval(bucket).formatted(date: .omitted, time: .shortened)
        guard cell.observed > 0 else { return "\(range) · \(tag.label) · no data" }
        let pct = Int((cell.held / cell.elapsed * 100).rounded())
        let caps = cell.captures == 1 ? "1 capture" : "\(cell.captures) captures"
        return "\(range) · \(tag.label) · \(formatDuration(cell.held)) (\(pct)%) · \(caps)"
    }

    // MARK: Bucketing

    private func bucketed(_ tag: FactTag) -> [Cell] {
        let origin = dayStart.timeIntervalSince1970
        let elapsedTotal = now.timeIntervalSince(dayStart)
        var out = (0..<columns).map { i in
            Cell(elapsed: min(max(elapsedTotal - Double(i) * bucket, 0), bucket))
        }
        for span in spans {
            let s = span.start.timeIntervalSince1970 - origin, e = span.end.timeIntervalSince1970 - origin
            let has = span.has(tag)
            if has && span.captured, case let i = Int(s / bucket), out.indices.contains(i) {
                out[i].captures += 1
            }
            var i = max(Int(s / bucket), 0)
            while i < columns, Double(i) * bucket < e {
                let overlap = min(e, Double(i + 1) * bucket) - max(s, Double(i) * bucket)
                if overlap > 0 {
                    out[i].observed += overlap
                    if has { out[i].held += overlap }
                }
                i += 1
            }
        }
        return out
    }

    // MARK: Color — one sequential hue, light to dark, like GitHub's contribution graph.

    private static let empty = Color.primary.opacity(0.07)
    private static let levels: [Color] = [empty] + [0.3, 0.5, 0.75, 1.0].map { AppTheme.warm.opacity($0) }

    private static func color(_ cell: Cell) -> Color {
        guard cell.observed > 0 else { return Color.primary.opacity(0.03) }
        let share = cell.held / cell.elapsed
        switch share {
        case ..<0.001: return levels[0]
        case ..<0.25: return levels[1]
        case ..<0.5: return levels[2]
        case ..<0.75: return levels[3]
        default: return levels[4]
        }
    }
}

private struct RowLabel: View {
    let tag: FactTag
    let height: CGFloat
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: FactStyle.icon(for: tag.key))
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 14)
            Text(tag.label).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove row")
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(FactStyle.label(for: tag.key))
    }
}

private func hourLabel(_ h: Int) -> String {
    let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
    return date.formatted(.dateTime.hour())
}
