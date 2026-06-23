import SwiftUI

/// An interactive force-directed graph of the vault (Obsidian-style): notes are
/// nodes, `[[wikilinks]]` are edges. A live physics simulation runs so dragging
/// a node makes its neighbours follow; pan by dragging the background, zoom with
/// pinch or the +/− buttons. Tap a node to open it.
struct GraphView: View {
    @EnvironmentObject var index: IndexService
    let current: URL?
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var nodes: [URL] = []
    @State private var edges: [(Int, Int)] = []
    @State private var degree: [Int] = []
    @State private var pos: [CGPoint] = []
    @State private var vel: [CGPoint] = []

    // viewport
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    // interaction
    @State private var dragNode: Int?
    @State private var dragMoved = false
    @State private var gestureActive = false
    @State private var panStart: CGSize = .zero
    @State private var alive = true

    private let canvas = CGSize(width: 860, height: 580)
    private var center: CGPoint { CGPoint(x: canvas.width / 2, y: canvas.height / 2) }
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if nodes.isEmpty {
                VStack { Spacer(); Text("沒有筆記或連結 — 用 [[筆記名]] 建立連結").foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                graphCanvas
            }
        }
        .frame(width: canvas.width, height: canvas.height + 50)
        .onAppear(perform: build)
        .onReceive(tick) { _ in step() }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
            Text(LZ("關係圖譜 Graph")).font(.headline)
            Text("\(nodes.count) 篇 · \(edges.count) 連結").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { zoomBy(0.8) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            Button(LZ("重置")) { resetView(); alive = true }
            Button(LZ("關閉"), action: onClose)
        }
        .padding(10)
    }

    private var graphCanvas: some View {
        Canvas { ctx, _ in
            for (a, b) in edges where a < pos.count && b < pos.count {
                var path = Path()
                path.move(to: toScreen(pos[a])); path.addLine(to: toScreen(pos[b]))
                ctx.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: 1)
            }
            for i in nodes.indices where i < pos.count {
                let p = toScreen(pos[i])
                let isCurrent = nodes[i] == current
                let r = (6 + CGFloat(min(degree[i], 7))) * scale
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect),
                         with: .color(isCurrent ? .orange : .purple.opacity(0.8)))
                let name = nodes[i].deletingPathExtension().lastPathComponent
                ctx.draw(Text(name).font(.system(size: max(8, 9 * scale))).foregroundStyle(.primary),
                         at: CGPoint(x: p.x, y: p.y + r + 8))
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { v in scale = min(max(lastScale * v, 0.3), 3.5); alive = true }
                .onEnded { _ in lastScale = scale }
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !gestureActive {
                    gestureActive = true
                    dragMoved = false
                    if let i = nearest(to: toGraph(g.startLocation)) {
                        dragNode = i
                    } else {
                        dragNode = nil
                        panStart = offset
                    }
                    alive = true
                }
                if let i = dragNode {
                    pos[i] = toGraph(g.location)
                    vel[i] = .zero
                } else {
                    offset = CGSize(width: panStart.width + g.translation.width,
                                    height: panStart.height + g.translation.height)
                }
                if abs(g.translation.width) + abs(g.translation.height) > 4 { dragMoved = true }
                alive = true
            }
            .onEnded { _ in
                if let i = dragNode, !dragMoved { onOpen(nodes[i]) }
                dragNode = nil
                gestureActive = false
            }
    }

    // MARK: transforms

    private func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - center.x) * scale + center.x + offset.width,
                y: (p.y - center.y) * scale + center.y + offset.height)
    }
    private func toGraph(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.width - center.x) / scale + center.x,
                y: (p.y - offset.height - center.y) / scale + center.y)
    }
    private func nearest(to p: CGPoint) -> Int? {
        var best: (Int, CGFloat)?
        for i in pos.indices {
            let d = hypot(pos[i].x - p.x, pos[i].y - p.y)
            let hit = (10 + CGFloat(min(degree[i], 7))) // graph-space radius + slop
            if d < hit, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
    private func zoomBy(_ f: CGFloat) { scale = min(max(scale * f, 0.3), 3.5); lastScale = scale }
    private func resetView() { offset = .zero; scale = 1; lastScale = 1 }

    // MARK: simulation

    private func step() {
        let n = nodes.count
        guard n > 0, (alive || dragNode != nil) else { return }
        var force = [CGPoint](repeating: .zero, count: n)
        let krep: CGFloat = 4500, kspr: CGFloat = 0.02, rest: CGFloat = 80, grav: CGFloat = 0.01, damp: CGFloat = 0.84
        for i in 0 ..< n {
            for j in (i + 1) ..< n {
                var dx = pos[i].x - pos[j].x, dy = pos[i].y - pos[j].y
                var d2 = dx * dx + dy * dy
                if d2 < 1 { d2 = 1; dx = CGFloat(i % 5 - 2) * 0.5 + 0.1; dy = 0.1 }
                let d = sqrt(d2), f = krep / d2
                force[i].x += dx / d * f; force[i].y += dy / d * f
                force[j].x -= dx / d * f; force[j].y -= dy / d * f
            }
        }
        for (a, b) in edges {
            let dx = pos[b].x - pos[a].x, dy = pos[b].y - pos[a].y
            let d = max(sqrt(dx * dx + dy * dy), 0.01), f = (d - rest) * kspr
            force[a].x += dx / d * f; force[a].y += dy / d * f
            force[b].x -= dx / d * f; force[b].y -= dy / d * f
        }
        var energy: CGFloat = 0
        for i in 0 ..< n {
            force[i].x += (center.x - pos[i].x) * grav
            force[i].y += (center.y - pos[i].y) * grav
            if i == dragNode { vel[i] = .zero; continue }
            vel[i].x = (vel[i].x + force[i].x) * damp
            vel[i].y = (vel[i].y + force[i].y) * damp
            pos[i].x += vel[i].x; pos[i].y += vel[i].y
            energy += vel[i].x * vel[i].x + vel[i].y * vel[i].y
        }
        if energy < 0.4 && dragNode == nil { alive = false }
    }

    // MARK: build

    private func build() {
        let entries = index.entries.filter { $0.ext == "md" || $0.ext == "markdown" || $0.ext == "tex" }
        nodes = entries.map { $0.url }
        let idx = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, $0.offset) })
        var es: [(Int, Int)] = []
        var deg = [Int](repeating: 0, count: nodes.count)
        for e in entries {
            guard let a = idx[e.url] else { continue }
            for link in e.links {
                if let target = index.resolveNote(link), let b = idx[target], a != b {
                    es.append((a, b)); deg[a] += 1; deg[b] += 1
                }
            }
        }
        edges = es
        degree = deg
        // Seed positions on a circle; the live sim settles them.
        let n = nodes.count
        pos = (0 ..< n).map { i in
            let a = CGFloat(i) / CGFloat(max(n, 1)) * 2 * .pi
            return CGPoint(x: center.x + cos(a) * canvas.width / 3.4,
                           y: center.y + sin(a) * canvas.height / 3.4)
        }
        vel = Array(repeating: .zero, count: n)
        alive = true
    }
}
