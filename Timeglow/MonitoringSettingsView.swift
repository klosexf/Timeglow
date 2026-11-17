import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import UniformTypeIdentifiers

private struct ReminderNodeDraft: Identifiable, Equatable {
    let id = UUID()
    var value: String
}

// Approved concept A: a category sidebar and one focused column of settings.
private enum SettingsStyle {
    static let sectionGap: CGFloat = 20
    static let fieldHeight: CGFloat = 36
    static let radius: CGFloat = 8
    static let title = Font.system(size: 26, weight: .semibold)
    static let sectionTitle = Font.system(size: 12, weight: .semibold)
    static let fieldLabel = Font.system(size: 12, weight: .medium)
    static let body = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let metadata = Font.system(size: 11)
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case reminders, scope, permissions, startup
    var id: Self { self }
    var title: String {
        switch self {
        case .reminders: return "用时与提醒"
        case .scope: return "统计范围"
        case .permissions: return "权限与计时"
        case .startup: return "启动与数据"
        }
    }
    var icon: String {
        switch self {
        case .reminders: return "bell"
        case .scope: return "square.grid.2x2"
        case .permissions: return "slider.horizontal.3"
        case .startup: return "internaldrive"
        }
    }
    var pageTitle: String { self == .reminders ? "提醒设置" : title }
}

private struct SettingsGroup: ViewModifier {
    var horizontal: CGFloat = 18
    var vertical: CGFloat = 16
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, horizontal).padding(.vertical, vertical)
            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Graphite.line, lineWidth: 1))
    }
}

private struct SettingsOutline: ViewModifier {
    var filled = true
    func body(content: Content) -> some View {
        content
            .background(filled ? Color.black.opacity(0.14) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: SettingsStyle.radius))
            .overlay(RoundedRectangle(cornerRadius: SettingsStyle.radius).strokeBorder(Graphite.line, lineWidth: 1))
    }
}

private struct SettingsButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: primary ? 12 : 11, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Color(red: 0.12, green: 0.13, blue: 0.16) : Graphite.muted)
            .padding(.horizontal, primary ? 20 : 11).padding(.vertical, primary ? 11 : 8)
            .background(primary ? Graphite.accent : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? .clear : Graphite.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct MonitoringSettingsView: View {
    let monitor: MonitoringController
    @ObservedObject var permissions: PermissionServices
    @State private var website = ""
    @State private var websiteError: String?
    @State private var percentNodes: [ReminderNodeDraft] = []
    @State private var minuteNodes: [ReminderNodeDraft] = []
    @State private var message = ""
    @State private var draftError: String?
    @State private var draftSaved = false
    @State private var applicationsExpanded = true
    @State private var previewNode = ""
    @State private var previewFeedback: String?
    @State private var category: SettingsCategory = .reminders
    @State private var stateRangesExpanded = false
    @State private var previewExpanded = false

    private var isPercent: Bool { monitor.preferences.reminderKind == "percent" }
    private var activeNodes: [ReminderNodeDraft] { isPercent ? percentNodes : minuteNodes }
    private var activeNodeBinding: Binding<[ReminderNodeDraft]> { isPercent ? $percentNodes : $minuteNodes }
    private var previewValue: String { activeNodes.contains(where: { $0.value == previewNode }) ? previewNode : activeNodes.first?.value ?? "—" }
    private var previewTitle: String { isPercent ? "今天合计已用每日限额的 \(previewValue)%" : "今天合计已用 \(previewValue) 分钟" }
    private var selectedAppNames: String {
        let known = Dictionary(uniqueKeysWithValues: monitor.availableApplications.map { ($0.bundleID, $0.name) })
        let names = monitor.preferences.selectedApps.map { known[$0] ?? $0 }.sorted()
        return names.isEmpty ? "选择要合计用时的应用" : names.joined(separator: "、")
    }

    private func binding<T>(_ keyPath: WritableKeyPath<MonitoringPreferences, T>) -> Binding<T> {
        Binding(get: { monitor.preferences[keyPath: keyPath] }, set: { value in
            var preferences = monitor.preferences
            preferences[keyPath: keyPath] = value
            monitor.updatePreferences(preferences)
        })
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 950
            HStack(spacing: 0) {
                settingsSidebar.frame(width: compact ? 168 : 194)
                Rectangle().fill(Graphite.line.opacity(0.6)).frame(width: 1)
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: SettingsStyle.sectionGap) {
                            settingsHeading
                            categoryContent(compact: compact)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, compact ? 28 : 40).padding(.top, compact ? 26 : 28).padding(.bottom, 26)
                    }.scrollIndicators(.automatic).id(category)
                    if category == .reminders {
                        saveFooter.padding(.horizontal, compact ? 28 : 40).padding(.vertical, 12)
                            .frame(minHeight: 66)
                            .background(Color(red: 0.188, green: 0.196, blue: 0.212).opacity(0.94))
                            .overlay(alignment: .top) { Rectangle().fill(Graphite.line).frame(height: 1) }
                    }
                }
            }
        }
        .font(SettingsStyle.body).tint(Graphite.accent)
        .buttonStyle(SettingsButtonStyle())
        .onAppear {
            percentNodes = monitor.preferences.percentThresholds.map { .init(value: String($0)) }
            minuteNodes = monitor.preferences.minuteThresholds.map { .init(value: String($0)) }
            message = monitor.preferences.message
            Task { await permissions.refresh() }
        }
        .onChange(of: percentNodes) { _, _ in draftSaved = false }
        .onChange(of: minuteNodes) { _, _ in draftSaved = false }
        .onChange(of: message) { _, _ in draftSaved = false }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 5) {
                ForEach(SettingsCategory.allCases) { item in
                    Button {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        category = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).font(.system(size: 13)).frame(width: 17)
                                .foregroundStyle(category == item ? Graphite.accent : Graphite.muted)
                            Text(item.title).font(.system(size: 12, weight: category == item ? .medium : .regular))
                            Spacer(minLength: 0)
                        }.foregroundStyle(category == item ? Graphite.ink : Graphite.muted)
                            .padding(.horizontal, 12).frame(height: 37)
                            .background(category == item ? .white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(category == item ? .isSelected : [])
                }
            }
            Spacer(minLength: 30)
        }.padding(.horizontal, 14).padding(.top, 30).padding(.bottom, 25)
            .frame(maxHeight: .infinity, alignment: .topLeading).background(.black.opacity(0.12))
    }

    private var settingsHeading: some View {
        HStack(alignment: .center, spacing: 20) {
            Text(category.pageTitle).font(SettingsStyle.title).foregroundStyle(Graphite.ink)
            Spacer(minLength: 0)
            if category == .reminders {
                HStack(spacing: 12) {
                    Text("用时提醒").font(SettingsStyle.caption).foregroundStyle(Graphite.muted)
                    Toggle("开启用时提醒", isOn: binding(\.notificationsEnabled)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }.frame(minHeight: 36)
    }

    @ViewBuilder private func categoryContent(compact: Bool) -> some View {
        switch category {
        case .reminders: reminderPage
        case .scope: scopeSettings(compact: compact)
        case .permissions: permissionsSettings
        case .startup: startupSettings
        }
    }

    private var reminderPage: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.sectionGap) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("每日限额").font(SettingsStyle.fieldLabel)
                        hint("所选应用与网站合计")
                    }
                    Spacer(minLength: 0)
                    quotaControl
                }
                stateRangeSettings
            }.modifier(SettingsGroup())
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Text("提醒时机").font(SettingsStyle.sectionTitle)
                    Spacer(minLength: 0)
                    reminderModePicker
                }
                reminderSettings.modifier(SettingsGroup(horizontal: 14, vertical: 12))
            }
            messageSettings
            VStack(alignment: .leading, spacing: 14) {
                Divider().overlay(Graphite.line)
                DisclosureGroup(isExpanded: $previewExpanded) {
                    notificationPreview.frame(maxWidth: 480).frame(maxWidth: .infinity).padding(.top, 15)
                } label: {
                    Label("通知预览", systemImage: "bell").font(SettingsStyle.caption).foregroundStyle(Graphite.muted)
                }
            }
        }
    }

    private var quotaControl: some View {
        HStack(spacing: 10) {
            Button { changeQuota(by: -15) } label: {
                Image(systemName: "minus").font(.system(size: 10)).frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Graphite.line, lineWidth: 1))
                    .contentShape(Circle())
            }.accessibilityLabel("每日限额减少 15 分钟")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("每日合计用时限额", value: Binding(get: { monitor.preferences.quotaMinutes }, set: { value in
                    binding(\.quotaMinutes).wrappedValue = min(1440, max(1, value))
                }), format: .number.grouping(.never))
                    .textFieldStyle(.plain).font(.system(size: 29, weight: .regular)).monospacedDigit()
                    .multilineTextAlignment(.trailing).frame(width: 72).accessibilityLabel("每日合计用时限额")
                Text("分钟 / 天").font(SettingsStyle.metadata).foregroundStyle(Graphite.muted).fixedSize()
            }
            Button { changeQuota(by: 15) } label: {
                Image(systemName: "plus").font(.system(size: 10)).frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Graphite.line, lineWidth: 1))
                    .contentShape(Circle())
            }.accessibilityLabel("每日限额增加 15 分钟")
        }.buttonStyle(.plain).foregroundStyle(Graphite.ink).fixedSize()
    }

    private func changeQuota(by amount: Int) {
        binding(\.quotaMinutes).wrappedValue = min(1440, max(1, monitor.preferences.quotaMinutes + amount))
    }

    private var saveFooter: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if let draftError {
                    Text(draftError).font(SettingsStyle.caption).foregroundStyle(Graphite.warning).fixedSize(horizontal: false, vertical: true)
                } else if draftSaved {
                    Label("已保存", systemImage: "checkmark")
                        .font(SettingsStyle.metadata).foregroundStyle(Graphite.safe)
                } else {
                    Text("节点和文案修改后需要保存").font(SettingsStyle.caption).foregroundStyle(Graphite.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: saveReminderDraft) {
                HStack(spacing: 8) { Text("保存设置"); Image(systemName: "checkmark").font(.system(size: 10)) }
            }.buttonStyle(SettingsButtonStyle(primary: true))
        }
    }


    private func scopeSettings(compact: Bool) -> some View {
        let applications = monitor.availableApplications.filter { BrowserReader.supported[$0.bundleID] == nil }
        let browsers = monitor.availableApplications.filter { BrowserReader.supported[$0.bundleID] != nil }
        return VStack(alignment: .leading, spacing: SettingsStyle.sectionGap) {
            VStack(alignment: .leading, spacing: 5) {
                fieldHeading("计入每日限额", detail: "\(monitor.preferences.selectedApps.count) 个应用 · \(monitor.preferences.websites.filter(\.enabled).count) 个网站")
                hint("选中项目共用每日限额；取消勾选仍会记录用时。")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button { applicationsExpanded.toggle() } label: {
                        HStack(spacing: 7) {
                            Text("应用").foregroundStyle(Graphite.ink).font(SettingsStyle.fieldLabel)
                            Image(systemName: applicationsExpanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("选择计入每日限额的应用").accessibilityValue(applicationsExpanded ? "已展开" : "已收起")
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        Button("添加应用…", action: addApplications)
                        Button("全选") { var value = monitor.preferences; value.selectedApps.formUnion(monitor.availableApplications.map(\.bundleID)); monitor.updatePreferences(value) }
                        Button("清空") { var value = monitor.preferences; value.selectedApps = []; monitor.updatePreferences(value) }
                    }.buttonStyle(.plain).font(SettingsStyle.caption).foregroundStyle(Graphite.muted)
                }
                if applicationsExpanded {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3), alignment: .leading, spacing: 0) {
                        ForEach(applications, id: \.bundleID) { app in
                            applicationSelection(app).frame(minHeight: 39, alignment: .leading)
                        }
                    }
                    if !browsers.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: compact ? 1 : 2), alignment: .leading, spacing: 14) {
                            ForEach(browsers, id: \.bundleID) { app in
                                VStack(alignment: .leading, spacing: 7) {
                                    applicationSelection(app)
                                    Text("勾选后统计整个浏览器用时；只统计添加的网站时，请勿勾选。")
                                        .font(SettingsStyle.metadata).foregroundStyle(Graphite.muted)
                                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
                                }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 13)
                                    .overlay(alignment: .top) { Rectangle().fill(Graphite.line).frame(height: 1) }
                            }
                        }
                    }
                } else {
                    Text(selectedAppNames).font(SettingsStyle.caption).foregroundStyle(Graphite.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().overlay(Graphite.line)
            VStack(alignment: .leading, spacing: 8) {
                fieldHeading("网站", detail: "包含子域名", prominent: false)
                if monitor.preferences.websites.isEmpty { hint("还没有添加网站") }
                ForEach(monitor.preferences.websites, id: \.domain) { site in
                    HStack {
                        Toggle(site.domain, isOn: Binding(get: { monitor.preferences.websites.first(where: { $0.domain == site.domain })?.enabled ?? false }, set: { enabled in
                            var value = monitor.preferences
                            if let index = value.websites.firstIndex(where: { $0.domain == site.domain }) { value.websites[index].enabled = enabled }
                            monitor.updatePreferences(value)
                        })).toggleStyle(.checkbox).controlSize(.small).font(SettingsStyle.body)
                        Spacer()
                        Button {
                            var value = monitor.preferences
                            value.websites.removeAll { $0.domain == site.domain }
                            monitor.updatePreferences(value)
                        } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                            .buttonStyle(.plain).accessibilityLabel("移除网站 \(site.domain)")
                    }.foregroundStyle(Graphite.muted).frame(minHeight: 35)
                        .overlay(alignment: .bottom) { Rectangle().fill(Graphite.line.opacity(0.6)).frame(height: 1) }
                }
                HStack(spacing: 7) {
                    TextField("域名或完整网址，如 youtube.com", text: $website).textFieldStyle(.plain).font(SettingsStyle.caption)
                        .padding(.horizontal, 11).frame(height: SettingsStyle.fieldHeight).modifier(SettingsOutline()).onSubmit(addWebsite)
                    Button("添加", action: addWebsite).frame(height: SettingsStyle.fieldHeight)
                }
                if let websiteError { Text(websiteError).font(SettingsStyle.caption).foregroundStyle(Graphite.warning) }
            }.padding(.top, 5)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 9) {
                    hint("选中的应用和网站合并计算每天的使用时长，不是每项各算一份。选中整个浏览器时，其中所有网站都会计入合计，即使未单独选中网站。重复匹配的用时只算一次。")
                    hint("支持 HTTP / HTTPS 网站。完整链接会按域名保存，页面路径与参数不参与匹配。例：bilibili.com、youtube.com、github.com。")
                }.padding(.top, 10)
            } label: {
                Text("这些用时如何计算？").font(SettingsStyle.metadata).foregroundStyle(Graphite.muted)
            }.padding(.top, 5)
        }
    }

    private func applicationSelection(_ app: AppIdentity) -> some View {
        Toggle(isOn: Binding(get: { monitor.preferences.selectedApps.contains(app.bundleID) }, set: { selected in
            var value = monitor.preferences
            if selected { value.selectedApps.insert(app.bundleID) } else { value.selectedApps.remove(app.bundleID) }
            monitor.updatePreferences(value)
        })) {
            HStack(spacing: 8) {
                AppIcon(bundleID: app.bundleID).frame(width: 22, height: 22)
                Text(app.name).font(SettingsStyle.body).lineLimit(2)
            }
        }.toggleStyle(.checkbox).controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateRangeSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            let warning = monitor.preferences.warningPercent
            let spent = monitor.preferences.spentPercent
            let maximum = Double(max(120, spent * 6 / 5))
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    Graphite.safe.frame(width: max(0, (geometry.size.width - 6) * Double(warning) / maximum))
                    Graphite.warning.frame(width: max(0, (geometry.size.width - 6) * Double(spent - warning) / maximum))
                    Graphite.spent
                }.clipShape(Capsule())
            }.frame(height: 4)
            HStack(spacing: 12) {
                stateLabel("充足  0–\(warning - 1)%", color: Graphite.safe)
                Spacer(minLength: 0)
                stateLabel("留意  \(warning)–\(spent - 1)%", color: Graphite.warning)
                Spacer(minLength: 0)
                stateLabel("用尽  \(spent)% 起", color: Graphite.spent)
            }
            DisclosureGroup(isExpanded: $stateRangesExpanded) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            stateLabel("进入「留意」", color: Graphite.warning)
                            numberField("进入留意的百分比", value: binding(\.warningPercent), unit: "%", range: 1...(spent - 1))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            stateLabel("进入「用尽」", color: Graphite.spent)
                            numberField("进入用尽的百分比", value: binding(\.spentPercent), unit: "%", range: (warning + 1)...300)
                        }
                    }
                    hint("状态范围控制书签、小球与进度条的颜色，通知按提醒节点触发。")
                    let percent = monitor.summary.scopedSeconds / Double(max(1, monitor.preferences.quotaMinutes) * 60) * 100
                    let state = Graphite.state(percent: percent, preferences: monitor.preferences)
                    Label("今天合计已用每日限额的 \(Int(percent))% · \(state.0)", systemImage: "circle.fill")
                        .font(SettingsStyle.metadata).foregroundStyle(state.1)
                }.padding(.top, 12)
            } label: {
                Text("调整状态分界").font(SettingsStyle.metadata).foregroundStyle(Graphite.muted)
            }
        }
    }

    private var reminderModePicker: some View {
        HStack(spacing: 3) {
            ForEach([("percent", "按限额比例"), ("minutes", "按使用时长")], id: \.0) { kind in
                Button { binding(\.reminderKind).wrappedValue = kind.0 } label: {
                    Text(kind.1).font(SettingsStyle.caption)
                        .foregroundStyle(monitor.preferences.reminderKind == kind.0 ? Graphite.ink : Graphite.muted)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(monitor.preferences.reminderKind == kind.0 ? .white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(monitor.preferences.reminderKind == kind.0 ? .isSelected : [])
            }
        }.padding(3).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
    }

    private var reminderSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            if activeNodes.isEmpty { hint("还没有提醒节点，添加一个开始设置。") }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(activeNodeBinding) { $node in
                    HStack(spacing: 6) {
                        TextField("节点", text: $node.value).textFieldStyle(.plain).font(.system(size: 17)).monospacedDigit()
                            .accessibilityLabel("提醒节点")
                        Text(isPercent ? "%" : "分钟").font(SettingsStyle.metadata).foregroundStyle(Graphite.muted).fixedSize()
                        Button { removeNode(node.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).foregroundStyle(Graphite.muted).accessibilityLabel("移除提醒节点 \(node.value)")
                    }.padding(.horizontal, 10).frame(height: 36).modifier(SettingsOutline(filled: false))
                }
            }
            HStack(spacing: 12) {
                Button(action: addNode) { Label("添加节点", systemImage: "plus") }
                    .buttonStyle(.plain).font(SettingsStyle.caption).foregroundStyle(Graphite.accent)
                Spacer(minLength: 0)
                Text("每个节点每天提醒一次").font(SettingsStyle.metadata).foregroundStyle(Graphite.muted)
            }
        }
    }

    private var messageSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldHeading("提醒文案")
            TextEditor(text: $message).font(SettingsStyle.body).lineSpacing(4).scrollContentBackground(.hidden)
                .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 22).frame(height: 86)
                .modifier(SettingsOutline())
                .overlay(alignment: .bottomTrailing) {
                    Text("\(message.count) / 80").font(SettingsStyle.metadata).foregroundStyle(message.count > 80 ? Graphite.warning : Graphite.muted)
                        .padding(.trailing, 11).padding(.bottom, 7).allowsHitTesting(false)
                }.accessibilityLabel("写给自己的一句话")
            HStack(spacing: 9) {
                Button("温和一点") { message = "先停一下，把时间留给今天真正想做的事。" }
                Button("直接一点") { message = "现在关掉它，去完成那件重要的事。" }
            }
        }
    }

    private var notificationPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Menu {
                    ForEach(activeNodes) { node in Button("达到 \(node.value)\(isPercent ? "%" : " 分钟")") { previewNode = node.value } }
                } label: {
                    Text("达到 \(previewValue)\(isPercent ? "%" : " 分钟")").font(SettingsStyle.metadata).foregroundStyle(Graphite.muted)
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("预览提醒节点")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "timer").font(.system(size: 15)).foregroundStyle(Graphite.accent)
                        .frame(width: 26, height: 26).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    Text("Timeglow").font(.system(size: 11, weight: .medium)).foregroundStyle(Graphite.muted)
                    Spacer()
                    Text("现在").font(SettingsStyle.metadata).foregroundStyle(Graphite.muted)
                }
                Text(activeNodes.isEmpty ? "还没有设置提醒节点" : previewTitle).font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(message.isEmpty ? "在上方写下一句提醒自己的话。" : message).font(SettingsStyle.caption)
                    .foregroundStyle(Graphite.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Graphite.line, lineWidth: 1))
            HStack(spacing: 14) {
                Button("演示此节点提醒") {
                    if let context = reminderPreviewContext() { permissions.previewReminder?(context) }
                }.disabled(activeNodes.isEmpty)
                Button("发送系统测试通知 ↗") { Task { await sendTestNotification() } }.disabled(activeNodes.isEmpty)
                    .buttonStyle(.plain).font(SettingsStyle.caption).foregroundStyle(Graphite.muted)
            }
            if let previewFeedback {
                Text(previewFeedback).font(SettingsStyle.caption).foregroundStyle(Graphite.accent)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            hint("系统横幅是否显示，取决于通知设置和专注模式。")
        }
    }

    private var permissionsSettings: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.sectionGap) {
            VStack(alignment: .leading, spacing: 10) {
                fieldHeading("网页统计与授权")
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(BrowserReader.supported.keys.sorted(), id: \.self) { id in
                        HStack(spacing: 10) {
                            Toggle(isOn: Binding(get: { monitor.preferences.enabledBrowsers.contains(id) }, set: { enabled in
                                var value = monitor.preferences
                                if enabled { value.enabledBrowsers.insert(id) } else { value.enabledBrowsers.remove(id) }
                                monitor.updatePreferences(value)
                            })) {
                                HStack(spacing: 9) {
                                    AppIcon(bundleID: id).frame(width: 25, height: 25)
                                    Text(BrowserReader.supported[id]!).font(SettingsStyle.fieldLabel)
                                }
                            }.toggleStyle(.checkbox).controlSize(.small)
                            Spacer(minLength: 0)
                            Text((monitor.browserPermissions[id] ?? .notRequested).label).font(SettingsStyle.metadata).foregroundStyle(Graphite.muted)
                            Button("授权…") { monitor.requestBrowserPermission(id) }
                        }
                    }
                    Divider().overlay(Graphite.line)
                    hint("开启后仅在浏览器位于前台时读取当前网站。首次使用请打开对应浏览器，再点击授权；系统可能显示“想要控制浏览器”。")
                    Button("打开自动化设置 ↗") { openSystemSettings("Privacy_Automation") }
                }.modifier(SettingsGroup())
            }
            VStack(alignment: .leading, spacing: 10) {
                fieldHeading("计时规则")
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("闲置后暂停计时").font(SettingsStyle.fieldLabel)
                        Spacer()
                        Picker("闲置多久后暂停", selection: binding(\.idleSeconds)) {
                            Text("1 分钟").tag(60.0); Text("3 分钟").tag(180.0); Text("5 分钟").tag(300.0)
                            Text("10 分钟").tag(600.0); Text("不自动排除闲置").tag(0.0)
                        }.labelsHidden().font(SettingsStyle.caption).frame(width: 150)
                    }
                    hint("长时间阅读或看视频时可延长闲置阈值。锁屏、屏幕休眠和手动暂停另行停止计时。")
                }.modifier(SettingsGroup())
            }
            VStack(alignment: .leading, spacing: 10) {
                fieldHeading("系统通知")
                VStack(alignment: .leading, spacing: 13) {
                    hint(notificationDescription)
                    HStack(spacing: 10) {
                        Button("允许通知…") { Task { await permissions.requestNotifications() } }
                        Button("通知设置 ↗") { openSystemSettings("Privacy_Notifications") }
                    }
                }.modifier(SettingsGroup())
            }
        }
    }

    private var startupSettings: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.sectionGap) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 20) {
                    Text("登录 Mac 时自动启动").font(SettingsStyle.fieldLabel)
                    Spacer(minLength: 0)
                    Toggle("登录 Mac 时自动启动", isOn: Binding(get: { permissions.loginEnabled }, set: { enabled in
                        Task { await permissions.setLoginEnabled(enabled) }
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if permissions.loginNeedsApproval {
                    Button("在系统设置中允许登录项") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = permissions.error { Text(error).font(SettingsStyle.caption).foregroundStyle(Graphite.warning) }
                Divider().overlay(Graphite.line)
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("本地记录").font(SettingsStyle.fieldLabel)
                        hint("所有用时记录仅保存在这台 Mac 上")
                    }
                    Spacer(minLength: 0)
                    Button("查看位置 ↗") { NSWorkspace.shared.activateFileViewerSelecting([monitor.databaseURL]) }
                }
            }.modifier(SettingsGroup())
            hint("关闭窗口后继续记录，可通过书签或菜单栏查看；退出 Timeglow 后停止记录。")
        }
    }

    private func fieldHeading(_ title: String, detail: String? = nil, prominent: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(prominent ? SettingsStyle.sectionTitle : SettingsStyle.fieldLabel).foregroundStyle(Graphite.ink)
            Spacer(minLength: 0)
            if let detail { Text(detail).font(SettingsStyle.metadata).foregroundStyle(Graphite.muted) }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(SettingsStyle.caption).foregroundStyle(Graphite.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    private func stateLabel(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(SettingsStyle.metadata).foregroundStyle(Graphite.muted) }
    }

    private func numberField(_ label: String, value: Binding<Int>, unit: String, range: ClosedRange<Int>) -> some View {
        HStack {
            TextField(label, value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }), format: .number.grouping(.never))
                .textFieldStyle(.plain).font(SettingsStyle.body).monospacedDigit().accessibilityLabel(label)
            Text(unit).font(SettingsStyle.metadata).foregroundStyle(Graphite.muted)
        }.padding(.horizontal, 11).frame(height: SettingsStyle.fieldHeight).modifier(SettingsOutline())
    }


    private var notificationDescription: String {
        switch permissions.notificationStatus {
        case .authorized, .provisional: return "系统通知已允许"
        case .denied: return "系统通知未允许，计时仍然继续"
        default: return "尚未申请系统通知权限"
        }
    }

    private func addNode() {
        let maximum = isPercent ? 300 : 1440
        let step = isPercent ? 10 : 30
        let used = Set(activeNodes.compactMap { Int($0.value) })
        let suggested = (used.max() ?? 0) + step
        guard let next = suggested <= maximum ? suggested : (1...maximum).first(where: { !used.contains($0) }) else { return }
        activeNodeBinding.wrappedValue.append(.init(value: String(next)))
    }

    private func removeNode(_ id: UUID) { activeNodeBinding.wrappedValue.removeAll { $0.id == id } }

    private func addWebsite() {
        guard let domain = DomainRules.normalized(website) else { websiteError = "请输入有效的域名或 http/https 网址。"; return }
        var value = monitor.preferences
        value.addWebsite(domain)
        monitor.updatePreferences(value)
        website = ""
        websiteError = nil
    }

    private func addApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "加入每日合计"
        guard panel.runModal() == .OK else { return }
        let apps = panel.urls.compactMap { url -> AppIdentity? in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            return .init(bundleID: id, name: name)
        }
        monitor.addApplications(apps)
    }

    private func saveReminderDraft() {
        func values(_ nodes: [ReminderNodeDraft], maximum: Int) -> [Int]? {
            let values = nodes.compactMap { Int($0.value.trimmingCharacters(in: .whitespaces)) }
            guard !values.isEmpty, values.count == nodes.count, Set(values).count == values.count, values.allSatisfy({ (1...maximum).contains($0) }) else { return nil }
            return values.sorted()
        }
        guard let percent = values(percentNodes, maximum: 300), let minutes = values(minuteNodes, maximum: 1440), !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.count <= 80 else {
            draftError = "节点不能重复；百分比为 1–300，分钟数为 1–1440，警示语为 1–80 字。"; return
        }
        var value = monitor.preferences
        value.percentThresholds = percent
        value.minuteThresholds = minutes
        value.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        draftError = nil
        draftSaved = false
        monitor.updatePreferences(value) { success in
            draftSaved = success
            if !success { draftError = monitor.error }
        }
    }

    private func reminderPreviewContext() -> ReminderContext? {
        guard let node = Int(previewValue), node > 0 else { return nil }
        let quota = monitor.preferences.quotaMinutes
        let context = ReminderContext(day: ReminderContext.dayKey(at: Date()), kind: isPercent ? .percent : .minutes,
                                      node: node, quotaMinutes: quota,
                                      scopedSeconds: isPercent ? Double(node) / 100 * Double(quota) * 60 : Double(node) * 60,
                                      triggeredAt: Date(), message: message, isTest: true)
        return context.isValid ? context : nil
    }

    private func sendTestNotification() async {
        await permissions.refresh()
        guard permissions.notificationStatus == .authorized || permissions.notificationStatus == .provisional else {
            previewFeedback = "尚未允许系统通知，可在左侧「权限与计时」中开启；也可以先演示此节点提醒。"; return
        }
        do {
            guard let context = reminderPreviewContext() else { return }
            try await permissions.send(identifier: "timeglow-settings-test-\(UUID().uuidString)", title: "Timeglow · 测试通知", body: previewTitle + "。\n" + message, reminder: context)
            previewFeedback = "已发送系统测试通知，实际横幅显示取决于系统通知设置。"
        } catch { previewFeedback = "测试通知未发送：\(error.localizedDescription)" }
    }

    private func openSystemSettings(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)") { NSWorkspace.shared.open(url) }
    }
}
