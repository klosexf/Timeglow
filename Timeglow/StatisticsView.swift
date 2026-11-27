import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

enum UsageText {
    static func percent(_ value: Double, rounded: Bool = false) -> String {
        if value > 0, value < 1 { return "<1%" }
        return "\(Int(rounded ? value.rounded() : value.rounded(.down)))%"
    }
    static func time(_ seconds: Double) -> String {
        let s = Int(max(0, seconds)), m = s / 60
        if s == 0 { return "0 分钟" }
        if m == 0 { return "\(s) 秒" }
        if m < 60 { return "\(m) 分钟" }
        return m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 时 \(m % 60) 分"
    }
    static func day(_ date: Date) -> String { date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) }
    static func range(_ interval: DateInterval, period: ReportPeriod) -> String {
        let first = interval.start, last = period == .all ? interval.end : interval.end.addingTimeInterval(-1)
        let calendar = Calendar.current
        if calendar.isDate(first, inSameDayAs: last) { return day(first) }
        let tail = calendar.isDate(first, equalTo: last, toGranularity: .month) ? "\(calendar.component(.day, from: last))日" : day(last)
        return day(first) + " – " + tail
    }
}

private struct StatisticsCard: ViewModifier {
    var compact: Bool
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 12 : 16)
            .background(Color(red: 0.18, green: 0.188, blue: 0.208), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Graphite.line, lineWidth: 1))
    }
}

private func cardHeading(_ title: String, _ note: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 13, weight: .semibold))
        Spacer(minLength: 6)
        Text(note).font(.system(size: 11)).foregroundStyle(Graphite.muted)
    }
}

private struct ReportDestination: Equatable {
    var period: ReportPeriod
    var anchor: Date
    var page: Int
}

struct StatisticsView: View {
    let monitor: MonitoringController
    @ObservedObject var navigation: WorkspaceNavigation
    @State private var report: UsageReport?
    @State private var loadedKey: ReportRefreshKey?
    @State private var failedKey: ReportRefreshKey?
    @State private var reportError = ""
    @State private var retry = 0
    @State private var exportError: String?
    @State private var parent: ReportDestination?
    @State private var showAll = false
    @State private var page = 0
    private var period: ReportPeriod { navigation.period }
    private var anchor: Date { navigation.anchor }
    private var key: ReportRefreshKey { monitor.reportRefreshKey(period: period, anchor: anchor) }
    private var displayed: UsageReport? {
        guard let loadedKey, loadedKey.period == key.period, loadedKey.anchor == key.anchor,
              loadedKey.scope == key.scope, loadedKey.today == key.today, failedKey != key else { return nil }
        return report
    }
    private var interval: DateInterval { displayed?.interval ?? period.interval(anchor: anchor, firstRecord: nil) }
    private var canAdvance: Bool { period != .all && interval.start < period.interval(anchor: Date(), firstRecord: nil).start }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width <= 900
            let inset: CGFloat = 29
            let width = max(0, geometry.size.width - 2 * inset)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 12) {
                        if let parent {
                            Button { goBack(parent) } label: { Label(parent.period == .all ? "返回累计" : "返回周统计", systemImage: "arrow.left") }
                                .buttonStyle(.plain).foregroundStyle(Graphite.muted)
                        }
                        Text("使用统计").font(.system(size: 25, weight: .semibold))
                        Spacer()
                        Button(action: exportCSV) { Label("导出 CSV", systemImage: "square.and.arrow.down") }
                            .buttonStyle(WorkspaceActionButtonStyle()).disabled(loadedKey != key || displayed?.days.contains(where: \.hasRecord) != true)
                    }
                    HStack(spacing: 8) {
                        PeriodControl(period: Binding(get: { period }, set: { destination in
                            parent = nil; showAll = false; page = 0; navigation.period = destination
                        }), overview: false).frame(width: 139)
                        Spacer()
                        if period != .all { arrow("上一周期", direction: -1) { move(-1) }.disabled(interval.start <= Calendar.current.startOfDay(for: displayed?.firstRecord ?? report?.firstRecord ?? Date())) }
                        Label(period == .all && displayed == nil ? "累计" : UsageText.range(interval, period: period), systemImage: "calendar")
                            .foregroundStyle(Graphite.muted)
                        if period != .all {
                            arrow("下一周期", direction: 1) { move(1) }.disabled(!canAdvance)
                            if canAdvance { Button(period == .week ? "回到本周" : "回到今天") { navigation.anchor = Date(); page = 0 }.buttonStyle(.plain) }
                        }
                    }.font(.system(size: 12)).frame(minHeight: 30)
                    if let report = displayed {
                        metrics(report)
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 14) {
                                TrendCard(report: report, period: period, compact: compact)
                                rankings(report, compact: compact)
                            }.frame(width: (width - 14) * 1.2 / 2.2)
                            VStack(spacing: 14) {
                                CategoryCard(categories: report.categories, compact: compact)
                                quotas(report, compact: compact)
                            }.frame(maxWidth: .infinity)
                        }
                    } else if failedKey == key {
                        VStack(alignment: .leading, spacing: 8) { Text("未能读取统计"); Text(reportError).foregroundStyle(Graphite.muted); Button("重新读取") { retry += 1 } }
                            .modifier(StatisticsCard(compact: compact))
                    } else { ProgressView("正在读取统计…").controlSize(.small) }
                }.padding(.horizontal, inset).padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: navigation.section == "statistics" ? ReadRequest(key: key, retry: retry) : nil) {
            if navigation.section == "statistics" { await reload() }
        }
        .onChange(of: navigation.todayRequest) { parent = nil; page = 0; showAll = false }
        .alert("未能导出", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("好") { exportError = nil } } message: { Text(exportError ?? "") }
    }
    private struct ReadRequest: Hashable { var key: ReportRefreshKey; var retry: Int }
    private func reload() async {
        let requested = key
        failedKey = nil
        do {
            let result = try await monitor.report(period: requested.period, anchor: anchor)
            try Task.checkCancellation()
            guard requested == key else { return }
            report = result; loadedKey = requested
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requested == key else { return }
            reportError = error.localizedDescription; failedKey = requested
        }
    }

    private func goBack(_ previous: ReportDestination) {
        navigation.anchor = previous.anchor; navigation.period = previous.period; page = previous.page; parent = nil; showAll = false
    }
    private func move(_ amount: Int) {
        if let date = Calendar.current.date(byAdding: .day, value: amount * (period == .week ? 7 : 1), to: anchor) { navigation.anchor = date; page = 0; showAll = false }
    }
    private func arrow(_ name: String, direction: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: direction < 0 ? "chevron.left" : "chevron.right").frame(width: 20, height: 22) }
            .buttonStyle(.plain).accessibilityLabel(name).help(name)
    }

    private func metrics(_ report: UsageReport) -> some View {
        let count = report.days.filter(\.hasRecord).count, total = report.summary.totalSeconds
        let part = total > 0 ? UsageText.percent(report.summary.scopedSeconds / total * 100, rounded: true) : "—"
        return HStack(spacing: 0) {
            metric("计入额度", report.summary.scopedSeconds, count, "占全部用时 " + part)
            Divider().padding(.horizontal, 18)
            metric("全部应用用时", total, count, "网站已计入浏览器")
            if period != .day {
                Divider().padding(.horizontal, 18)
                metric("日均使用", report.averageSeconds, count, "按有记录的 \(count) 天计算")
            }
        }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
    }
    private func metric(_ label: String, _ seconds: Double, _ count: Int, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Graphite.muted)
            if count == 0 { Text("—").font(.system(size: 30)) }
            else {
                let parts = UsageText.time(seconds).split(separator: " ")
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Text(part).font(.system(size: Int(part) == nil ? 16 : 30, weight: .medium)).monospacedDigit()
                    }
                }
            }
            Text(count == 0 ? "此期间暂无记录" : note).font(.system(size: 11)).foregroundStyle(Graphite.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankings(_ report: UsageReport, compact: Bool) -> some View {
        let apps = report.summary.applications
        return VStack(alignment: .leading, spacing: 8) {
            cardHeading("应用与网站排行", "按用时排序")
            if apps.isEmpty { Text("此期间暂无应用记录").foregroundStyle(Graphite.muted).padding(.vertical, 18) }
            else {
                UsageRows(applications: showAll ? apps : Array(apps.prefix(4)), selectedApps: monitor.preferences.selectedApps, websiteRules: monitor.preferences.websites, addApplication: { monitor.addApplications([.init(bundleID: $0.id, name: $0.name)]) }, addWebsite: monitor.addWebsite)
                if apps.count > 4 {
                    Button(showAll ? "收起排行" : "查看全部 \(apps.count) 个应用 ›") { showAll.toggle() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Graphite.muted)
                }
            }
        }.modifier(StatisticsCard(compact: compact))
    }

    private func quotas(_ report: UsageReport, compact: Bool) -> some View {
        let days = report.days
        let pageSize = 14
        let maxPage = max(0,(days.count-1)/pageSize)
        let end = max(0, days.count - min(page, maxPage)*pageSize)
        let visible = Array(days[max(0,end-pageSize)..<end])
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                cardHeading("每日额度", period == .all && maxPage > 0 ? "" : "每日 " + UsageText.time(Double(monitor.preferences.quotaMinutes*60)))
                if period == .all && maxPage > 0 {
                    arrow("更早的额度记录", direction: -1) { page = min(maxPage, page+1) }.disabled(page >= maxPage)
                    arrow("较新的额度记录", direction: 1) { page = max(0,page-1) }.disabled(page == 0)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(visible) { day in quotaTile(day) }
            }
            Divider()
            let recorded = days.filter(\.hasRecord)
            Text(recorded.isEmpty ? "此期间暂无额度记录。" : "有记录 \(recorded.count) 天，\(recorded.filter { $0.percent >= 100 }.count) 天达到额度。").font(.system(size: 11)).foregroundStyle(Graphite.muted)
        }.modifier(StatisticsCard(compact: compact))
    }

    private func quotaTile(_ day: DailyUsage) -> some View {
        let status = day.date > Date() ? "尚未到" : "无记录"
        let value = day.hasRecord ? UsageText.percent(day.percent) : "—"
        return Button {
            parent = .init(period: period, anchor: anchor, page: page)
            navigation.period = .day; navigation.anchor = day.date; page = 0; showAll = false
        } label: {
            VStack(spacing: 4) {
                Text(day.date, format: .dateTime.month(.twoDigits).day(.twoDigits)).font(.system(size: 10)).foregroundStyle(Graphite.muted)
                Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(day.hasRecord ? Graphite.state(percent: day.percent, preferences: monitor.preferences).1 : Graphite.muted)
            }.monospacedDigit().frame(maxWidth: .infinity).frame(height: 43).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).disabled(!day.hasRecord || period == .day)
            .help(day.hasRecord ? UsageText.time(day.scoped) + " / " + UsageText.time(Double(day.quotaMinutes*60)) : status)
            .accessibilityLabel(UsageText.day(day.date) + "，" + (day.hasRecord ? value : status))
    }

    private func exportCSV() {
        guard loadedKey == key, let report = displayed, report.days.contains(where: \.hasRecord) else { return }
        let dates = report.days.map { ReminderContext.dayKey(at: $0.date) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Timeglow_\(dates.first ?? "")_\(dates.last ?? "").csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var rows = [["日期", "应用", "使用分钟"]]
        for day in report.days where day.hasRecord {
            rows += (report.timesByDay[day.date] ?? []).map { [ReminderContext.dayKey(at: day.date), $0.name, String(format: "%.2f", $0.seconds / 60)] }
        }
        let csv = "\u{feff}" + rows.map { row in row.map { value in
            let safe = value.first.map { "=+-@".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") }.joined(separator: "\r\n")
        do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch { exportError = error.localizedDescription }
    }
}

private struct CategoryCard: View {
    let categories: [UsageCategory]
    let compact: Bool
    var body: some View {
        let diameter: CGFloat = compact ? 98 : 116
        let total = categories.reduce(0) { $0 + $1.seconds }
        VStack(spacing: 8) {
            cardHeading("用途分类", "按应用归类")
            HStack(spacing: compact ? 14 : 24) {
                ZStack {
                    if categories.isEmpty { Circle().strokeBorder(Graphite.line, lineWidth: 12) }
                    else { Chart(categories) { category in
                        SectorMark(angle: .value("用时", category.seconds), innerRadius: .ratio(0.76)).foregroundStyle(Graphite.categoryColor(category.name))
                    } }
                    VStack(spacing: 3) {
                        Text(categories.first.map { UsageText.time($0.seconds) } ?? "—").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Text(categories.first?.name ?? "无记录").font(.system(size: 11)).foregroundStyle(Graphite.muted)
                    }.frame(width: diameter * 0.75)
                }.frame(width: diameter, height: diameter)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(categories) { category in
                        GridRow {
                            Circle().fill(Graphite.categoryColor(category.name)).frame(width: 7, height: 7)
                            Text(category.name)
                            Text(UsageText.percent(category.seconds / max(total,1) * 100, rounded: true)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                    }
                    if categories.isEmpty { Text("有记录后显示各类占比") }
                }.font(.system(size: compact ? 11 : 12)).foregroundStyle(Graphite.muted)
            }.frame(maxWidth: .infinity, minHeight: compact ? 142 : 158)
        }.modifier(StatisticsCard(compact: compact))
    }
}

private struct TrendCard: View {
    let report: UsageReport
    let period: ReportPeriod
    let compact: Bool
    @State private var selected: Date?
    private var monthly: Bool { period == .all && report.days.count > 45 }
    private var points: [UsageTrendPoint] {
        guard monthly else { return report.trend }
        return Dictionary(grouping: report.trend) { Calendar.current.dateInterval(of: .month, for: $0.date)!.start }
            .map { start, group in UsageTrendPoint(date: start, total: group.reduce(0) { $0 + $1.total }, scoped: group.reduce(0) { $0 + $1.scoped }, hasRecord: group.contains(where: \.hasRecord)) }
            .sorted { $0.date < $1.date }
    }
    private func label(_ date: Date, axis: Bool) -> String {
        let c = Calendar.current
        if period == .day { return String(format: axis ? "%d时" : "%02d:00", c.component(.hour, from: date)) }
        if monthly { return date.formatted(.dateTime.year().month().locale(Locale(identifier: "zh_CN"))) }
        if axis && period == .week { return ["周日","周一","周二","周三","周四","周五","周六"][c.component(.weekday, from: date)-1] }
        return axis ? date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) : UsageText.day(date)
    }
    private func detail(_ point: UsageTrendPoint) -> String {
        if point.date > Date() { return "尚未到" }
        return point.hasRecord ? "全部 " + UsageText.time(point.total) + " · 计入额度 " + UsageText.time(point.scoped) : "无记录"
    }
    var body: some View {
        let buckets = points, slots = buckets.indices.map { String($0) }
        let latest = buckets.lastIndex(where: { $0.date <= Date() && $0.hasRecord }) ?? 0
        let current = buckets.firstIndex(where: { $0.date == selected }) ?? latest
        let divisor: Double = period != .day && (buckets.map(\.total).max() ?? 0) >= 7200 ? 3600 : 60
        let stride = period == .day ? 4 : max(1, Int(ceil(Double(slots.count)/7)))
        VStack(alignment: .leading, spacing: 8) {
            cardHeading("用时趋势", divisor == 3600 ? "小时" : "分钟")
            HStack(spacing: 16) {
                legend("全部用时", Graphite.accent.opacity(0.72))
                legend("其中计入额度", Graphite.safe)
            }
            Chart(Array(buckets.enumerated()), id: \.element.id) { index, point in
                BarMark(x: .value("时段", String(index)), yStart: .value("起点",0), yEnd: .value("全部", point.total / divisor), width: .ratio(0.55))
                    .foregroundStyle(Graphite.accent.opacity(0.72))
                BarMark(x: .value("时段", String(index)), yStart: .value("起点",0), yEnd: .value("计入额度",point.scoped / divisor), width: .ratio(0.55))
                    .foregroundStyle(Graphite.safe)
            }.chartXScale(domain: slots)
                .chartXAxis {
                    AxisMarks(values: slots.indices.compactMap { $0.isMultiple(of: stride) ? slots[$0] : nil }) { value in
                        if let key = value.as(String.self), let i = Int(key), buckets.indices.contains(i) {
                            AxisValueLabel { Text(label(buckets[i].date, axis: true)).font(.system(size: 10)) }
                        }
                    }
                }.chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { AxisGridLine(); AxisValueLabel().font(.system(size: 10)) }
                }
                .chartOverlay { proxy in GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let p) = phase { select(p, proxy, geometry, buckets) }
                        }.onTapGesture { p in select(p, proxy, geometry, buckets) }
                } }
                .frame(height: compact ? 115 : 136)
                .focusable().onMoveCommand { direction in
                    guard !buckets.isEmpty, direction == .left || direction == .right else { return }
                    selected = buckets[max(0,min(buckets.count-1,current + (direction == .left ? -1 : 1)))].date
                }.accessibilityLabel("用时趋势，左右方向键选择时段")
            if buckets.indices.contains(current) {
                let p = buckets[current]
                HStack(spacing: 7) { Text(label(p.date, axis: false)).fontWeight(.semibold); Text(detail(p)).foregroundStyle(Graphite.muted) }
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
        }.modifier(StatisticsCard(compact: compact))
    }
    private func select(_ p: CGPoint, _ proxy: ChartProxy, _ geometry: GeometryProxy, _ points: [UsageTrendPoint]) {
        guard let frame = proxy.plotFrame, geometry[frame].contains(p),
              let key = proxy.value(atX: p.x - geometry[frame].minX, as: String.self),
              let i = Int(key), points.indices.contains(i) else { return }
        selected = points[i].date
    }
    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8,height: 8); Text(text) }.font(.system(size: 11)).foregroundStyle(Graphite.muted)
    }
}
