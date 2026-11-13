import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

struct StatisticsView: View {
    let monitor: MonitoringController
    @State private var period: ReportPeriod = .day
    @State private var anchor = Date()
    @State private var report: UsageReport?
    @State private var exportError: String?
    @State private var reportError: String?
    private let columns = [GridItem(.flexible(), spacing: WorkspaceStyle.cardGap), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("把时间看清楚").font(.system(size: 11)).foregroundStyle(Graphite.muted)
                        Text(period == .all ? "一路以来的时间去向" : period == .week ? "这一周的时间去向" : "这一天的时间去向").font(.system(size: 25, weight: .medium))
                    }
                    Spacer()
                    Button(action: exportCSV) {
                        HStack(spacing: 7) { Text("导出 CSV"); Image(systemName: "arrow.up.right").font(.system(size: 10)) }
                    }.buttonStyle(WorkspaceActionButtonStyle())
                }
                HStack {
                    Picker("统计周期", selection: $period) { ForEach(ReportPeriod.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 210, alignment: .leading)
                    Spacer()
                    if period != .all {
                        Button { move(-1) } label: { Image(systemName: "chevron.left") }.help("上一周期")
                        Text(anchor, format: .dateTime.year().month().day()).font(.system(size: 11)).foregroundStyle(Graphite.muted)
                        Button { move(1) } label: { Image(systemName: "chevron.right") }.disabled(!canMoveForward).help("下一周期")
                        Button("回到今天") { anchor = Date() }.font(.system(size: 10))
                    }
                }
                if let reportError { Text(reportError).font(.caption).foregroundStyle(.orange) }
                if let report {
                    HStack(spacing: 0) {
                        metric("所有应用总时长", DurationText.format(report.summary.totalSeconds), "前台使用时长 · 网站计入浏览器")
                        metricDivider
                        if period != .day {
                            metric("日均使用", DurationText.format(report.averageSeconds), "按有记录的 \(report.days.filter(\.hasRecord).count) 天计算")
                            metricDivider
                        }
                        metric("所选应用和网站合计用时", DurationText.format(report.summary.scopedSeconds), "占全部用时 \(Int(report.summary.scopedSeconds / max(1, report.summary.totalSeconds) * 100))%")
                    }.padding(.vertical, 6)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: WorkspaceStyle.cardGap) {
                        TrendCard(report: report, period: period)
                        CategoryCard(categories: report.categories)
                        VStack(alignment: .leading, spacing: 12) {
                            cardTitle("每个应用，都有记录", "按使用时长排序 · 浏览器可展开网站")
                            if report.summary.applications.isEmpty { emptyRecord.frame(maxWidth: .infinity, minHeight: 140) }
                            else {
                                GeometryReader { geometry in
                                    ScrollView {
                                        UsageRows(applications: report.summary.applications, selectedApps: monitor.preferences.selectedApps, websiteRules: monitor.preferences.websites, addApplication: { usage in
                                            monitor.addApplications([.init(bundleID: usage.id, name: usage.name)])
                                        }, addWebsite: monitor.addWebsite)
                                        .frame(width: max(0, geometry.size.width - 16))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.frame(height: 210)
                            }
                        }.graphiteCard()
                        VStack(alignment: .leading, spacing: 14) {
                            cardTitle("每日合计用时记录", "所选应用和网站合计用时 / 当日用时限额")
                            ScrollView {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 8) {
                                    ForEach(report.days) { day in
                                        let state = Graphite.state(percent: day.percent, preferences: monitor.preferences)
                                        Button {
                                            anchor = day.date; period = .day
                                        } label: {
                                            VStack(spacing: 6) {
                                                Text(day.date, format: .dateTime.month(.twoDigits).day(.twoDigits)).font(.system(size: 9))
                                                Text(day.hasRecord ? "\(Int(day.percent))%" : "—").font(.system(size: 11, weight: .medium))
                                            }.frame(maxWidth: .infinity).frame(height: 55)
                                                .foregroundStyle(day.hasRecord ? state.1 : Graphite.muted)
                                                .background((day.hasRecord ? state.1 : .gray).opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
                                        }.buttonStyle(.plain).disabled(!day.hasRecord)
                                    }
                                }
                            }.frame(height: 150)
                            HStack(spacing: 12) {
                                legend("充足", Graphite.safe); legend("留意", Graphite.warning); legend("用尽", Graphite.spent)
                            }.font(.system(size: 9))
                            Text("\(report.days.filter { $0.hasRecord && $0.percent >= 100 }.count) 天合计用时达到或超过每日限额").font(.system(size: 11)).foregroundStyle(Graphite.muted)
                        }.graphiteCard()
                    }
                    Text("\(monitor.state) · \(monitor.currentApp)。尚未记录的时段显示为空；网站明细需先开启浏览器授权。").font(.system(size: 10)).foregroundStyle(Graphite.muted)
                }
            }.padding(WorkspaceStyle.pageInset)
        }
        .task(id: monitor.reportRefreshKey(period: period, anchor: anchor)) { await reload() }
        .alert("未能导出", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("好") { exportError = nil } } message: { Text(exportError ?? "") }
    }

    private var canMoveForward: Bool {
        return period.interval(anchor: anchor, firstRecord: nil).start < period.interval(anchor: Date(), firstRecord: nil).start
    }
    private func move(_ direction: Int) { anchor = Calendar.current.date(byAdding: .day, value: direction * (period == .week ? 7 : 1), to: anchor)! }
    private func reload() async {
        do {
            let value = try await monitor.report(period: period, anchor: anchor)
            try Task.checkCancellation()
            report = value
            reportError = nil
        } catch is CancellationError { }
        catch { reportError = "无法读取统计：\(error.localizedDescription)" }
    }
    private func metric(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11)).foregroundStyle(Graphite.muted)
            Text(value).font(.system(size: 30, weight: .regular)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(note).font(.system(size: 10)).foregroundStyle(Graphite.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var metricDivider: some View {
        Rectangle().fill(Graphite.line.opacity(0.65)).frame(width: 1, height: 78).padding(.horizontal, 24)
    }
    private var emptyRecord: some View { Text("这一段时间暂无记录").font(.system(size: 12)).foregroundStyle(Graphite.muted) }
    private func legend(_ label: String, _ color: Color) -> some View { HStack(spacing: 4) { Circle().fill(color).frame(width: 5, height: 5); Text(label).foregroundStyle(Graphite.muted) } }

    private func exportCSV() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Timeglow-使用记录.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
          do {
        var lines = [["日期", "应用", "使用分钟"]]
        for day in report.days where day.hasRecord {
            let daily = try await monitor.report(period: .day, anchor: day.date)
            let date = ISO8601DateFormatter.string(from: day.date, timeZone: .current, formatOptions: [.withFullDate])
            lines += daily.summary.applications.map { [date, $0.name, String(format: "%.2f", $0.seconds / 60)] }
        }
        let csv = "\u{feff}" + lines.map { row in row.map { value in
            let safe = value.first.map { "=+-@".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") }.joined(separator: "\r\n")
        try csv.write(to: url, atomically: true, encoding: .utf8)
          } catch { exportError = error.localizedDescription }
        }
    }
}

private func cardTitle(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.system(size: 13, weight: .medium))
        Text(subtitle).font(.system(size: 10)).foregroundStyle(Graphite.muted)
    }
}

private struct TrendCard: View {
    let report: UsageReport
    let period: ReportPeriod
    private let totalColor = Graphite.accent.opacity(0.7)
    private let scopedColor = Graphite.safe.opacity(0.85)
    @State private var selectedKey: String?

    // One discrete slot per report bucket: bars, labels and selection all
    // resolve to its center rather than mixing day/hour intervals with midnight.
    private func chartKey(_ point: UsageTrendPoint) -> String {
        point.date.formatted(.dateTime.year().month().day().hour().minute().timeZone(.iso8601(.short)).locale(Locale(identifier: "zh_CN")))
    }

    private var axisKeys: [String] {
        let step = max(1, Int(ceil(Double(report.trend.count) / 7)))
        return report.trend.enumerated().compactMap { index, point in index.isMultiple(of: step) ? chartKey(point) : nil }
    }

    private var selectedPoint: UsageTrendPoint? {
        guard let selectedKey else { return nil }
        return report.trend.first { chartKey($0) == selectedKey }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(period == .day ? "时间集中在哪些时段" : "每天花了多少时间")
                    .font(.system(size: 13, weight: .medium))
                HStack(alignment: .top, spacing: 12) {
                    legendItem("全部应用用时", color: totalColor)
                    legendItem("所选应用和网站用时（已含于总量）", color: scopedColor)
                }
                .font(.system(size: 10))
                .foregroundStyle(Graphite.muted)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("灰色：全部应用用时。绿色：所选应用和网站用时，已包含在总量中。")
            }
            Chart(report.trend) { point in
                BarMark(x: .value("时间", chartKey(point)), yStart: .value("起点", 0), yEnd: .value("分钟", point.total / 60), width: .ratio(0.6)).foregroundStyle(totalColor)
                    .accessibilityLabel(Text(point.date, format: period == .day ? .dateTime.hour() : .dateTime.month().day()))
                    .accessibilityValue("全部应用用时 \(DurationText.format(point.total))")
                BarMark(x: .value("时间", chartKey(point)), yStart: .value("起点", 0), yEnd: .value("所选应用和网站", point.scoped / 60), width: .ratio(0.6)).foregroundStyle(scopedColor)
                    .accessibilityLabel(Text(point.date, format: period == .day ? .dateTime.hour() : .dateTime.month().day()))
                    .accessibilityValue("所选应用和网站用时 \(DurationText.format(point.scoped))")
                if selectedPoint?.id == point.id {
                    RuleMark(x: .value("选中时间", chartKey(point)))
                        .foregroundStyle(Graphite.accent.opacity(0.45)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXScale(domain: report.trend.map(chartKey))
            .chartXAxis {
                AxisMarks(values: axisKeys) { value in
                    AxisValueLabel {
                        if let key = value.as(String.self), let point = report.trend.first(where: { chartKey($0) == key }) {
                            Text(point.date, format: period == .day ? .dateTime.hour() : .dateTime.month().day()).font(.system(size: 9))
                        }
                    }
                }
            }.chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            select(at: location, proxy: proxy, geometry: geometry)
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                select(at: location, proxy: proxy, geometry: geometry)
                            case .ended: selectedKey = nil
                            }
                        }
                }
            }
            .frame(height: 150)
            .onChange(of: period) { selectedKey = nil }
            .onChange(of: report.interval.start) { selectedKey = nil }
            Group {
                if let point = selectedPoint {
                    HStack(spacing: 6) {
                        Text(point.date, format: period == .day ? .dateTime.hour() : .dateTime.month().day())
                        Text("· 全部 \(DurationText.format(point.total)) · 合计 \(DurationText.format(point.scoped))")
                    }
                } else { Text("将指针移到柱形上，查看全部与合计用时") }
            }.font(.system(size: 10)).foregroundStyle(Graphite.muted).frame(minHeight: 15, alignment: .leading)
        }.graphiteCard()
    }

    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let frame = proxy.plotFrame, geometry[frame].contains(location) else { selectedKey = nil; return }
        selectedKey = proxy.value(atX: location.x - geometry[frame].minX, as: String.self)
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CategoryCard: View {
    let categories: [UsageCategory]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("时间花在哪里", "按应用用途归类")
            HStack(spacing: 18) {
                if categories.isEmpty { Circle().stroke(Graphite.line, lineWidth: 14).overlay(Text("暂无记录").font(.system(size: 11)).foregroundStyle(Graphite.muted)).frame(width: 140, height: 140) }
                else {
                    Chart(Array(categories.enumerated()), id: \.element.id) { index, category in
                        SectorMark(angle: .value("用时", category.seconds), innerRadius: .ratio(0.76), angularInset: 2).foregroundStyle(Graphite.categoryColor(category.name))
                    }.frame(width: 140, height: 140)
                        .overlay {
                            if let largest = categories.max(by: { $0.seconds < $1.seconds }) {
                                VStack(spacing: 5) {
                                    Text("最多时间").font(.system(size: 9)).foregroundStyle(Graphite.muted)
                                    Text(largest.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text("\(Int(largest.seconds / max(0.000001, categories.reduce(0) { $0 + $1.seconds }) * 100))%")
                                        .font(.system(size: 11)).foregroundStyle(Graphite.muted)
                                }.frame(width: 100)
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        HStack(spacing: 6) {
                            Circle().fill(Graphite.categoryColor(category.name)).frame(width: 5, height: 5)
                            Text(category.name).lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(Int(category.seconds / max(0.000001, categories.reduce(0) { $0 + $1.seconds }) * 100))%")
                        }.font(.system(size: 11)).foregroundStyle(Graphite.muted)
                    }
                }
            }.frame(height: 180)
        }.graphiteCard()
    }
}
