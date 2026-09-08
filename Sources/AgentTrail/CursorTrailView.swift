import AppKit
import Combine
import SwiftUI
import TrailCore

struct CursorTrailRequest: Identifiable {
    let id = UUID()
    let sessionID: String
    let title: String
    var firstEventID: Int64 = 1
    var lastEventID: Int64 = Int64.max
}

struct CursorTrailView: View {
    let store: TrailStore
    let request: CursorTrailRequest
    @Environment(\.dismiss) private var dismiss
    @State private var trail = CursorTrail(events: [])
    @State private var page: CursorPage?
    @State private var pageCursors: [Int64] = []
    @State private var refreshID = UUID()
    @State private var loading = true
    @State private var failure: String?
    @State private var position = 0.0
    @State private var manualIndex: Int?
    @State private var isPlaying = false
    @State private var speed = 1.0
    @State private var anchorTime = 0.0
    @State private var anchorPosition = 0.0
    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    private var pageAfterID: Int64 { pageCursors.last ?? max(0, request.firstEventID - 1) }
    private var currentIndex: Int? { manualIndex ?? trail.sampleIndex(at: position) }
    private var currentSample: CursorSample? { currentIndex.map { trail.samples[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cursor trail").font(.system(size: 24, weight: .semibold))
                    Text(request.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(loading)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 18) {
                legend("Move", color: .secondary, dashed: true)
                legend("Drag", color: Studio.signal)
                HStack(spacing: 5) {
                    Circle().stroke(Studio.signal, lineWidth: 1.5).frame(width: 8, height: 8)
                    Text("Button down")
                }
                Spacer()
                Text("\(trail.samples.count.formatted()) samples · \(trail.clickCount) \(trail.clickCount == 1 ? "press" : "presses") · \(trail.breakCount) \(trail.breakCount == 1 ? "break" : "breaks")")
                    .monospacedDigit().lineLimit(1)
            }.font(.system(size: 11)).foregroundStyle(.secondary)

            ZStack {
                if loading {
                    ProgressView("Reading cursor samples…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failure {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text(failure).multilineTextAlignment(.center)
                        Button("Retry") { reload() }
                    }.foregroundStyle(.secondary).padding(24)
                } else if trail.samples.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "cursorarrow.motionlines").font(.system(size: 32, weight: .light))
                        Text("No pointer samples in this range").font(.system(size: 16, weight: .medium))
                        Text("Choose a movement or drag action, open another part, or record a session with mouse input.")
                            .font(.system(size: 12)).multilineTextAlignment(.center).frame(maxWidth: 350)
                    }.foregroundStyle(.secondary).padding(28)
                } else {
                    CursorMap(trail: trail, currentIndex: currentIndex)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 340)
            .background(Studio.inset, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recorded cursor coordinate map")
            .accessibilityValue(currentSample.map { "Event \($0.id), x \(coordinate($0.x)), y \(coordinate($0.y)), \($0.kind)" } ?? "No pointer samples")

            HStack(spacing: 12) {
                Button { togglePlayback() } label: {
                    Label(isPlaying ? "Pause" : position >= trail.duration ? "Replay" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 60)
                }.buttonStyle(.borderedProminent).disabled(loading || trail.samples.count < 2 || trail.duration == 0)
                Button { step(-1) } label: { Image(systemName: "backward.end.fill") }.help("Previous recorded sample").accessibilityLabel("Previous recorded sample").disabled(loading || trail.samples.isEmpty)
                Button { step(1) } label: { Image(systemName: "forward.end.fill") }.help("Next recorded sample").accessibilityLabel("Next recorded sample").disabled(loading || trail.samples.isEmpty)
                Slider(value: Binding(get: { position }, set: { position = $0; manualIndex = nil; isPlaying = false }), in: 0...max(0.001, trail.duration))
                    .disabled(loading || trail.samples.isEmpty).accessibilityLabel("Cursor playback time")
                Text("\(time(position)) / \(time(trail.duration))").font(.system(size: 11, design: .monospaced)).monospacedDigit().frame(width: 130)
                Picker("Speed", selection: $speed) {
                    Text("½×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                    Text("4×").tag(4.0)
                }.labelsHidden().frame(width: 64).accessibilityLabel("Playback speed")
                    .onChange(of: speed) { anchorPosition = position; anchorTime = ProcessInfo.processInfo.systemUptime }
            }.controlSize(.regular)

            HStack(alignment: .firstTextBaseline, spacing: 20) {
                if let sample = currentSample {
                    Text("x \(coordinate(sample.x))   y \(coordinate(sample.y))")
                        .font(.system(size: 16, weight: .medium, design: .monospaced)).monospacedDigit().textSelection(.enabled)
                    Text("#\(sample.id) · \(sample.kind.replacingOccurrences(of: "mouse_", with: ""))\(sample.button.map { " · button \($0)" } ?? "")")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(sample.app).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("x —   y —").font(.system(size: 16, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                }
            }.frame(height: 24)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Coordinate map fitted to recorded motion. Lines connect samples; gaps and app changes break the path.")
                    Text("Playback stays in this viewer. It does not move your real cursor or replay app actions.")
                    if let sample = currentSample { Text("Observed \(SessionExport.iso(sample.timestamp))").font(.system(size: 10, design: .monospaced)) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if page?.hasMore == true || !pageCursors.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack {
                            Button("Previous part") { pageCursors.removeLast(); reload() }.disabled(pageCursors.isEmpty || loading)
                            Button("Next part") {
                                if let lastID = page?.lastEventID { pageCursors.append(lastID); reload() }
                            }.disabled(page?.hasMore != true || loading)
                        }
                        Text("Part \(pageCursors.count + 1) · up to 20,000 records per part").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24).frame(width: 860).tint(Studio.signal)
        .task(id: refreshID) { await load() }
        .onReceive(timer) { _ in
            guard isPlaying else { return }
            manualIndex = nil
            position = min(trail.duration, anchorPosition + (ProcessInfo.processInfo.systemUptime - anchorTime) * speed)
            if position >= trail.duration { isPlaying = false }
        }
        .onDisappear { isPlaying = false }
    }

    private func load() async {
        loading = true
        isPlaying = false
        failure = nil
        let dataStore = store
        let sessionID = request.sessionID
        let afterID = pageAfterID
        let throughID = request.lastEventID
        do {
            let result = try await Task.detached {
                let page = try dataStore.cursorPage(sessionID: sessionID, afterID: afterID, throughID: throughID)
                return (page, CursorTrail(events: page.events))
            }.value
            guard !Task.isCancelled else { return }
            page = result.0
            trail = result.1
            position = trail.duration
            manualIndex = nil
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            loading = false
        }
    }

    private func reload() { isPlaying = false; refreshID = UUID() }

    private func togglePlayback() {
        if isPlaying { isPlaying = false; return }
        if position >= trail.duration { position = 0 }
        manualIndex = nil
        anchorPosition = position
        anchorTime = ProcessInfo.processInfo.systemUptime
        isPlaying = true
    }

    private func step(_ delta: Int) {
        isPlaying = false
        guard let index = currentIndex, !trail.samples.isEmpty else { return }
        let next = min(trail.samples.count - 1, max(0, index + delta))
        manualIndex = next
        position = trail.samples[next].elapsed
    }

    private func coordinate(_ value: Double) -> String { String(format: "%.1f", value) }
    private func time(_ value: Double) -> String { String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60)) }

    private func legend(_ name: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: dashed ? 12 : 18, height: dashed ? 1 : 2)
            Text(name)
        }
    }
}

private struct CursorMap: View {
    let trail: CursorTrail
    let currentIndex: Int?

    var body: some View {
        Canvas { context, size in
            let projection = CursorProjection(bounds: trail.bounds, width: size.width, height: size.height, padding: 38)
            let gridColor = Color.secondary.opacity(0.12)
            var grid = Path()
            for horizontal in stride(from: 20.0, through: size.width, by: 24) {
                for vertical in stride(from: 20.0, through: size.height, by: 24) {
                    grid.addEllipse(in: CGRect(x: horizontal, y: vertical, width: 1.5, height: 1.5))
                }
            }
            context.fill(grid, with: .color(gridColor))
            let bounds = trail.bounds
            let top = projection.project(x: bounds.minX, y: bounds.minY)
            let bottom = projection.project(x: bounds.minX + bounds.width, y: bounds.minY + bounds.height)
            context.draw(Text(String(format: "x %.0f", bounds.minX)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: top.x, y: size.height - 14), anchor: .leading)
            context.draw(Text(String(format: "x %.0f", bounds.minX + bounds.width)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: bottom.x, y: size.height - 14), anchor: .trailing)
            context.draw(Text(String(format: "y %.0f", bounds.minY)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: 12, y: 14), anchor: .leading)
            guard let currentIndex, !trail.samples.isEmpty else { return }
            var moves = Path()
            var drags = Path()
            var previous: CursorSample?
            for sample in trail.samples.prefix(currentIndex + 1) {
                let location = projection.project(x: sample.x, y: sample.y)
                let point = CGPoint(x: location.x, y: location.y)
                if let previous, !sample.startsSegment {
                    let origin = projection.project(x: previous.x, y: previous.y)
                    if sample.isDrag || (sample.kind == "mouse_up" && previous.isDrag) {
                        drags.move(to: CGPoint(x: origin.x, y: origin.y))
                        drags.addLine(to: point)
                    } else {
                        moves.move(to: CGPoint(x: origin.x, y: origin.y))
                        moves.addLine(to: point)
                    }
                }
                previous = sample
            }
            context.stroke(moves, with: .color(.secondary.opacity(0.65)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            context.stroke(drags, with: .color(Studio.signal), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            for sample in trail.samples.prefix(currentIndex + 1) where sample.isClick {
                let location = projection.project(x: sample.x, y: sample.y)
                let ring = Path(ellipseIn: CGRect(x: location.x - 7, y: location.y - 7, width: 14, height: 14))
                context.fill(ring, with: .color(Studio.surface))
                context.stroke(ring, with: .color(Studio.signal), lineWidth: 1.5)
                context.draw(Text(sample.button == 1 ? "R" : sample.button == 0 ? "L" : String(sample.button ?? 0)).font(.system(size: 7, weight: .semibold, design: .monospaced)).foregroundColor(Studio.signal), at: CGPoint(x: location.x, y: location.y))
            }
            let sample = trail.samples[currentIndex]
            let location = projection.project(x: sample.x, y: sample.y)
            let halo = Path(ellipseIn: CGRect(x: location.x - 12, y: location.y - 12, width: 24, height: 24))
            context.fill(halo, with: .color(Studio.signal.opacity(0.12)))
            context.fill(Path(ellipseIn: CGRect(x: location.x - 3, y: location.y - 3, width: 6, height: 6)), with: .color(Studio.signal))
            context.draw(Image(systemName: "cursorarrow").resizable(), in: CGRect(x: location.x + 4, y: location.y - 2, width: 13, height: 19))
        }
    }
}
