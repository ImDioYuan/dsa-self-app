import SwiftData
import SwiftUI

/// 画在四象限里的一件事（同一件事的几条只画一个点）
struct MatrixTask: Identifiable, Equatable {
    let id: PersistentIdentifier
    let title: String
    let due: Date?
    let importance: Importance
    let quadrant: Quadrant
    /// 横轴位置 0…1（UrgencyScale.x）
    let x: Double
}

/// 某个缩放程度下每个点画在哪。
/// 纵轴分四条（很重要 / 重要 / 一般 / 不重要），横轴按截止时间；同一条里靠得太近、
/// 标签会叠在一起的几个合成一个「N」气泡，放大后间距变大，气泡就散开成一个个任务
struct MatrixLayout {
    /// 缩小时只画点，放大一些显示标题，再放大连截止时间一起显示
    enum Detail: Equatable { case dots, titles, full }

    enum NodeID: Hashable {
        case task(PersistentIdentifier)
        case cluster(PersistentIdentifier, Int)
    }

    struct Node: Identifiable {
        enum Kind {
            case task(MatrixTask)
            case cluster([MatrixTask])
        }

        let id: NodeID
        let kind: Kind
        let center: CGPoint
        let quadrant: Quadrant
    }

    static let maxZoom: CGFloat = 6
    /// iPhone 上绘图区的宽度。显示到哪一级看「有效倍率」：iPad、Mac 的全屏更宽，不放大也能显示标题
    static let referenceWidth: CGFloat = 330
    static let bands = 4
    static let gap: CGFloat = 4

    /// 绘图区大小（不含坐标轴）
    let size: CGSize
    let zoom: CGFloat
    /// 内容左上角在绘图区里的位置（放大后拖动，最大是 0）
    let offset: CGPoint
    let detail: Detail
    private(set) var nodes: [Node] = []

    static func detail(for zoom: CGFloat) -> Detail {
        zoom < 1.5 ? .dots : (zoom < 2.6 ? .titles : .full)
    }

    static func chipSize(_ detail: Detail) -> CGSize {
        switch detail {
        case .dots: CGSize(width: 22, height: 22)
        case .titles: CGSize(width: 96, height: 24)
        case .full: CGSize(width: 132, height: 36)
        }
    }

    /// 从上往下第几条：很重要 0 … 不重要 3
    static func band(of importance: Importance) -> Int { Importance.critical.rawValue - importance.rawValue }

    func screenX(_ x: Double) -> CGFloat { offset.x + CGFloat(x) * size.width * zoom }
    func screenY(_ y: Double) -> CGFloat { offset.y + CGFloat(y) * size.height * zoom }
    var bandHeight: CGFloat { size.height * zoom / CGFloat(Self.bands) }
    func bandCenterY(_ band: Int) -> CGFloat { screenY((Double(band) + 0.5) / Double(Self.bands)) }

    func rect(of quadrant: Quadrant) -> CGRect {
        let x0 = quadrant.isUrgent ? 0 : UrgencyScale.divider
        let y0 = quadrant.isImportant ? 0 : 0.5
        let origin = CGPoint(x: screenX(x0), y: screenY(y0))
        return CGRect(origin: origin, size: CGSize(width: size.width * zoom / 2, height: size.height * zoom / 2))
    }

    init(tasks: [MatrixTask], size: CGSize, zoom: CGFloat, offset: CGPoint) {
        self.size = size
        self.zoom = zoom
        self.offset = offset
        detail = Self.detail(for: zoom * size.width / Self.referenceWidth)
        nodes = (0..<Self.bands).flatMap { band in
            layoutBand(band, tasks.filter { Self.band(of: $0.importance) == band })
        }
    }

    private func layoutBand(_ band: Int, _ tasks: [MatrixTask]) -> [Node] {
        let chip = Self.chipSize(detail)
        let half = chip.width / 2 + 2
        let dividerX = screenX(UrgencyScale.divider)
        let centerY = bandCenterY(band)

        // 先把每个点限制在自己那一半里（标签不跨过中线、不伸出边界），再从左到右排
        let placed = tasks.map { task -> (task: MatrixTask, x: CGFloat) in
            let lo = (task.quadrant.isUrgent ? screenX(0) : dividerX) + half
            let hi = (task.quadrant.isUrgent ? dividerX : screenX(1)) - half
            let x = screenX(task.x)
            return (task, lo <= hi ? min(max(x, lo), hi) : (lo + hi) / 2)
        }
        .sorted { ($0.x, $0.task.title) < ($1.x, $1.task.title) }

        // 和左边那个隔不到一个标签宽就归到一组（不跨中线）
        var groups: [[(task: MatrixTask, x: CGFloat)]] = []
        for p in placed {
            if let last = groups.last?.last,
               last.task.quadrant == p.task.quadrant,
               p.x - last.x < chip.width + Self.gap {
                groups[groups.count - 1].append(p)
            } else {
                groups.append([p])
            }
        }

        // 一组几个：这一条够高就上下错开排，否则合成气泡
        let rowHeight = chip.height + Self.gap
        let slots = detail == .dots ? 1 : max(1, Int((bandHeight - 6 + Self.gap) / rowHeight))
        return groups.flatMap { group -> [Node] in
            if group.count == 1 || group.count <= slots {
                return group.enumerated().map { i, p in
                    let y = centerY + (CGFloat(i) - CGFloat(group.count - 1) / 2) * rowHeight
                    return Node(id: .task(p.task.id), kind: .task(p.task), center: CGPoint(x: p.x, y: y), quadrant: p.task.quadrant)
                }
            }
            let members = group.map(\.task)
            let x = group.map(\.x).reduce(0, +) / CGFloat(group.count)
            return [Node(id: .cluster(members[0].id, members.count), kind: .cluster(members),
                         center: CGPoint(x: x, y: centerY), quadrant: members[0].quadrant)]
        }
    }

    /// 只画看得见的（放大 6 倍时大部分在外面）
    var visibleNodes: [Node] {
        let margin = Self.chipSize(detail).width
        return nodes.filter {
            $0.center.x > -margin && $0.center.x < size.width + margin
                && $0.center.y > -margin && $0.center.y < size.height + margin
        }
    }

    /// 把拖动 / 缩放后的位置限制在内容范围内，不露出空白
    static func clamp(_ offset: CGPoint, zoom: CGFloat, size: CGSize) -> CGPoint {
        CGPoint(
            x: min(0, max(size.width * (1 - zoom), offset.x)),
            y: min(0, max(size.height * (1 - zoom), offset.y))
        )
    }
}

// MARK: - 卡片

/// 「今日」页顶部的四象限总览，只看不缩放：页面要上下滚，卡片里放双指缩放会和滚动抢手势（苹果的天气地图、
/// 健身路线图也是这样，列表里只放预览）。点红点跳到下面的卡片；点气泡或空白处打开全屏四象限，在那里缩放
struct QuadrantMatrixCard: View {
    let tasks: [MatrixTask]
    let scale: UrgencyScale
    @Binding var horizonHours: Int
    var onSelect: (PersistentIdentifier) -> Void
    /// 打开全屏。点的是气泡时带上它的位置（0…1 的内容坐标），打开后放大到那里
    var onOpen: (CGPoint?) -> Void

    static let plotHeight: CGFloat = 290

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("四象限").font(.headline)
                Text("点开放大").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { onOpen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("全屏查看")
                Menu {
                    UrgencyHorizonPicker(horizonHours: $horizonHours)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("紧急的界线")
            }
            GeometryReader { geo in
                let size = MatrixPlot.plotSize(in: geo.size)
                MatrixPlot(
                    tasks: tasks, scale: scale, plotSize: size, zoom: 1, offset: .zero,
                    onSelect: onSelect,
                    onExpand: { point in onOpen(CGPoint(x: point.x / size.width, y: point.y / size.height)) }
                )
                // 只有单击，不拦截拖动：从卡片上开始滑也是滚页面
                .contentShape(.rect)
                .onTapGesture { onOpen(nil) }
            }
            .frame(height: Self.plotHeight)
        }
        .glassCard(cornerRadius: 26, padding: 14)
    }
}

/// 「多久以内算紧急」（卡片和全屏页的菜单共用）
private struct UrgencyHorizonPicker: View {
    @Binding var horizonHours: Int

    var body: some View {
        Picker("多久以内算紧急", selection: $horizonHours) {
            ForEach(UrgencyScale.horizonOptions, id: \.hours) { option in
                Text("\(option.label)以内").tag(option.hours)
            }
        }
    }
}

// MARK: - 放大的卡片

/// 点开后的四象限：卡片从原位置放大到屏幕中间（宽度不变，高度占屏幕四分之三），周围是模糊的今日页，
/// 点模糊处收回。外面没有滚动的页面，双指缩放、拖动、双击都不会和别的手势抢
struct QuadrantMatrixOverlay: View {
    let tasks: [MatrixTask]
    let scale: UrgencyScale
    @Binding var horizonHours: Int
    /// 打开后先放大到这一点（0…1 的内容坐标）
    var focus: CGPoint?
    /// 今日页里那张卡片的位置（全局坐标），从这里放大出来、收回到这里
    var sourceFrame: CGRect
    /// 收回动画结束后调用；点了任务时带上它，今日页跳到那张卡片
    var onClose: (PersistentIdentifier?) -> Void

    @State private var expanded = false
    @State private var zoom: CGFloat = 1
    @State private var offset: CGPoint = .zero

    private var isZoomed: Bool { zoom > 1.001 }

    /// 放大后的位置：iPhone 上和原来的卡片一样宽（横轴是时间，变窄了更挤），iPad / Mac 取四分之三宽；高度四分之三
    static func targetFrame(in size: CGSize) -> CGRect {
        let width = min(size.width - 32, max(size.width * 0.75, 420))
        let height = size.height * 0.75
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = geo.frame(in: .global)
            let source = sourceFrame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            let frame = expanded ? Self.targetFrame(in: geo.size) : source
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.06))
                    .opacity(expanded ? 1 : 0)
                    .contentShape(.rect)
                    .onTapGesture { close(nil) }
                    .accessibilityElement()
                    .accessibilityLabel("收起四象限")
                    .accessibilityAddTraits(.isButton)

                card
                    .frame(width: frame.width, height: frame.height)
                    .shadow(color: .black.opacity(expanded ? 0.18 : 0), radius: 30, y: 12)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.smooth(duration: 0.4)) { expanded = true }
        }
        .accessibilityAction(.escape) { close(nil) }
        #if os(macOS)
        .onExitCommand { close(nil) }
        #endif
        // 弹出层是单独一层，也要跟随主题和浅色 / 深色
        .themedTint()
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("四象限").font(.headline)
                Text(isZoomed ? String(format: "%.1fx", zoom) : "双指缩放 · 点外面收起")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                if isZoomed {
                    Button {
                        withAnimation(.smooth(duration: 0.4)) {
                            zoom = 1
                            offset = .zero
                        }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("缩回全图")
                    .transition(.opacity)
                }
                Menu {
                    UrgencyHorizonPicker(horizonHours: $horizonHours)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("紧急的界线")
            }
            .animation(.snappy(duration: 0.2), value: isZoomed)
            ZoomableMatrix(tasks: tasks, scale: scale, zoom: $zoom, offset: $offset, focus: focus, onSelect: { close($0) })
        }
        .glassCard(cornerRadius: 26, padding: 14)
    }

    /// 缩回 1 倍、卡片收回原位，动画结束再真正关掉
    private func close(_ selected: PersistentIdentifier?) {
        guard expanded else { return }
        withAnimation(.smooth(duration: 0.35)) {
            expanded = false
            zoom = 1
            offset = .zero
        } completion: {
            onClose(selected)
        }
    }
}

/// 可以缩放的四象限。缩放和位置由外面持有（表头的「缩回」、收起时复位要用）
private struct ZoomableMatrix: View {
    let tasks: [MatrixTask]
    let scale: UrgencyScale
    @Binding var zoom: CGFloat
    @Binding var offset: CGPoint
    var focus: CGPoint?
    var onSelect: (PersistentIdentifier) -> Void

    @State private var pinchBase: (zoom: CGFloat, offset: CGPoint)?
    @State private var panBase: CGPoint?
    @State private var lastGestureEnd = Date.distantPast
    /// 当前绘图区大小。卡片放大动画进行中尺寸一直在变，放大到气泡时要用动画结束后的
    @State private var plotSize: CGSize = .zero
    // 手势被系统取消时 onEnded 不会调用，GestureState 会自动复位，靠它收尾
    @GestureState private var pinching = false
    @GestureState private var panning = false

    var body: some View {
        GeometryReader { geo in
            let size = MatrixPlot.plotSize(in: geo.size)
            MatrixPlot(
                tasks: tasks, scale: scale, plotSize: size, zoom: zoom, offset: offset,
                onSelect: { id in ifNotGesturing { onSelect(id) } },
                onExpand: { point in ifNotGesturing { zoomIn(at: point, size: size) } }
            )
            .contentShape(.rect)
            .onTapGesture(count: 2) { location in
                let point = CGPoint(x: location.x - MatrixPlot.gutter.width, y: location.y)
                if zoom >= MatrixLayout.maxZoom - 0.01 { reset() } else { zoomIn(at: point, size: size) }
            }
            // 没放大时不拦截拖动，下滑可以关掉全屏
            .gesture(pan(size: size), including: zoom > 1.001 ? .all : .subviews)
            .simultaneousGesture(magnify(size: size))
        }
        .onGeometryChange(for: CGSize.self) { MatrixPlot.plotSize(in: $0.size) } action: { plotSize = $0 }
        .task {
            // 等卡片放大的动画走完再放大到气泡，看得到气泡散开
            guard let focus else { return }
            try? await Task.sleep(for: .milliseconds(420))
            zoomIn(at: CGPoint(x: focus.x * plotSize.width, y: focus.y * plotSize.height), size: plotSize)
        }
        .onChange(of: pinching) { _, active in
            if !active {
                pinchBase = nil
                lastGestureEnd = .now
            }
        }
        .onChange(of: panning) { _, active in
            if !active {
                panBase = nil
                lastGestureEnd = .now
            }
        }
    }

    /// 双指缩放、拖动时手指正好按在任务或气泡上，松手时按钮会以为被点了（会关掉全屏跳走），
    /// 手势进行中和刚结束的一小会儿里不算点击
    private func ifNotGesturing(_ action: () -> Void) {
        guard pinchBase == nil, panBase == nil, Date.now.timeIntervalSince(lastGestureEnd) > 0.35 else { return }
        action()
    }

    private func magnify(size: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .updating($pinching) { _, state, _ in state = true }
            .onChanged { value in
                let base = pinchBase ?? (zoom, offset)
                if pinchBase == nil { pinchBase = base }
                let newZoom = min(max(base.zoom * value.magnification, 1), MatrixLayout.maxZoom)
                // 两指中间那一点保持不动
                let anchor = CGPoint(x: value.startLocation.x - MatrixPlot.gutter.width, y: value.startLocation.y)
                let ratio = newZoom / base.zoom
                let moved = CGPoint(
                    x: anchor.x - (anchor.x - base.offset.x) * ratio,
                    y: anchor.y - (anchor.y - base.offset.y) * ratio
                )
                zoom = newZoom
                offset = MatrixLayout.clamp(moved, zoom: newZoom, size: size)
            }
            .onEnded { _ in
                pinchBase = nil
                lastGestureEnd = .now
            }
    }

    /// 放大后单指拖动
    private func pan(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($panning) { _, state, _ in state = true }
            .onChanged { value in
                // 缩放时不跟着拖；缩放结束后接着拖，以当前位置为起点，不会跳
                guard pinchBase == nil else {
                    panBase = nil
                    return
                }
                let base = panBase ?? CGPoint(x: offset.x - value.translation.width, y: offset.y - value.translation.height)
                if panBase == nil { panBase = base }
                offset = MatrixLayout.clamp(
                    CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height),
                    zoom: zoom, size: size
                )
            }
            .onEnded { _ in
                panBase = nil
                lastGestureEnd = .now
            }
    }

    /// 双击或点气泡：放大一倍，把点的地方移到中间
    private func zoomIn(at point: CGPoint, size: CGSize) {
        let target = min(MatrixLayout.maxZoom, max(zoom * 2, 1.6))
        let content = CGPoint(x: (point.x - offset.x) / zoom, y: (point.y - offset.y) / zoom)
        let moved = CGPoint(x: size.width / 2 - content.x * target, y: size.height / 2 - content.y * target)
        withAnimation(.smooth(duration: 0.45)) {
            zoom = target
            offset = MatrixLayout.clamp(moved, zoom: target, size: size)
        }
    }

    private func reset() {
        withAnimation(.smooth(duration: 0.4)) {
            zoom = 1
            offset = .zero
        }
    }
}

// MARK: - 绘图

/// 坐标轴 + 象限 + 任务。实现 Animatable：双击 / 点气泡 / 缩回时，缩放和位置逐帧插值，
/// 每一帧都重新排布，气泡在动画过程中就会一个个散开，和双指缩放看到的一样
private struct MatrixPlot: View, @preconcurrency Animatable {
    let tasks: [MatrixTask]
    let scale: UrgencyScale
    let plotSize: CGSize
    var zoom: CGFloat
    var offset: CGPoint
    var onSelect: (PersistentIdentifier) -> Void
    /// 点了气泡：在这一点放大
    var onExpand: (CGPoint) -> Void

    /// 左边是重要程度，下面是时间
    static let gutter = CGSize(width: 20, height: 18)

    /// 去掉坐标轴后绘图区的大小
    static func plotSize(in size: CGSize) -> CGSize {
        CGSize(width: max(size.width - gutter.width, 1), height: max(size.height - gutter.height, 1))
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(zoom, AnimatablePair(offset.x, offset.y)) }
        set {
            zoom = newValue.first
            offset = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    var body: some View {
        let layout = MatrixLayout(tasks: tasks, size: plotSize, zoom: zoom, offset: offset)
        let ticks = visibleTicks(layout)
        ZStack(alignment: .topLeading) {
            importanceAxis(layout)
                .frame(width: Self.gutter.width, height: plotSize.height)
                .clipped()

            plot(layout, ticks: ticks)
                .frame(width: plotSize.width, height: plotSize.height, alignment: .topLeading)
                .clipShape(.rect(cornerRadius: 14))
                .offset(x: Self.gutter.width)

            timeAxis(layout, ticks: ticks)
                .frame(width: plotSize.width, height: Self.gutter.height)
                .clipped()
                .offset(x: Self.gutter.width, y: plotSize.height)
        }
        .frame(width: plotSize.width + Self.gutter.width, height: plotSize.height + Self.gutter.height, alignment: .topLeading)
    }

    private func plot(_ layout: MatrixLayout, ticks: [(tick: UrgencyScale.Tick, x: CGFloat)]) -> some View {
        // 每个子视图都不能比绘图区大：ZStack 会变大，再被外面的 frame 居中，整张图就偏了
        ZStack(alignment: .topLeading) {
            grid(layout, ticks: ticks)

            ForEach(Quadrant.allCases) { quadrant in
                quadrantLabel(quadrant, layout: layout)
            }

            ForEach(layout.visibleNodes) { node in
                nodeView(node, detail: layout.detail)
                    .position(node.center)
                    .transition(.scale(scale: 0.5).combined(with: .opacity).animation(.snappy(duration: 0.25)))
            }
        }
    }

    private func grid(_ layout: MatrixLayout, ticks: [(tick: UrgencyScale.Tick, x: CGFloat)]) -> some View {
        Canvas { context, size in
            for quadrant in Quadrant.allCases {
                context.fill(Path(layout.rect(of: quadrant)), with: .color(quadrant.tint.opacity(0.07)))
            }
            func line(_ from: CGPoint, _ to: CGPoint, _ color: Color, dash: [CGFloat] = []) {
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
            }
            for (tick, x) in ticks where !tick.isDivider {
                line(CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height), .secondary.opacity(0.12), dash: [2, 4])
            }
            for band in 1..<MatrixLayout.bands where band != MatrixLayout.bands / 2 {
                let y = layout.screenY(Double(band) / Double(MatrixLayout.bands))
                line(CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y), .secondary.opacity(0.12), dash: [2, 4])
            }
            let midX = layout.screenX(UrgencyScale.divider)
            let midY = layout.screenY(0.5)
            line(CGPoint(x: midX, y: 0), CGPoint(x: midX, y: size.height), .secondary.opacity(0.45))
            line(CGPoint(x: 0, y: midY), CGPoint(x: size.width, y: midY), .secondary.opacity(0.45))
        }
        .allowsHitTesting(false)
    }

    /// 象限名字 + 数量，贴在这个象限看得见部分的外角上：放大后也一直看得到自己在哪个象限
    @ViewBuilder
    private func quadrantLabel(_ quadrant: Quadrant, layout: MatrixLayout) -> some View {
        let visible = layout.rect(of: quadrant).intersection(CGRect(origin: .zero, size: plotSize))
        if !visible.isNull, visible.width > 80, visible.height > 26 {
            let count = tasks.filter { $0.quadrant == quadrant }.count
            let alignment: Alignment = switch quadrant {
            case .doNow: .topLeading
            case .plan: .topTrailing
            case .quick: .bottomLeading
            case .later: .bottomTrailing
            }
            Color.clear
                .frame(width: visible.width, height: visible.height)
                .overlay(alignment: alignment) {
                    HStack(spacing: 4) {
                        Text(quadrant.displayName).font(.caption.weight(.semibold))
                        Text("\(count)").font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(quadrant.tint.opacity(count > 0 ? 0.9 : 0.45))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                .offset(x: visible.minX, y: visible.minY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func nodeView(_ node: MatrixLayout.Node, detail: MatrixLayout.Detail) -> some View {
        switch node.kind {
        case let .task(task):
            Button { onSelect(task.id) } label: {
                MatrixChip(task: task, detail: detail)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(task.title)，\(task.quadrant.displayName)")
            .accessibilityHint("跳到这条任务")
        case let .cluster(members):
            Button { onExpand(node.center) } label: {
                ClusterBubble(count: members.count, tint: node.quadrant.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(members.count) 个任务：\(members.map(\.title).joined(separator: "、"))")
            .accessibilityHint("放大查看")
        }
    }

    // MARK: 坐标轴

    private func importanceAxis(_ layout: MatrixLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Importance.allCases, id: \.self) { importance in
                Text(importance.displayName.map(String.init).joined(separator: "\n"))
                    .font(.system(size: 10, weight: importance.isImportant ? .semibold : .regular))
                    .foregroundStyle(importance.isImportant ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(-2)
                    .fixedSize()
                    .position(x: Self.gutter.width / 2 - 2, y: layout.bandCenterY(MatrixLayout.band(of: importance)))
            }
        }
        .accessibilityHidden(true)
    }

    private func timeAxis(_ layout: MatrixLayout, ticks: [(tick: UrgencyScale.Tick, x: CGFloat)]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.tick.id) { tick, x in
                Text(tick.label)
                    .font(.system(size: 10, weight: tick.isDivider ? .semibold : .regular))
                    .foregroundStyle(tick.isDivider ? .primary : .secondary)
                    .fixedSize()
                    .position(x: x, y: Self.gutter.height / 2 + 1)
            }
        }
        .accessibilityHidden(true)
    }

    /// 重要的刻度先放，和已经放好的挤在一起就不放；放大后间距变大，刻度越来越密
    private func visibleTicks(_ layout: MatrixLayout) -> [(tick: UrgencyScale.Tick, x: CGFloat)] {
        func width(_ label: String) -> CGFloat {
            label.reduce(4) { $0 + ($1.isASCII ? 6 : 10) }
        }
        var shown: [(tick: UrgencyScale.Tick, x: CGFloat)] = []
        for tick in scale.ticks.sorted(by: { ($0.priority, $0.x) < ($1.priority, $1.x) }) {
            let w = width(tick.label)
            // 两头的标签往里收一点，不被裁掉
            let x = min(max(layout.screenX(tick.x), w / 2), plotSize.width - w / 2)
            let raw = layout.screenX(tick.x)
            guard raw > -w, raw < plotSize.width + w else { continue }
            if shown.allSatisfy({ abs($0.x - x) >= (width($0.tick.label) + w) / 2 + 6 }) {
                shown.append((tick, x))
            }
        }
        return shown
    }
}

// MARK: - 点 / 标签 / 气泡

private struct MatrixChip: View {
    let task: MatrixTask
    let detail: MatrixLayout.Detail

    var body: some View {
        let tint = task.quadrant.tint
        Group {
            if detail == .dots {
                Circle()
                    .fill(tint)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    .shadow(color: tint.opacity(0.4), radius: 3)
                    // 点很小，点击范围放大一些
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            } else {
                CappedWidth(maxWidth: MatrixLayout.chipSize(detail).width) {
                    HStack(spacing: 5) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                            if detail == .full {
                                Text(task.due.map { Countdown.string(to: $0) } ?? "无期限")
                                    .font(.system(size: 9))
                                    .foregroundStyle(task.quadrant.isUrgent ? tint : .secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: .rect(cornerRadius: detail == .full ? 10 : 12))
                    .overlay(RoundedRectangle(cornerRadius: detail == .full ? 10 : 12).stroke(tint.opacity(0.45), lineWidth: 1))
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: detail)
    }
}

private struct ClusterBubble: View {
    let count: Int
    let tint: Color

    var body: some View {
        let side = 22 + CGFloat(min(count, 8)) * 2
        Text("\(count)")
            .font(.system(size: count > 9 ? 11 : 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(tint.gradient, in: .circle)
            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))
            .shadow(color: tint.opacity(0.35), radius: 4, y: 1)
            .frame(width: max(side, 30), height: max(side, 30))
            .contentShape(.circle)
    }
}

/// 宽度跟着内容走，但不超过 maxWidth（超出的标题由 Text 自己截断加省略号）
private struct CappedWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(child.sizeThatFits(.unspecified).width, maxWidth)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
