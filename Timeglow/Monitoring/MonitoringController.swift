import AppKit
import Observation
import CoreGraphics
import UserNotifications

@MainActor
@Observable
final class MonitoringController {
    private(set) var summary = UsageSummary()
    private(set) var currentApp = "等待前台活动"
    private(set) var currentDomain: String?
    private(set) var state = "正在记录"
    private(set) var isPaused = false
    private(set) var browserPermissions: [String: BrowserPermission] = [:]
    private(set) var preferences = MonitoringPreferences()
    private(set) var lastSaved: Date?
    var error: String?
    private(set) var additionalApplications: [AppIdentity] = []
    let permissions = PermissionServices()
    let databaseURL: URL
    let isVerification: Bool

    private var writer: SegmentWriter?
    private var reports: UsageReportRepository?
    private var reportChanges = ReportRevision()
    private var lastFlushRequested: Date?
    private var writeInFlight = false
    private var needsFlush = false
    private var needsDayReload = false
    private var durablePreferences = MonitoringPreferences()
    private var preferenceRevision: UInt64 = 0
    private var foregroundPID: pid_t?
    private var foregroundIdentity: AppIdentity?
    private var runningApplications: [AppIdentity] = []
    private(set) var availableApplications: [AppIdentity] = []
    private var dateKeyCache: (day: Date, calendar: Calendar, key: String)?
    private var engine = TrackingEngine(at: Date())
    private let browser = BrowserReader()
    private var timer: Timer?
    private var isStarted = false
    private let cadence = MonitoringCadence()
    private var lastSummaryRefresh: Date?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var sleeping = false
    private var screenAsleep = false
    private var sessionInactive = false
    private var screenLocked = false
    private var browserInFlight = false
    private var generation: UInt64 = 0
    private var lastBrowserRead = Date.distantPast
    private var lastTick = Date()
    private var lastUptime = ProcessInfo.processInfo.systemUptime
    private var dayCache = DailySegmentCache(day: Calendar.current.startOfDay(for: Date()))
    private var cacheLoaded = false
    private var previousScoped: Double?
    private var lastInputAt = Date()
    private var reminderDay: String = ""
    private var notificationsInFlight: Set<String> = []

    init() {
        #if DEBUG
        isVerification = true
        #else
        isVerification = ProcessInfo.processInfo.arguments.contains("--verify-monitoring")
        #endif
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Timeglow", isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains("--verify-monitoring") {
            databaseURL = root.appendingPathComponent("Verification/\(UUID().uuidString)/usage.sqlite")
        } else {
            databaseURL = isVerification ? root.appendingPathComponent("Development/usage.sqlite") : root.appendingPathComponent("usage.sqlite")
        }
        do {
            let opened = try SegmentStore(url: databaseURL)
            if let data = try opened.data(forKey: "preferences") {
                preferences = try JSONDecoder().decode(MonitoringPreferences.self, from: data)
            }
            if let data = try opened.data(forKey: "application-catalog") {
                additionalApplications = try JSONDecoder().decode([AppIdentity].self, from: data)
            }
            dayCache.apply(try opened.segments(from: dayCache.day, to: Date().addingTimeInterval(1)))
            cacheLoaded = true
            durablePreferences = preferences
            writer = SegmentWriter(store: opened)
            reports = try UsageReportRepository(url: databaseURL)
            refreshAvailableApplications(runningChanged: true)
        } catch { self.error = "无法打开本地记录：\(error.localizedDescription)" }
    }

    func start() {
        guard !isStarted, writer != nil else { return }
        isStarted = true
        engine = TrackingEngine(at: Date())
        let center = NSWorkspace.shared.notificationCenter
        observe(NotificationCenter.default, .NSCalendarDayChanged) { monitor in
            // A suspended collector has no timer, but the visible "today" quota
            // must still roll over at midnight without inventing any usage.
            let now = Date()
            monitor.flush(at: now)
            monitor.refreshSummary(at: now)
        }
        observe(center, NSWorkspace.didActivateApplicationNotification) { $0.foregroundChanged() }
        observe(center, NSWorkspace.didLaunchApplicationNotification) { $0.refreshAvailableApplications(runningChanged: true); $0.foregroundChanged(); $0.refreshBrowserPermissions() }
        observe(center, NSWorkspace.didTerminateApplicationNotification) { $0.refreshAvailableApplications(runningChanged: true); $0.foregroundChanged(); $0.refreshBrowserPermissions() }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { $0.refreshBrowserPermissions() }
        observe(center, NSWorkspace.willSleepNotification) { $0.sleeping = true; $0.reconcileSuspension() }
        observe(center, NSWorkspace.didWakeNotification) { $0.sleeping = false; $0.reconcileSuspension() }
        observe(center, NSWorkspace.screensDidSleepNotification) { $0.screenAsleep = true; $0.reconcileSuspension() }
        observe(center, NSWorkspace.screensDidWakeNotification) { $0.screenAsleep = false; $0.reconcileSuspension() }
        observe(center, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true; $0.reconcileSuspension() }
        observe(center, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false; $0.reconcileSuspension() }
        // Workspace notifications cover sleep/session changes; these observed system
        // notifications supplement screen locking. Their OS behavior needs a live lock test.
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.screenLocked = locked; self?.reconcileSuspension() }
            })
        }
        foregroundChanged()
        tick()
        updateTimer()
        refreshBrowserPermissions()
        Task { await permissions.refresh() }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        timer?.invalidate()
        timer = nil
        engine.suspend(at: Date())
        flush(at: Date(), force: true)
        writer?.drain()
        for (center, token) in observers { center.removeObserver(token) }
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
        observers.removeAll()
        distributedObservers.removeAll()
        generation &+= 1
    }

    func togglePause() {
        isPaused.toggle()
        reconcileSuspension()
    }

    private func refreshAvailableApplications(runningChanged: Bool = false) {
        if runningChanged {
            runningApplications = NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
                return .init(bundleID: id, name: app.localizedName ?? id)
            }
        }
        var apps = Dictionary(uniqueKeysWithValues: additionalApplications.map { ($0.bundleID, $0) })
        for row in dayCache.segments where row.kind == .application { apps[row.value] = .init(bundleID: row.value, name: row.label) }
        for app in runningApplications { apps[app.bundleID] = app }
        let values = apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if availableApplications != values { availableApplications = values }
    }

    func addApplications(_ values: [AppIdentity]) {
        guard let writer else { return }
        var apps = Dictionary(uniqueKeysWithValues: additionalApplications.map { ($0.bundleID, $0) })
        for app in values { apps[app.bundleID] = app }
        let catalog = Array(apps.values)
        let previousCatalog = additionalApplications
        writer.enqueue({ try $0.setData(JSONEncoder().encode(catalog), forKey: "application-catalog") }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                var value = self.preferences
                value.selectedApps.formUnion(values.map(\.bundleID))
                self.updatePreferences(value)
            case .failure(let error):
                if self.additionalApplications == catalog { self.additionalApplications = previousCatalog; self.refreshAvailableApplications() }
                self.error = "应用选择未保存：\(error.localizedDescription)"
            }
        }
        additionalApplications = catalog
        refreshAvailableApplications()
    }

    func addWebsite(_ domain: String) {
        var value = preferences
        guard value.addWebsite(domain) else { error = "请输入有效的域名或 http/https 网址。"; return }
        updatePreferences(value)
    }

    func updatePreferences(_ value: MonitoringPreferences, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard let writer else { error = "本地记录尚未打开，设置未保存。"; completion?(false); return }
        guard (1...1440).contains(value.quotaMinutes), value.idleSeconds >= 0,
              (1...300).contains(value.warningPercent), (1...300).contains(value.spentPercent), value.warningPercent < value.spentPercent,
              ["minutes", "percent"].contains(value.reminderKind), !value.message.isEmpty, value.message.count <= 80,
              value.percentThresholds.allSatisfy({ (1...300).contains($0) }), value.minuteThresholds.allSatisfy({ (1...1440).contains($0) }) else {
            error = "请检查每日合计用时限额、状态分界和提醒节点的范围。"; completion?(false); return
        }
        preferenceRevision &+= 1
        let revision = preferenceRevision
        let quotaKey = dayKey(at: Date())
        writer.enqueue({ try $0.savePreferences(value, quotaKey: "quota:" + quotaKey) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.durablePreferences = value
                completion?(true)
            case .failure(let error):
                if revision == self.preferenceRevision { self.applyPreferences(self.durablePreferences) }
                self.error = "设置未保存：\(error.localizedDescription)"
                completion?(false)
            }
        }
        applyPreferences(value)
    }

    private func applyPreferences(_ value: MonitoringPreferences) {
        preferences = value
        error = nil
        generation &+= 1
        currentDomain = nil
        if let bundle = engine.application?.bundleID { engine.setWebsite(nil, browser: bundle, at: Date()) }
        previousScoped = nil
        refreshSummary(at: Date())
        tick()
    }

    private func dayKey(at date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        if let cached = dateKeyCache, cached.day == day, cached.calendar == calendar { return cached.key }
        let key = ISO8601DateFormatter.string(from: day, timeZone: calendar.timeZone, formatOptions: [.withFullDate])
        dateKeyCache = (day, calendar, key)
        return key
    }

    private func refreshBrowserPermissions() {
        for bundleID in BrowserReader.supported.keys {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                if browserPermissions[bundleID] != .notRunning { browserPermissions[bundleID] = .notRunning }
                continue
            }
            let pid = app.processIdentifier
            browser.checkPermission(pid: pid) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier == pid else { return }
                    if self.browserPermissions[bundleID] != result { self.browserPermissions[bundleID] = result }
                }
            }
        }
    }

    func requestBrowserPermission(_ bundleID: String) {
        guard BrowserReader.supported[bundleID] != nil else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            browserPermissions[bundleID] = .notRunning; return
        }
        browser.requestPermission(pid: app.processIdentifier) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.browserPermissions[bundleID] = result

            }
        }
    }

    func reportRefreshKey(period: ReportPeriod, anchor: Date?) -> ReportRefreshKey {
        let now = Date(), calendar = Calendar.current
        let interval = period.interval(anchor: anchor ?? now, firstRecord: .distantPast, now: now, calendar: calendar)
        return .init(period: period, anchor: period == .all ? nil : interval.start,
                     revision: reportChanges.version(in: interval), scope: ReportScope(preferences),
                     today: calendar.startOfDay(for: now), calendar: calendar)
    }

    func report(period: ReportPeriod, anchor: Date) async throws -> UsageReport {
        guard let reports else { throw SegmentStore.StoreError(message: "本地记录尚未打开。") }
        let now = Date()
        return try await reports.load(period: period, anchor: anchor, now: now,
            preferences: preferences, checkpoint: engine.checkpoint(at: now), revisions: reportChanges.days)
    }

    private func updateTimer() {
        guard isStarted, !engine.isSuspended else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        lastTick = Date()
        lastUptime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Keep the existing one-second idle/resume detection accuracy. Expensive
        // aggregation and I/O have their own cadence, and do not run while idle.
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor (MonitoringController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    private func reconcileSuspension() {
        let now = Date()
        if isPaused || sleeping || screenAsleep || sessionInactive || screenLocked {
            engine.suspend(at: now)
            currentDomain = nil
            generation &+= 1
        } else {
            engine.resume(at: now)
            foregroundChanged()
        }
        updateTimer()
        if sleeping || screenAsleep || sessionInactive || screenLocked {
            flush(at: now, force: true)
            writer?.drain()
        } else { flush(at: now) }
        refreshSummary(at: now)
        refreshState()
    }

    private func foregroundChanged() {
        guard !engine.isSuspended, !engine.isIdle else { return }
        applyForeground(NSWorkspace.shared.frontmostApplication, force: true)
    }

    private func applyForeground(_ running: NSRunningApplication?, force: Bool) {
        guard !engine.isSuspended, !engine.isIdle else { return }
        let pid = running?.processIdentifier
        let identity: AppIdentity?
        if !force, pid == foregroundPID { identity = foregroundIdentity }
        else {
            identity = running.flatMap { app -> AppIdentity? in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
                return .init(bundleID: id, name: app.localizedName ?? id)
            }
            foregroundPID = pid
            foregroundIdentity = identity
        }
        guard identity != engine.application else { return }
        generation &+= 1
        currentDomain = nil
        engine.setApplication(identity, at: Date())
        refreshAvailableApplications()
        let name = identity?.name ?? "无前台应用"
        if currentApp != name { currentApp = name }
        flush(at: Date())
        refreshSummary(at: Date())
    }

    private func tick() {
        guard isStarted, !engine.isSuspended else { return }
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        if abs(now.timeIntervalSince(lastTick) - (uptime - lastUptime)) > 3 || now.timeIntervalSince(lastTick) > 15 {
            // Stop at the last observed time when timers were suspended or the wall clock changed.
            engine.suspend(at: lastTick)
            generation &+= 1
            if !isPaused && !sleeping && !screenAsleep && !sessionInactive && !screenLocked { engine.resume(at: now) }
        }
        lastTick = now
        lastUptime = uptime
        let eventType = CGEventType(rawValue: UInt32.max)!
        let seconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: eventType)
        lastInputAt = seconds.isFinite && seconds >= 0 ? now.addingTimeInterval(-seconds) : now
        let wasIdle = engine.isIdle
        engine.samplePresence(secondsSinceInput: seconds, idleAfter: preferences.idleSeconds, at: now)
        if wasIdle != engine.isIdle {
            generation &+= 1
            if currentDomain != nil { currentDomain = nil }
            flush(at: now)
            refreshSummary(at: now)
            refreshState()
        }
        // Idle keeps only the cheap input query above, so resumption accuracy
        // is unchanged. It does not repeatedly write the DB or rebuild views.
        guard !engine.isIdle else { return }
        let running = NSWorkspace.shared.frontmostApplication
        applyForeground(running, force: false)
        if lastFlushRequested == nil || now.timeIntervalSince(lastFlushRequested!) >= 5 { flush(at: now) }
        if cadence.shouldRefresh(last: lastSummaryRefresh, at: now, idle: false, suspended: false) { refreshSummary(at: now) }
        refreshState()
        readBrowserIfNeeded(at: now, running: running)
    }

    private func readBrowserIfNeeded(at now: Date, running: NSRunningApplication?) {
        guard !engine.isSuspended, !engine.isIdle, !browserInFlight, now.timeIntervalSince(lastBrowserRead) >= 2,
              let app = running, let bundle = foregroundIdentity?.bundleID,
              engine.application?.bundleID == bundle, preferences.enabledBrowsers.contains(bundle), BrowserReader.supported[bundle] != nil else { return }
        browserInFlight = true
        lastBrowserRead = now
        let token = generation, pid = app.processIdentifier
        browser.read(pid: pid, bundleID: bundle) { [weak self] context in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.browserInFlight = false
                if self.browserPermissions[bundle] != context.permission { self.browserPermissions[bundle] = context.permission }
                guard self.generation == token, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      self.preferences.enabledBrowsers.contains(bundle), !self.engine.isSuspended, !self.engine.isIdle else { return }
                self.engine.setWebsite(context.domain, browser: bundle, at: Date())
                if self.currentDomain != context.domain {
                    self.currentDomain = context.domain
                    self.flush(at: Date())
                    self.refreshSummary(at: Date())
                }
            }
        }
    }

    private func flush(at now: Date, force: Bool = false) {
        guard let writer else { return }
        let checkpoint = engine.checkpoint(at: now)
        let today = Calendar.current.startOfDay(for: now)
        if !cacheLoaded || dayCache.day != today {
            dayCache = DailySegmentCache(day: today)
            cacheLoaded = true
            needsDayReload = true
        }
        dayCache.apply(checkpoint)
        reportChanges.record(checkpoint, calendar: .current)
        if writeInFlight && !force { needsFlush = true; return }
        let reload = needsDayReload
        needsDayReload = false
        writeInFlight = true
        lastFlushRequested = now
        let quotaKey = "quota:" + dayKey(at: now), quota = preferences.quotaMinutes
        writer.enqueue({ store -> [TrackingSegment]? in
            try store.upsert(checkpoint)
            try store.ensureQuota(quota, forKey: quotaKey)
            return reload ? try store.segments(from: today, to: now.addingTimeInterval(1)) : nil
        }) { [weak self] result in
            guard let self else { return }
            self.writeInFlight = false
            switch result {
            case .success(let loaded):
                self.engine.acknowledgeSaved(checkpoint)
                self.lastSaved = now
                if let loaded, self.dayCache.day == today {
                    let newer = self.dayCache.segments
                    self.dayCache.apply(loaded)
                    self.dayCache.apply(newer)
                    self.dayCache.apply(self.engine.checkpoint(at: Date()))
                    self.refreshAvailableApplications()
                    self.refreshSummary(at: Date())
                }
            case .failure(let error):
                if reload { self.needsDayReload = true }
                self.lastFlushRequested = nil
                self.error = "本地记录未能保存：\(error.localizedDescription)"
            }
            if self.needsFlush && self.isStarted {
                self.needsFlush = false
                self.flush(at: Date())
            }
        }
    }

    private func refreshSummary(at now: Date) {
        let today = Calendar.current.startOfDay(for: now)
        if !cacheLoaded || today != dayCache.day { flush(at: now) }
        var rows = Dictionary(uniqueKeysWithValues: dayCache.segments.map { ($0.id, $0) })
        for row in engine.checkpoint(at: now) { rows[row.id] = row }
        // Confirmed input truncates just the provisional presence cursor. Share
        // the expensive grouping/intersections with the live display summary.
        let confirmed = engine.checkpoint(at: now, confirmedThrough: preferences.idleSeconds > 0 ? lastInputAt : nil)
        let ends = Dictionary(uniqueKeysWithValues: confirmed.filter { $0.kind == .presence }.map { ($0.id, $0.end) })
        let calculation = UsageCalculator.calculate(Array(rows.values), from: today, to: now, preferences: preferences, confirmedPresenceEnds: ends)
        if summary != calculation.summary { summary = calculation.summary }
        lastSummaryRefresh = now
        let confirmedScoped = calculation.confirmedScopedSeconds
        let day = dayKey(at: now)
        if reminderDay != day { reminderDay = day; previousScoped = nil }
        if let previousScoped { sendReminders(previous: previousScoped, current: confirmedScoped, day: day) }
        previousScoped = confirmedScoped
    }

    private func sendReminders(previous: Double, current: Double, day: String) {
        guard permissions.notificationStatus == .authorized, !ProcessInfo.processInfo.arguments.contains("--verify-monitoring") else { return }
        for node in ReminderRules.crossed(previous: previous, current: current, preferences: preferences) {
            let key = "\(day):\(preferences.reminderKind):\(node)"
            guard !notificationsInFlight.contains(key) else { continue }
            guard let writer else { continue }
            notificationsInFlight.insert(key)
            let title = preferences.reminderKind == "percent" ? "今天合计已用每日限额的 \(node)%" : "今天合计已用 \(node) 分钟"
            let message = preferences.message
            let context = ReminderContext(day: day, kind: preferences.reminderKind == "percent" ? .percent : .minutes,
                                          node: node, quotaMinutes: preferences.quotaMinutes,
                                          scopedSeconds: current, triggeredAt: Date(), message: message)
            writer.enqueue({ try $0.claimReminder(key) }) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(true):
                    Task {
                        defer { self.notificationsInFlight.remove(key) }
                        do { try await self.permissions.send(identifier: key, title: title, body: message, reminder: context) }
                        catch {
                            writer.enqueue({ try $0.releaseReminder(key) }) { _ in }
                            self.error = "提醒未发送：\(error.localizedDescription)"
                        }
                    }
                case .success(false): self.notificationsInFlight.remove(key)
                case .failure(let error):
                    self.notificationsInFlight.remove(key)
                    self.error = "提醒状态未保存：\(error.localizedDescription)"
                }
            }
        }
    }

    private func refreshState() {
        let value: String
        if isPaused { value = "已暂停" }
        else if engine.isSuspended { value = "屏幕或会话已离开，暂停计时" }
        else if engine.isIdle { value = "电脑闲置，暂停计时" }
        else { value = "正在记录" }
        if state != value { state = value }
    }
}
