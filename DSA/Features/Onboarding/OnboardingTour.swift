import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 第一次打开时的新手引导：欢迎页 → 指着底部的「设置」→ 高亮「用前配置」→ 高亮「一步一步配置」，
/// 点开后由 `SetupWizardView` 一页一步带着做完必需的配置。
/// 只弹一次；跳过或打开一步一步配置后就不再弹，可以在 设置 → 用前配置 底部重新看
@MainActor
@Observable
final class OnboardingTour {
    static let shared = OnboardingTour()

    enum Step: Int {
        case welcome, openSettings, openGuide, startWizard
    }

    /// 要高亮的地方，由 `.tourTarget(_:)` 报告位置
    enum Target: Hashable {
        case setupRow, wizardButton
    }

    private(set) var step: Step?
    /// 窗口坐标（.global）
    private(set) var frames: [Target: CGRect] = [:]
    /// 现在在屏幕上的（切走的标签页、被推到后面的页面不算）
    private(set) var visible: Set<Target> = []

    private static let seenKey = "onboarding.seen"

    private init() {}

    /// 第一次打开时开始。更新前就填过 Worker 的老用户不弹
    func startIfNeeded() {
        let defaults = UserDefaults.standard
        guard step == nil, !defaults.bool(forKey: Self.seenKey) else { return }
        if AppSettings.workerURL != nil {
            defaults.set(true, forKey: Self.seenKey)
            return
        }
        step = .welcome
    }

    /// 从 设置 → 用前配置 重新看一遍
    func restart() {
        AppRouter.shared.tab = .tasks
        step = .welcome
    }

    /// 欢迎页上点了「开始配置」
    func begin() {
        step = AppRouter.shared.tab == .settings ? .openGuide : .openSettings
    }

    func tabChanged(to tab: AppRouter.AppTab) {
        if step == .openSettings, tab == .settings { step = .openGuide }
    }

    /// 「用前配置」出现了（点了高亮的那一行，或者从「今日」的提醒卡片过来）
    func guideAppeared() {
        if step == .openSettings || step == .openGuide { step = .startWizard }
    }

    /// 跳过，或者已经打开一步一步配置：以后不再自动弹出
    func finish() {
        step = nil
        UserDefaults.standard.set(true, forKey: Self.seenKey)
    }

    fileprivate func report(_ frame: CGRect, for target: Target) {
        if frames[target] != frame { frames[target] = frame }
    }

    fileprivate func setVisible(_ isVisible: Bool, _ target: Target) {
        if isVisible { visible.insert(target) } else { visible.remove(target) }
    }

    /// 这一步要高亮的地方；不在屏幕上时为 nil
    func frame(of target: Target) -> CGRect? {
        guard visible.contains(target), let frame = frames[target], !frame.isEmpty else { return nil }
        return frame
    }
}

extension View {
    /// 新手引导要高亮的地方：报告它在窗口里的位置
    func tourTarget(_ target: OnboardingTour.Target) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            OnboardingTour.shared.report($0, for: target)
        }
        .onAppear { OnboardingTour.shared.setVisible(true, target) }
        .onDisappear { OnboardingTour.shared.setVisible(false, target) }
    }
}

// MARK: - 盖在整个 app 上的一层

/// 放在 TabView 上面，盖住底部标签栏。高亮的地方挖空，只有那里能点；其他地方变暗、点不到
struct TourOverlay: View {
    @State private var tour = OnboardingTour.shared
    @State private var settingsTab: CGRect?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if let step = tour.step {
            GeometryReader { proxy in
                // 高亮位置是窗口坐标，换算成这一层自己的坐标
                let origin = proxy.frame(in: .global).origin
                if step == .welcome {
                    WelcomeCard(onStart: { withAnimation(.snappy) { tour.begin() } }, onSkip: skip)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.25))
                        .background(.ultraThinMaterial)
                } else {
                    spotlight(step, hole: hole(for: step)?.offsetBy(dx: -origin.x, dy: -origin.y), size: proxy.size)
                }
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in locateSettingsTab() }
            .task(id: step) { locateSettingsTab() }
        }
    }

    private func hole(for step: OnboardingTour.Step) -> CGRect? {
        switch step {
        case .welcome: nil
        case .openSettings: settingsTab
        // 行里的内容往外扩一圈，盖住整行（图标左边的空白、右边的箭头）
        case .openGuide: tour.frame(of: .setupRow).map { CGRect(x: $0.minX - 14, y: $0.minY - 12, width: $0.width + 31, height: $0.height + 24) }
        case .startWizard: tour.frame(of: .wizardButton)?.insetBy(dx: -6, dy: -6)
        }
    }

    @ViewBuilder
    private func spotlight(_ step: OnboardingTour.Step, hole: CGRect?, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let hole {
                let shape = SpotlightShape(hole: hole, cornerRadius: min(hole.height / 2, 26))
                shape
                    .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                    // 挖空的地方点得到下面的按钮，其他地方挡住
                    .contentShape(shape, eoFill: true)
                    .animation(.snappy, value: hole)
                PulseRing(hole: hole, cornerRadius: shape.cornerRadius)
            }
            calloutLayer(step, hole: hole, size: size)
        }
    }

    /// 说明气泡：高亮的地方在上半屏就放在它下面，否则放在上面；找不到高亮的地方时放在屏幕中间
    @ViewBuilder
    private func calloutLayer(_ step: OnboardingTour.Step, hole: CGRect?, size: CGSize) -> some View {
        let callout = TourCallout(step: step, canOpenSettings: step == .openSettings && hole == nil, onSkip: skip)
            .frame(maxWidth: 360)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
        VStack(spacing: 0) {
            if let hole {
                if hole.midY < size.height * 0.55 {
                    Color.clear.frame(height: hole.maxY + 14)
                    callout
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    callout
                    Color.clear.frame(height: size.height - hole.minY + 14)
                }
            } else {
                Spacer()
                callout
                Spacer()
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.snappy, value: hole)
    }

    private func skip() {
        withAnimation(.snappy) { tour.finish() }
    }

    private func locateSettingsTab() {
        #if os(iOS)
        settingsTab = sizeClass == .compact ? TabBarLocator.settingsTab() : nil
        #endif
    }
}

/// 整个屏幕挖掉一个圆角矩形
private struct SpotlightShape: Shape {
    var hole: CGRect
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(hole.minX, hole.minY), .init(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -200, dy: -200))
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        return path
    }
}

/// 高亮边上一圈慢慢向外扩散的光圈
private struct PulseRing: View {
    let hole: CGRect
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(.white, lineWidth: 2)
            .frame(width: hole.width, height: hole.height)
            .phaseAnimator([false, true]) { ring, expanded in
                ring
                    .scaleEffect(expanded ? 1.08 : 1)
                    .opacity(expanded ? 0 : 0.9)
            } animation: { expanded in
                expanded ? .easeOut(duration: 1.2) : .linear(duration: 0.01)
            }
            .offset(x: hole.minX, y: hole.minY)
            .allowsHitTesting(false)
    }
}

// MARK: - 欢迎页

private struct WelcomeCard: View {
    let onStart: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text("欢迎使用 DSA").font(.title.bold())
                Text("要做的事、记账和新闻放在一起，由你自己的 AI 帮你整理。")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                feature("checklist", "今日", "日历、提醒事项、邮件里要处理的事，自动整理成一张清单")
                feature("creditcard", "记账", "Apple Pay、小票、邮件收据自动记账")
                feature("newspaper", "新闻", "每天早上按你的兴趣写一份简报")
            }

            Text("开始前要做 4 步基本配置：部署 Worker、连接、添加 AI 的 key、填个人资料。我带你一步一步来，其中部署要在 Mac 上做。")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button(action: onStart) {
                    Text("开始配置").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button("先随便看看", action: onSkip)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
            }
            Text("以后可以在 设置 → 用前配置 里继续。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .padding(20)
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 说明气泡

private struct TourCallout: View {
    let step: OnboardingTour.Step
    /// 找不到底部标签栏（iPad、Mac）时，直接给一个按钮
    let canOpenSettings: Bool
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("第 \(step.rawValue) 步，共 3 步")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("跳过引导", action: onSkip)
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            Text(title).font(.headline)
            Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if canOpenSettings {
                Button("打开设置") { AppRouter.shared.tab = .settings }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var title: String {
        switch step {
        case .welcome, .openSettings: "打开「设置」"
        case .openGuide: "点「用前配置」"
        case .startWizard: "跟着引导一步一步来"
        }
    }

    private var message: String {
        switch step {
        case .welcome, .openSettings:
            canOpenSettings ? "所有配置都在「设置」里。" : "所有配置都在右下角的「设置」里，点一下它。"
        case .openGuide:
            "这里列出了要做的每一步，每步都有教程，做完会打勾。"
        case .startWizard:
            "先把 4 个必需的步骤做完：部署 Worker、连接、添加 AI 的 key、填个人资料。"
        }
    }
}

// MARK: - 底部标签栏里「设置」的位置

#if os(iOS)
@MainActor
enum TabBarLocator {
    /// 在窗口里找标签栏上叫「设置」的按钮；找不到就按 iOS 26 悬浮标签栏的样子估算（四个标签平分，左右各留 31pt）
    static func settingsTab() -> CGRect? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return nil }

        if let tabBar = first(UITabBar.self, in: window), !tabBar.isHidden, tabBar.alpha > 0,
           let item = element(labeled: "设置", in: tabBar) {
            let frame = item.convert(item.bounds, to: window)
            if frame.width > 20, frame.height > 20 { return frame }
        }

        let size = window.bounds.size
        guard size.height > size.width else { return nil }
        let itemWidth = (size.width - 62) / 4
        let center = CGPoint(x: size.width - 31 - itemWidth / 2, y: size.height - window.safeAreaInsets.bottom - 18)
        return CGRect(x: center.x - itemWidth / 2, y: center.y - 27, width: itemWidth, height: 54)
    }

    private static func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = first(type, in: subview) { return match }
        }
        return nil
    }

    private static func element(labeled label: String, in view: UIView) -> UIView? {
        if view.accessibilityLabel == label, !view.isHidden { return view }
        for subview in view.subviews {
            if let match = element(labeled: label, in: subview) { return match }
        }
        return nil
    }
}
#endif
