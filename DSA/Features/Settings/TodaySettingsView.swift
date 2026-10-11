import EventKit
import SwiftData
import SwiftUI

/// 今日的设置：日历和提醒事项、订阅日历、邮件特别关注、立即同步。
/// 日历是这台设备上的设置；特别关注的规则存在 Worker 上，没连 Worker 时那一节点不了，其他照常
struct TodaySettingsView: View {
    let sync: TaskSyncService

    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.useCalendar) private var useCalendar = false
    @AppStorage(SettingsKey.useReminders) private var useReminders = false
    @AppStorage(SettingsKey.gmailExtraQuery) private var gmailExtraQuery = ""
    @AppStorage(SettingsKey.lastSyncAt) private var lastSyncAt: Double = 0
    @State private var icalFeeds = AppSettings.icalFeeds
    @State private var addingFeed = false
    @State private var store = ConfigStore.shared
    @State private var calendarStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            calendarSection
            watchSection
            syncSection
        }
        .formStyle(.grouped)
        .navigationTitle("今日")
        .configEditing()
        // 打开开关后同步时会弹出权限请求，同步完再看一次授权状态
        .onChange(of: sync.isSyncing) { _, syncing in if !syncing { refreshPermissions() } }
        .onAppear(perform: refreshPermissions)
        .sheet(isPresented: $addingFeed) {
            AddICalFeedSheet { feed in
                icalFeeds.append(feed)
                feedsChanged()
            }
        }
    }

    // MARK: - 日历

    private var calendarSection: some View {
        Section {
            Toggle(isOn: $useCalendar) {
                Label("苹果日历", systemImage: "calendar")
            }
            Toggle(isOn: $useReminders) {
                Label("提醒事项", systemImage: "checklist")
            }
            if let denied = deniedPermission {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(denied)没有权限，开着也读不到", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    #if os(iOS)
                    Button("去系统设置打开") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                    #endif
                }
            }
            ForEach(icalFeeds) { feed in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.name.isEmpty ? "订阅日历" : feed.name)
                        Text(feed.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } icon: {
                    Image(systemName: TaskSource.ical.systemImage)
                }
            }
            .onDelete { offsets in
                icalFeeds.remove(atOffsets: offsets)
                feedsChanged()
            }
            Button {
                addingFeed = true
            } label: {
                Label("添加订阅日历", systemImage: "plus")
            }
        } header: {
            Text("日历")
        } footer: {
            Text("关掉后，它带进今日的任务会一起移除。")
        }
        .onChange(of: useCalendar) { _, on in sourceToggled(.calendar, on: on) }
        .onChange(of: useReminders) { _, on in sourceToggled(.reminders, on: on) }
    }

    // MARK: - 邮件特别关注

    private var watchSection: some View {
        Section {
            if store.saved != nil {
                ForEach(store.draft.watchRules.indices, id: \.self) { index in
                    TextField("例如：X 公司的招聘邮件都提醒我", text: $store.draft.watchRules[index], axis: .vertical)
                        .lineLimit(1...6)
                }
                .onDelete { store.draft.watchRules.remove(atOffsets: $0) }
                if store.draft.watchRules.count < UserConfig.maxWatchRules {
                    Button {
                        store.draft.watchRules.append("")
                    } label: {
                        Label("添加规则", systemImage: "plus")
                    }
                }
            } else if store.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                Text("规则存在 Worker 上，需要先连接 Worker。")
                    .foregroundStyle(.secondary)
            }
            TextField("Gmail 搜索，例如 company (interview OR offer)", text: $gmailExtraQuery, axis: .vertical)
                .urlInput()
        } header: {
            Text("邮件特别关注")
        } footer: {
            Text("命中规则的邮件即使不用处理也会出现在今日；Gmail 搜索让这类邮件分到「推广」也会被读到。")
        }
    }

    // MARK: - 同步

    private var syncSection: some View {
        Section {
            Button {
                Task { await sync.sync(context: context) }
            } label: {
                HStack {
                    Text("立即同步")
                    Spacer()
                    if sync.isSyncing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(sync.isSyncing)
        } footer: {
            if lastSyncAt > 0 {
                Text("上次同步：\(Date(timeIntervalSince1970: lastSyncAt).formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN"))))")
            }
        }
    }

    /// 开关开着但被拒绝了权限的那一项
    private var deniedPermission: String? {
        let denied: (EKAuthorizationStatus) -> Bool = { $0 == .denied || $0 == .restricted || $0 == .writeOnly }
        if useCalendar && denied(calendarStatus) { return "日历" }
        if useReminders && denied(remindersStatus) { return "提醒事项" }
        return nil
    }

    private func refreshPermissions() {
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        remindersStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    /// 订阅日历改了：存下来、马上同步（删光了就移除它带进来的任务）
    private func feedsChanged() {
        AppSettings.icalFeeds = icalFeeds
        if icalFeeds.isEmpty {
            withAnimation { TaskSyncService.removeTasks(from: [.ical], in: context) }
        } else {
            Task { await sync.sync(context: context) }
        }
    }

    /// 关掉：马上移除这个数据源的任务；打开：马上同步一次，任务（和权限弹窗）立刻出来
    private func sourceToggled(_ source: TaskSource, on: Bool) {
        if on {
            Task { await sync.sync(context: context) }
        } else {
            withAnimation { TaskSyncService.removeTasks(from: [source], in: context) }
        }
    }
}

/// 添加一个订阅日历：名字 + iCal 链接
private struct AddICalFeedSheet: View {
    let onAdd: (ICalFeed) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""

    private var feed: ICalFeed { ICalFeed(name: name.trimmingCharacters(in: .whitespaces), url: url.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字，例如 Moodle、课表", text: $name)
                    TextField("https:// 或 webcal:// 开头的链接", text: $url, axis: .vertical)
                        .urlInput()
                }
                Section {
                    NavigationLink("各平台怎么拿链接") { SetupStepView(step: .icalFeeds, showsSettingsLink: false) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加订阅日历")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(feed)
                        dismiss()
                    }
                    .disabled(feed.downloadURL?.scheme?.hasPrefix("http") != true)
                }
            }
        }
        .macSheetFrame(minWidth: 420, minHeight: 360)
        .themedTint()
    }
}
