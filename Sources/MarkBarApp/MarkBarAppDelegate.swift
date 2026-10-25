import AppKit
import Foundation
import MarkBarCore
import ServiceManagement
@preconcurrency import UserNotifications

private final class TideNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onPresent: (@Sendable (String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        onPresent?(notification.request.identifier)
        completionHandler([.banner, .sound])
    }
}

@MainActor
final class MarkBarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var catalogueClient: MarketDataClient
    private var detailsClient: MarketDataClient
    private let quoteSession = MainQuoteSession()
    private var quoteUpdatesTask: Task<Void, Never>?
    private var quoteSnapshot = MainQuoteSnapshot(revision: 0, phase: .stopped,
                                                   entries: [:], observedAt: Date())
    private var lastQuoteRenderAt = Date.distantPast
    private var alertContinuityEpochs: [String: UInt64] = [:]
    private let defaults = UserDefaults.standard
    private var preferences: TidePreferences
    private var sourceProfiles: [String: TidePreferences] = [:]
    private let settingsModel: TideSettingsModel
    private var settingsWindow: TideSettingsWindowController?
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var contractItems: [Contract: NSMenuItem] = [:]
    private var marketDetailItems: [Contract: NSMenuItem] = [:]
    private var timeItems: [Contract: NSMenuItem] = [:]
    private var errorItems: [Contract: NSMenuItem] = [:]
    private let quoteStatusItem = NSMenuItem(title: "行情状态", action: nil, keyEquivalent: "")
    private let sourceItem = NSMenuItem(title: "行情来源…", action: nil, keyEquivalent: ",")
    private let alertsItem = NSMenuItem(title: "到价提醒…", action: nil, keyEquivalent: "3")
    private let externalDisplayItem = NSMenuItem(title: "外部显示…", action: nil, keyEquivalent: "")
    private let recentAlertItem = NSMenuItem(title: "最近提醒", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "立即刷新", action: nil, keyEquivalent: "r")
    private let applicationRefreshItem = NSMenuItem(title: "立即刷新", action: nil, keyEquivalent: "r")
    private let updateAvailableItem = NSMenuItem(title: "发现新版本", action: nil, keyEquivalent: "")
    private let checkUpdatesItem = NSMenuItem(title: "检查更新…", action: nil, keyEquivalent: "")
    private let applicationCheckUpdatesItem = NSMenuItem(title: "检查更新…", action: nil, keyEquivalent: "")
    private let aboutItem = NSMenuItem(title: "关于 TideTicker", action: nil, keyEquivalent: "")
    private let applicationAboutItem = NSMenuItem(title: "关于 TideTicker", action: nil, keyEquivalent: "")
    private var statusRows: [CompactStatusImage.Row] = []
    private var details: [Contract: MarketDetails] = [:]
    private var referenceSpots: [Contract: MarkQuote] = [:]
    private var detailsTasks: [Contract: Task<Void, Never>] = [:]
    private var nextDetailsRefresh: [Contract: Date] = [:]
    private var catalogueTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var catalogueGeneration: UInt64 = 0
    private var connectionGeneration: UInt64 = 0
    private var sleeping = false
    private var resuming = false
    private var terminating = false
    private let loginMonitor = LoginItemMonitor(service: SystemLoginItemService())
    private var alertEngine = PriceAlertEngine()
    private let notificationDelegate = TideNotificationDelegate()
    private var updateController: TideUpdateController?
    private let kindleController: TideKindleController
    private var updateMenuState: TideUpdateMenuState = .idle
    private var notificationAuthorizationStatus: UNAuthorizationStatus?
    private var lastPresentedNotificationID: String?
    private let snapshotURL: URL?
    private let preferencesURL: URL?
    private let suppressDefaultLoginRegistration: Bool
    private static let preferencesKey = "tide.preferences.v1"
    private static let profilesKey = "tide.sourceProfiles.v1"
    private static let loginConfiguredKey = "didAttemptDefaultLoginRegistration"
    private static let symbolStyleKey = "showCoinIcons"
    private var showsCoinIcons: Bool { defaults.bool(forKey: Self.symbolStyleKey) }

    private let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "HH:mm:ss"; return f
    }()
    private let fullDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"; return f
    }()

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
        func pathArgument(_ key: String) -> URL? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: arguments[index + 1])
        }
        snapshotURL = pathArgument("--ui-snapshot")
        preferencesURL = pathArgument("--preferences-file")
        suppressDefaultLoginRegistration = arguments.contains("--skip-default-login-registration") || preferencesURL != nil
        let data = preferencesURL.flatMap { try? Data(contentsOf: $0) } ?? (preferencesURL == nil ? UserDefaults.standard.data(forKey: Self.preferencesKey) : nil)
        let decoded = data.flatMap { try? JSONDecoder().decode(TidePreferences.self, from: $0) }
        var loaded = decoded ?? .default
        loaded.normalize()
        preferences = loaded
        catalogueClient = MarketDataClient(networkMode: loaded.networkMode)
        detailsClient = MarketDataClient(networkMode: loaded.networkMode)
        settingsModel = TideSettingsModel(preferences: loaded)
        kindleController = TideKindleController(defaults: .standard)
        let profileData = preferencesURL.flatMap { try? Data(contentsOf: $0.appendingPathExtension("profiles.json")) }
            ?? (preferencesURL == nil ? UserDefaults.standard.data(forKey: Self.profilesKey) : nil)
        sourceProfiles = profileData.flatMap { try? JSONDecoder().decode([String: TidePreferences].self, from: $0) } ?? [:]
        super.init()
        if data != nil && decoded == nil {
            settingsModel.setMessage("设置文件无法读取，暂用默认 BTC / ETH；保存设置后会替换损坏的配置。", kind: .error)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureSettingsCallbacks()
        buildMenu()
        buildApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.menu = menu
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.imageScaling = .scaleNone
        configureUpdateController()
        registerWorkspaceNotifications()
        loginMonitor.onChange = { [weak self] in
            guard let self, !self.terminating else { return }
            self.renderLoginItem()
            self.writeSnapshot(now: Date())
        }
        configureDefaultLoginItem()
        if Bundle.main.bundleURL.pathExtension == "app" {
            notificationDelegate.onPresent = { [weak self] identifier in
                Task { @MainActor [weak self] in
                    self?.lastPresentedNotificationID = identifier
                    self?.writeSnapshot(now: Date())
                }
            }
            UNUserNotificationCenter.current().delegate = notificationDelegate
            updateNotificationStatus()
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        startQuoteUpdates()
        reconcileQuoteSession()
        kindleController.startIfEnabled()
        if ProcessInfo.processInfo.arguments.contains("--show-settings") { showSettings() }
        if ProcessInfo.processInfo.arguments.contains("--show-main-window") { showMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        loginMonitor.refreshIfNeeded(force: true)
        updateNotificationStatus()
        updateController?.checkIfDue()
    }

    private func configureSettingsCallbacks() {
        settingsModel.onChange = { [weak self] updated in self?.applyPreferences(updated) }
        settingsModel.onSelectExchange = { [weak self] exchange in self?.loadCatalogue(exchange: exchange, switchSource: true) }
        settingsModel.onReloadCatalog = { [weak self] in
            guard let self else { return }
            self.loadCatalogue(exchange: self.preferences.exchange, forceReload: true)
        }
        settingsModel.onTestConnection = { [weak self] in self?.testConnection() }
        settingsModel.onRequestNotifications = { [weak self] in self?.requestNotifications() }
        settingsModel.onOpenNotificationSettings = { [weak self] in self?.openNotificationSettings() }
        settingsModel.onRefresh = { [weak self] in self?.refreshNow() }
        settingsModel.onAcknowledgeAlert = { [weak self] id in self?.acknowledgeAlert(id) }
        settingsModel.onSetCoinIcons = { [weak self] enabled in self?.setCoinIcons(enabled) }
        settingsModel.onSetAutomaticChecks = { [weak self] enabled in self?.setAutomaticUpdateChecks(enabled) }
        settingsModel.onSetLoginItem = { [weak self] enabled in self?.setLoginItemEnabled(enabled) }
        settingsModel.onOpenLoginSettings = { [weak self] in self?.openLoginSettings() }
        settingsModel.onCheckForUpdates = { [weak self] in self?.checkForUpdates() }
        kindleController.configureCallbacks()
    }

    private func buildMenu() {
        // Reused items may currently belong to a nested menu retained by AppKit.
        for item in [refreshItem, quoteStatusItem, recentAlertItem, sourceItem, alertsItem, externalDisplayItem,
                     updateAvailableItem, checkUpdatesItem, aboutItem] {
            item.menu?.removeItem(item)
        }
        menu.removeAllItems()
        contractItems.removeAll(); marketDetailItems.removeAll(); timeItems.removeAll(); errorItems.removeAll()
        menu.autoenablesItems = false
        menu.delegate = self
        addAction("显示主窗口", symbol: "macwindow", action: #selector(showMainWindow), key: "1")
        menu.addItem(.separator())
        let pinnedContracts = preferences.pinnedContracts
        let pinnedIDs = Set(pinnedContracts.map(\.id))
        let remainingContracts = preferences.watchlist.filter { !pinnedIDs.contains($0.id) }
        let headingDetail = preferences.watchlist.isEmpty
            ? "尚未关注品种"
            : "\(preferences.watchlist.count) 个关注 · \(pinnedContracts.count) 条常驻"
        TideMenuStyle.setStacked(addLabel("关注行情"), title: "关注行情 · \(preferences.exchange.title)",
                                 detail: headingDetail, heading: true)
        if preferences.watchlist.isEmpty {
            addAction("添加第一个关注品种…", symbol: "plus.circle", action: #selector(showWatchlist))
        }
        for contract in pinnedContracts {
            addQuoteItem(for: contract, to: menu)
        }
        if !remainingContracts.isEmpty {
            let remainingMenu = NSMenu(title: pinnedContracts.isEmpty ? "全部关注品种" : "其他关注品种")
            remainingMenu.autoenablesItems = false
            let remainingItem = NSMenuItem(title: remainingMenu.title, action: nil, keyEquivalent: "")
            remainingItem.image = TideMenuStyle.icon("list.bullet")
            remainingItem.submenu = remainingMenu
            TideMenuStyle.setColumns(remainingItem, remainingMenu.title,
                                     "\(remainingContracts.count) 个", muted: true)
            menu.addItem(remainingItem)
            for contract in remainingContracts {
                addQuoteItem(for: contract, to: remainingMenu)
            }
        }
        quoteStatusItem.action = #selector(showSource); quoteStatusItem.target = self
        menu.addItem(quoteStatusItem)
        recentAlertItem.action = #selector(showAlerts); recentAlertItem.target = self
        menu.addItem(recentAlertItem)
        menu.addItem(.separator())
        configureAction(refreshItem, symbol: "arrow.clockwise", action: #selector(refreshNow)); menu.addItem(refreshItem)
        addAction("管理关注品种…", symbol: "star", action: #selector(showWatchlist), key: "2")
        configureAction(alertsItem, symbol: "bell", action: #selector(showAlerts)); menu.addItem(alertsItem)
        configureAction(sourceItem, symbol: "slider.horizontal.3", action: #selector(showSource)); menu.addItem(sourceItem)
        configureAction(externalDisplayItem, symbol: "display.2", action: #selector(showExternalDisplay))
        menu.addItem(externalDisplayItem)
        menu.addItem(.separator())
        addAction("高级设置…", symbol: "gearshape", action: #selector(showAdvancedSettings))
        menu.addItem(.separator())
        configureAction(updateAvailableItem, symbol: "arrow.down.circle.fill", action: #selector(showAvailableUpdate))
        menu.addItem(updateAvailableItem)
        configureAction(checkUpdatesItem, symbol: "arrow.triangle.2.circlepath", action: #selector(checkForUpdates))
        menu.addItem(checkUpdatesItem)
        configureAction(aboutItem, symbol: "info.circle", action: #selector(showAboutPanel))
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        addAction("退出 TideTicker", symbol: "rectangle.portrait.and.arrow.right", action: #selector(quitApp), key: "q")
        renderUpdateItems()
    }

    private func configureAction(_ item: NSMenuItem, symbol: String, action: Selector) {
        item.action = action; item.target = self; item.image = TideMenuStyle.icon(symbol)
    }

    @discardableResult private func addAction(_ title: String, symbol: String, action: Selector,
                                              key: String = "", to parent: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        configureAction(item, symbol: symbol, action: action)
        (parent ?? menu).addItem(item)
        return item
    }

    @discardableResult private func addLabel(_ title: String, indented: Bool = false, to parent: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indented ? 1 : 0
        (parent ?? menu).addItem(item)
        return item
    }

    private func addQuoteItem(for contract: Contract, to parent: NSMenu) {
        let price = NSMenuItem(title: contract.symbol, action: nil, keyEquivalent: "")
        price.image = TideCoinIcon.image(for: contract.symbol, size: 18)
        parent.addItem(price)
        contractItems[contract] = price

        let detailMenu = NSMenu(title: contract.symbol)
        detailMenu.autoenablesItems = false
        price.submenu = detailMenu
        addLabel("\(contract.displayTitle) · \(contract.priceTitle)", to: detailMenu)
        marketDetailItems[contract] = addLabel("补充行情等待加载", to: detailMenu)
        marketDetailItems[contract]?.isHidden = true
        timeItems[contract] = addLabel("等待首个报价", to: detailMenu)
        errorItems[contract] = addLabel("", to: detailMenu)
        errorItems[contract]?.isHidden = true
        detailMenu.addItem(.separator())
        addAction("查看行情概览", symbol: "square.grid.2x2", action: #selector(showOverview), to: detailMenu)
        addAction("管理关注品种…", symbol: "star", action: #selector(showWatchlist), to: detailMenu)
    }

    private func buildApplicationMenu() {
        let main = NSMenu()
        let app = NSMenu(title: "TideTicker")
        let appItem = NSMenuItem(); appItem.submenu = app; main.addItem(appItem)
        configureAction(applicationAboutItem, symbol: "info.circle", action: #selector(showAboutPanel))
        app.addItem(applicationAboutItem)
        configureAction(applicationCheckUpdatesItem, symbol: "arrow.triangle.2.circlepath", action: #selector(checkForUpdates))
        app.addItem(applicationCheckUpdatesItem)
        app.addItem(.separator())
        addAction("显示主窗口", symbol: "macwindow", action: #selector(showMainWindow), key: "1", to: app)
        addAction("管理关注品种…", symbol: "star", action: #selector(showWatchlist), key: "2", to: app)
        addAction("到价提醒…", symbol: "bell", action: #selector(showAlerts), key: "3", to: app)
        addAction("行情来源…", symbol: "slider.horizontal.3", action: #selector(showSource), key: ",", to: app)
        addAction("外部显示…", symbol: "display.2", action: #selector(showExternalDisplay), to: app)
        addAction("高级设置…", symbol: "gearshape", action: #selector(showAdvancedSettings), to: app)
        app.addItem(.separator())
        configureAction(applicationRefreshItem, symbol: "arrow.clockwise", action: #selector(refreshNow))
        app.addItem(applicationRefreshItem)
        app.autoenablesItems = false
        app.addItem(.separator())
        addAction("退出 TideTicker", symbol: "rectangle.portrait.and.arrow.right", action: #selector(quitApp), key: "q", to: app)
        // Expose the same quote menu while the main window is foreground, too.
        let market = NSMenuItem(title: "行情", action: nil, keyEquivalent: "")
        market.submenu = menu
        main.addItem(market)
        let edit = NSMenu(title: "编辑")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        let window = NSMenu(title: "窗口")
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); windowItem.submenu = window; main.addItem(windowItem)
        window.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        NSApplication.shared.mainMenu = main
        NSApplication.shared.windowsMenu = window
        renderUpdateItems()
    }

    private func configureUpdateController() {
        let arguments = ProcessInfo.processInfo.arguments
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let versionString = shortVersion, let currentVersion = AppVersion(versionString) else {
            checkUpdatesItem.isEnabled = false
            applicationCheckUpdatesItem.isEnabled = false
            return
        }
        func argument(after key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let fixtureVersion = argument(after: "--update-fixture-version").flatMap(AppVersion.init)
        let fetcher: any ReleaseUpdateFetching
        if let fixtureVersion {
            let tag = "v\(fixtureVersion)"
            let release = AppRelease(
                version: fixtureVersion,
                tagName: tag,
                title: "TideTicker \(fixtureVersion)",
                publishedAt: Date(),
                releaseURL: URL(string: "https://github.com/realRongCat/TideTicker/releases/tag/\(tag)")!
            )
            fetcher = TideStaticReleaseFetcher(release: release)
        } else {
            fetcher = GitHubReleaseClient(appVersion: versionString)
        }
        let automaticAllowed = fixtureVersion != nil || (
            Bundle.main.bundleURL.pathExtension == "app"
                && preferencesURL == nil
                && !arguments.contains("--disable-update-checks")
        )
        let controller = TideUpdateController(
            currentVersion: currentVersion,
            fetcher: fetcher,
            defaults: defaults,
            automaticChecksAllowed: automaticAllowed,
            stateStore: fixtureVersion == nil ? nil : TideVolatileUpdateStateStore(),
            anchor: { [weak self] in self?.statusItem }
        )
        controller.onMenuStateChange = { [weak self] state in
            guard let self else { return }
            self.updateMenuState = state
            self.renderUpdateItems()
            self.writeSnapshot(now: Date())
        }
        controller.onAutomaticChecksChange = { [weak self] _ in self?.renderUpdateItems() }
        updateController = controller
        renderUpdateItems()
        controller.start()
        if fixtureVersion != nil { controller.checkNow() }
    }

    private func renderUpdateItems() {
        syncAdvancedSettings()
        switch updateMenuState {
        case .idle:
            updateAvailableItem.isHidden = true
            checkUpdatesItem.title = "检查更新…"
            applicationCheckUpdatesItem.title = "检查更新…"
            checkUpdatesItem.isEnabled = updateController != nil
            applicationCheckUpdatesItem.isEnabled = updateController != nil
        case .checking:
            updateAvailableItem.isHidden = true
            checkUpdatesItem.title = "正在检查更新…"
            applicationCheckUpdatesItem.title = "正在检查更新…"
            checkUpdatesItem.isEnabled = false
            applicationCheckUpdatesItem.isEnabled = false
        case let .available(release):
            updateAvailableItem.title = "发现新版本 \(release.version)…"
            updateAvailableItem.isHidden = false
            updateAvailableItem.isEnabled = true
            checkUpdatesItem.title = "再次检查更新…"
            applicationCheckUpdatesItem.title = "再次检查更新…"
            checkUpdatesItem.isEnabled = true
            applicationCheckUpdatesItem.isEnabled = true
        }
    }

    private func applyPreferences(_ proposed: TidePreferences) {
        var updated = proposed
        updated.normalize()
        guard updated.exchange == preferences.exchange else {
            loadCatalogue(exchange: updated.exchange, switchSource: true)
            settingsModel.preferences = preferences
            return
        }
        let old = preferences
        guard old != updated else { settingsModel.preferences = preferences; return }
        let networkChanged = old.networkMode != updated.networkMode
        if networkChanged { replaceNetworkClients(mode: updated.networkMode) }
        let removed = Set(old.watchlist).subtracting(updated.watchlist)
        for contract in removed {
            detailsTasks.removeValue(forKey: contract)?.cancel()
            nextDetailsRefresh.removeValue(forKey: contract)
            details.removeValue(forKey: contract)
            referenceSpots.removeValue(forKey: contract)
            alertContinuityEpochs.removeValue(forKey: contract.id)
        }
        preferences = updated
        if old.showsMarketDetails && !updated.showsMarketDetails {
            for task in detailsTasks.values { task.cancel() }
            detailsTasks.removeAll()
            nextDetailsRefresh.removeAll()
            details.removeAll()
            referenceSpots.removeAll()
        }
        if old.alerts != updated.alerts || old.watchlist != updated.watchlist { alertEngine.reset() }
        if old.refreshInterval != updated.refreshInterval { alertEngine.reset() }
        savePreferences()
        settingsModel.preferences = preferences
        buildMenu()
        reconcileQuoteSession()
        refreshDetailsIfNeeded()
        if networkChanged {
            settingsModel.setMessage(
                sleeping ? "已选择\(updated.networkMode.title)，将在唤醒后重新连接。" : "已选择\(updated.networkMode.title)，正在重新连接…",
                kind: sleeping ? .info : .loading
            )
            loadCatalogue(exchange: preferences.exchange, forceReload: true)
        }
    }

    /// The route is immutable within a client. Old cancellation and callbacks
    /// only touch old instances; a fast second switch cannot cancel new work.
    private func replaceNetworkClients(mode: NetworkMode) {
        generation &+= 1
        catalogueGeneration &+= 1
        resumeTask?.cancel(); resumeTask = nil
        cancelMarketTasks()
        catalogueTask?.cancel(); catalogueTask = nil
        settingsModel.catalogLoading = false
        settingsModel.connectionTesting = false
        settingsModel.connectionDiagnostic = nil
        let oldCatalogueClient = catalogueClient, oldDetailsClient = detailsClient
        let priorCancellation = cancellationTask
        catalogueClient = MarketDataClient(networkMode: mode)
        detailsClient = MarketDataClient(networkMode: mode)
        cancellationTask = Task {
            await priorCancellation?.value
            await oldCatalogueClient.cancelAll()
            await oldDetailsClient.cancelAll()
        }
        // Same contracts and price basis: retain the last known quotes and
        // errors, but establish a new crossing baseline on the new route.
        alertEngine.reset()
        alertContinuityEpochs.removeAll()
        nextDetailsRefresh.removeAll()
        if !sleeping { resuming = false }
    }

    private func savePreferences() {
        sourceProfiles[preferences.exchange.rawValue] = preferences
        do {
            let data = try JSONEncoder().encode(preferences)
            let profiles = try JSONEncoder().encode(sourceProfiles)
            if let preferencesURL {
                try data.write(to: preferencesURL, options: .atomic)
                try profiles.write(to: preferencesURL.appendingPathExtension("profiles.json"), options: .atomic)
            } else {
                defaults.set(data, forKey: Self.preferencesKey)
                defaults.set(profiles, forKey: Self.profilesKey)
            }
        } catch { settingsModel.setMessage("保存设置失败：\(error.localizedDescription)", kind: .error) }
    }

    private func tick() {
        if !sleeping && !terminating { loginMonitor.refreshIfNeeded() }
        refreshDetailsIfNeeded()
        render()
    }

    private func acceptsAuxiliaryResult(_ contract: Contract, generation expected: UInt64) -> Bool {
        generation == expected && !sleeping && !terminating && preferences.watchlist.contains(contract)
    }

    private func startQuoteUpdates() {
        quoteUpdatesTask?.cancel()
        quoteUpdatesTask = Task { [weak self] in
            guard let self else { return }
            let updates = await quoteSession.updates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                self.quoteSnapshot = update.snapshot
                for observation in update.advancedQuotes {
                    let id = observation.quote.contract.id
                    if self.alertContinuityEpochs[id] != observation.continuityEpoch {
                        self.alertEngine.reset(contractID: id)
                        self.alertContinuityEpochs[id] = observation.continuityEpoch
                    }
                    await self.processAlerts(observation.quote)
                }
                let now = Date()
                if now.timeIntervalSince(self.lastQuoteRenderAt) >= 0.2 {
                    self.lastQuoteRenderAt = now
                    self.render()
                }
            }
        }
    }

    private func reconcileQuoteSession() {
        guard !terminating else { return }
        let plan = MainQuotePlan(preferences: preferences)
        Task { [weak self] in
            guard let self else { return }
            do { try await self.quoteSession.reconcile(plan) }
            catch { self.settingsModel.setMessage("主报价设置失败：\(error.localizedDescription)", kind: .error) }
        }
    }

    private func refreshDetailsIfNeeded() {
        guard !sleeping, !resuming, !terminating else { return }
        let now = Date()
        let requestGeneration = generation
        let candidates = preferences.watchlist.filter(needsDetails).sorted {
            (nextDetailsRefresh[$0] ?? .distantPast) < (nextDetailsRefresh[$1] ?? .distantPast)
        }
        for contract in candidates {
            guard detailsTasks.count < 2 else { break }
            guard detailsTasks[contract] == nil, now >= (nextDetailsRefresh[contract] ?? .distantPast) else { continue }
            nextDetailsRefresh[contract] = now.addingTimeInterval(60)
            let client = detailsClient
            detailsTasks[contract] = Task { [weak self] in
                do {
                    let detail = try await client.details(for: contract)
                    guard let self, self.acceptsAuxiliaryResult(contract, generation: requestGeneration), !Task.isCancelled else { return }
                    self.details[contract] = detail
                    if let reference = ReferenceSpot.contract(for: contract) {
                        do {
                            let spot = try await client.fetch(reference)
                            guard self.acceptsAuxiliaryResult(contract, generation: requestGeneration), !Task.isCancelled else { return }
                            self.referenceSpots[contract] = spot
                        } catch {
                            self.referenceSpots.removeValue(forKey: contract)
                        }
                    } else {
                        self.referenceSpots.removeValue(forKey: contract)
                    }
                } catch { /* Supplemental data must not invalidate a valid primary quote. */ }
                guard let self, self.acceptsAuxiliaryResult(contract, generation: requestGeneration), !Task.isCancelled else { return }
                self.detailsTasks.removeValue(forKey: contract)
                self.render()
            }
        }
    }

    private func needsDetails(_: Contract) -> Bool {
        preferences.showsMarketDetails
    }

    private func loadCatalogue(exchange: Exchange, switchSource: Bool = false, forceReload: Bool = false) {
        guard !sleeping, !resuming, !terminating else { return }
        catalogueGeneration &+= 1
        let requestID = catalogueGeneration
        catalogueTask?.cancel()
        settingsModel.catalogLoading = true
        settingsModel.setMessage("正在通过\(preferences.networkMode.title)连接 \(exchange.title)，加载现货与永续市场…", kind: .loading)
        let client = catalogueClient
        catalogueTask = Task { [weak self] in
            do {
                let catalogue = try await client.instruments(for: exchange, forceReload: forceReload)
                guard let self, requestID == self.catalogueGeneration, !Task.isCancelled, !self.sleeping, !self.terminating else { return }
                guard !catalogue.isEmpty else { throw SettingsError.message("交易所没有返回可用的现货或永续品种") }
                if switchSource && exchange != self.preferences.exchange {
                    let old = self.preferences
                    var replacement = self.sourceProfiles[exchange.rawValue] ?? old
                    let restoringProfile = replacement.exchange == exchange
                    var mapped: [Contract] = []
                    var unavailable: [Contract] = []
                    var mapping: [String: String] = [:]
                    for contract in replacement.watchlist {
                        let match = catalogue.first { candidate in
                            contract.exchange == exchange ? candidate.id == contract.id :
                                candidate.symbol == contract.symbol &&
                                candidate.marketKind == contract.marketKind &&
                                candidate.quoteCurrency == contract.quoteCurrency &&
                                candidate.priceKind == contract.priceKind
                        }
                        if let match {
                            mapped.append(match); mapping[contract.id] = match.id
                        } else if restoringProfile {
                            // Keep unavailable saved contracts editable after switching back.
                            mapped.append(contract); mapping[contract.id] = contract.id
                            unavailable.append(contract)
                        } else {
                            throw SettingsError.message("\(exchange.title) 没有对应的 \(contract.displayTitle)；当前来源保持不变。请先调整关注列表。")
                        }
                    }
                    if let probe = mapped.first(where: { catalogue.contains($0) }) ?? catalogue.first {
                        _ = try await client.fetch(probe)
                    }
                    guard requestID == self.catalogueGeneration, !Task.isCancelled, !self.sleeping, !self.terminating,
                          self.preferences == old else { throw SettingsError.message("设置已变化，请重新选择数据源。") }
                    self.sourceProfiles[old.exchange.rawValue] = old
                    replacement.exchange = exchange
                    replacement.watchlist = mapped
                    replacement.pinnedIDs = replacement.pinnedIDs.compactMap { mapping[$0] }
                    replacement.refreshInterval = old.refreshInterval
                    replacement.showsMarketDetails = old.showsMarketDetails
                    replacement.networkMode = old.networkMode
                    if !restoringProfile {
                        replacement.alerts = []
                        replacement.pendingAlerts = []
                    }
                    replacement.normalize()
                    self.generation &+= 1
                    self.cancelMarketTasks()
                    self.alertEngine.reset()
                    self.alertContinuityEpochs.removeAll()
                    self.preferences = replacement
                    self.details.removeAll(); self.referenceSpots.removeAll()
                    self.nextDetailsRefresh.removeAll()
                    self.savePreferences()
                    self.settingsModel.preferences = self.preferences
                    self.settingsModel.connectionDiagnostic = nil
                    self.buildMenu()
                    var message = "已切换到 \(exchange.title)。关注项和提醒按交易所分别保存。"
                    if !unavailable.isEmpty {
                        message += " \(unavailable.map(\.symbol).joined(separator: "、")) 已不可用，可在关注列表中移除。"
                    }
                    self.settingsModel.setMessage(message, kind: .success, dismissAfter: 6)
                    self.reconcileQuoteSession()
                    self.refreshDetailsIfNeeded()
                } else {
                    self.settingsModel.setMessage("\(exchange.title) · 已加载 \(catalogue.count) 个可用品种", kind: .success, dismissAfter: 4)
                }
                self.settingsModel.catalogue = catalogue
            } catch {
                guard let self, requestID == self.catalogueGeneration, !Task.isCancelled else { return }
                self.settingsModel.setMessage(error is MarketProviderError ? error.localizedDescription : "\(exchange.title)：\(error.localizedDescription)", kind: .error)
            }
            guard let self, requestID == self.catalogueGeneration, !Task.isCancelled else { return }
            self.settingsModel.catalogLoading = false
            self.catalogueTask = nil
            self.render()
        }
    }

    private func testConnection() {
        guard connectionTask == nil, !sleeping, !resuming, !terminating else { return }
        connectionGeneration &+= 1
        let requestID = connectionGeneration
        let exchange = preferences.exchange
        let contract = preferences.watchlist.first
        let networkMode = preferences.networkMode
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let appVersion = build.map { "\(shortVersion) (\($0))" } ?? shortVersion
        settingsModel.connectionTesting = true
        settingsModel.connectionDiagnostic = nil
        settingsModel.setMessage("正在测试 \(exchange.title) · \(networkMode.title)…", kind: .loading)
        let client = catalogueClient
        connectionTask = Task { [weak self] in
            do {
                let report = try await client.connectionDiagnostics(
                    exchange: exchange,
                    networkMode: networkMode,
                    appVersion: appVersion,
                    preferredContract: contract
                )
                guard let self, self.connectionGeneration == requestID, !Task.isCancelled else { return }
                self.settingsModel.connectionDiagnostic = report
                self.settingsModel.setMessage(
                    report.succeeded
                        ? "\(exchange.title) · \(networkMode.title)连接诊断通过。"
                        : "\(exchange.title) · \(networkMode.title)连接诊断未通过，请查看阶段结果。",
                    kind: report.succeeded ? .success : .error,
                    dismissAfter: report.succeeded ? 5 : nil
                )
            } catch {
                guard let self, self.connectionGeneration == requestID, !Task.isCancelled else { return }
                self.settingsModel.setMessage("连接诊断已取消，请在当前设置下重新测试。", kind: .info, dismissAfter: 4)
            }
            guard let self, self.connectionGeneration == requestID, !Task.isCancelled else { return }
            self.settingsModel.connectionTesting = false
            self.connectionTask = nil
            self.render()
        }
    }

    private func render() {
        let now = Date()
        let pinned = preferences.pinnedContracts
        statusRows = pinned.map { contract in
            let state = quoteState(for: contract, now: now)
            return .init(symbol: contract.symbol, displaySymbol: contract.symbol,
                         price: formattedPrice(state.entry.quote),
                         isStale: state.isStale,
                         possiblyMissed: state.possiblyMissed)
        }
        if statusRows.isEmpty {
            statusItem?.button?.image = nil; statusItem?.button?.imagePosition = .noImage
            statusItem?.button?.title = "TideTicker"; statusItem?.length = NSStatusItem.variableLength
        } else {
            let image = CompactStatusImage.make(rows: statusRows, showIcons: showsCoinIcons)
            statusItem?.button?.title = ""; statusItem?.button?.imagePosition = .imageOnly
            statusItem?.button?.image = image; statusItem?.length = image.size.width + 6
        }
        statusItem?.button?.toolTip = pinned.isEmpty ? "TideTicker · 在设置中选择菜单栏常驻品种" : pinned.map { detailText(for: $0, now: now) }.joined(separator: "\n\n")
        statusItem?.button?.setAccessibilityLabel("TideTicker，\(preferences.exchange.title) 现货与永续行情")
        statusItem?.button?.setAccessibilityValue(statusRows.map { row in
            var value = "\(row.displaySymbol) \(row.price)"
            if row.isStale { value += "，报价已过期" }
            if row.possiblyMissed { value += "，行情可能漏报" }
            return value
        }.joined(separator: "；"))
        let pinnedIDs = Set(pinned.map(\.id))
        for contract in preferences.watchlist {
            let state = quoteState(for: contract, now: now)
            let entry = state.entry
            let stale = state.isStale
            if let item = contractItems[contract] {
                var notes: [String] = []
                if stale { notes.append("报价已过期 · 显示上次价格") }
                if state.possiblyMissed { notes.append("可能漏报 · \(state.continuity.description)") }
                if entry.lastError != nil { notes.append("请求失败 · 等待重试") }
                else if entry.quote == nil { notes.append("等待首个报价") }
                if pinnedIDs.contains(contract.id) {
                    TideMenuStyle.setQuote(item, symbol: contract.displayTitle,
                                           price: formattedPrice(entry.quote), notes: notes, muted: stale)
                } else {
                    var compactPrice = formattedPrice(entry.quote)
                    if stale { compactPrice += " · 过期" }
                    else if entry.lastError != nil { compactPrice += " · 失败" }
                    else if entry.quote == nil { compactPrice += " · 等待" }
                    else if state.possiblyMissed { compactPrice += " · 可能漏报" }
                    TideMenuStyle.setColumns(item, contract.displayTitle, compactPrice,
                                             emphasized: false, muted: stale)
                }
                item.setAccessibilityLabel((["\(contract.displayTitle)，\(contract.priceTitle) \(formattedPrice(entry.quote)) \(contract.quoteCurrency)"] + notes).joined(separator: "；"))
            }
            contractItems[contract]?.toolTip = detailText(for: contract, now: now)
            if let detailItem = marketDetailItems[contract] {
                detailItem.isHidden = !preferences.showsMarketDetails
                if preferences.showsMarketDetails {
                    TideMenuStyle.setStacked(detailItem, title: "补充行情",
                                             detail: marketSummaryParts(for: contract, now: now).joined(separator: "\n"))
                }
            }
            if let quote = entry.quote {
                timeItems[contract]?.title = "\(stale ? "已过期 · " : "")数据 \(clockFormatter.string(from: quote.dataTime)) · 收到 \(clockFormatter.string(from: quote.receivedAt))"
            } else { timeItems[contract]?.title = entry.lastError == nil ? "等待首个报价" : "暂无报价 · 等待重试" }
            timeItems[contract]?.toolTip = detailText(for: contract, now: now)
            if let message = entry.lastError {
                let compact = message.replacingOccurrences(of: "\n", with: " ")
                errorItems[contract]?.title = "请求失败：\(compact.prefix(70))\(compact.count > 70 ? "…" : "")"
                errorItems[contract]?.toolTip = message; errorItems[contract]?.isHidden = false
            } else { errorItems[contract]?.isHidden = true }
        }
        let busy = quoteSnapshot.phase.isBusy
        refreshItem.title = sleeping ? "休眠期间暂停刷新" : (busy || resuming ? "正在刷新…" : "立即刷新")
        refreshItem.isEnabled = !sleeping && !resuming && !busy && !terminating && !preferences.watchlist.isEmpty
        applicationRefreshItem.title = refreshItem.title
        applicationRefreshItem.isEnabled = refreshItem.isEnabled
        let freshCount = preferences.watchlist.filter {
            let state = quoteState(for: $0, now: now)
            return state.entry.quote != nil && !state.isStale
        }.count
        let errorCount = preferences.watchlist.filter { quoteState(for: $0, now: now).entry.lastError != nil }.count
        let gapCount = preferences.watchlist.filter { quoteState(for: $0, now: now).possiblyMissed }.count
        let stateText: String
        if sleeping { stateText = "休眠暂停" }
        else if resuming { stateText = "正在恢复连接" }
        else if preferences.watchlist.isEmpty { stateText = "尚未关注品种" }
        else if gapCount > 0 { stateText = "\(quoteSnapshot.phase.title) · \(freshCount)/\(preferences.watchlist.count) 新鲜" }
        else if errorCount > 0 { stateText = "\(errorCount) 项请求失败 · \(freshCount)/\(preferences.watchlist.count) 新鲜" }
        else { stateText = "\(quoteSnapshot.phase.title) · \(freshCount)/\(preferences.watchlist.count) 新鲜" }
        TideMenuStyle.setColumns(quoteStatusItem, "行情状态", stateText, muted: true)
        quoteStatusItem.image = TideMenuStyle.icon("waveform.path.ecg", color: errorCount > 0 ? .systemOrange : .secondaryLabelColor)
        quoteStatusItem.toolTip = "\(preferences.exchange.title) · \(preferences.networkMode.title)；点击检查行情来源与网络连接"
        TideMenuStyle.setColumns(alertsItem, "到价提醒…", "\(preferences.alerts.filter(\.isEnabled).count) 条启用", muted: true)
        if let pending = preferences.pendingAlerts.max(by: { $0.latestTriggeredAt < $1.latestTriggeredAt }) {
            recentAlertItem.isHidden = false
            TideMenuStyle.setStacked(recentAlertItem, title: "待确认 · \(pending.contract.displayTitle)",
                                     detail: "\(pending.direction.title) \(PriceFormatting.exact(pending.threshold)) · 最新 \(PriceFormatting.compact(pending.latestPrice))")
            recentAlertItem.image = TideMenuStyle.icon("bell.badge.fill", color: .systemOrange)
        } else {
            recentAlertItem.isHidden = true
        }
        TideMenuStyle.setColumns(sourceItem, "行情来源…", preferences.networkMode.title, muted: true)
        TideMenuStyle.setColumns(externalDisplayItem, "外部显示…", externalDisplayStatus, muted: true)
        updateOverview(now: now)
        renderLoginItem()
        let kindleSnapshot = KindleDisplaySnapshotFactory.make(
            preferences: preferences, quoteSnapshot: quoteSnapshot,
            details: details, referenceSpots: referenceSpots, now: now
        )
        kindleController.publish(kindleSnapshot)
        writeSnapshot(now: now)
    }

    private func formattedPrice(_ quote: MarkQuote?) -> String { quote.map { PriceFormatting.compact($0.price) } ?? "--" }

    private var externalDisplayStatus: String {
        switch kindleController.model.serviceState {
        case .disabled: return "均未开启"
        case .starting: return "Kindle 正在启动"
        case .ready: return "Kindle 已开启"
        case .awaitingAddress: return "Kindle 等待网络"
        case .failed, .stopped: return "Kindle 不可用"
        }
    }

    private func quoteState(for contract: Contract, now: Date) -> MainQuoteState {
        quoteSnapshot.state(for: contract) ?? MainQuoteState(
            contract: contract, entry: QuoteEntry(), isStale: false,
            continuityEpoch: 0,
            continuity: .possiblyMissed(since: now, cause: .startup), route: nil
        )
    }
    private func marketSummary(for contract: Contract, now: Date) -> String {
        marketSummaryParts(for: contract, now: now).joined(separator: " · ")
    }
    private func overviewSupplement(for contract: Contract, now: Date) -> TideOverviewSupplement? {
        guard preferences.showsMarketDetails else { return nil }
        guard let value = details[contract] else {
            return TideOverviewSupplement(
                change24h: "--",
                fundingRate: contract.marketKind.isPerpetual ? "--" : nil,
                fundingCountdown: contract.marketKind.isPerpetual ? "--" : nil,
                premium: contract.marketKind.isPerpetual
                    ? (contract.marketKind == .inversePerpetual ? "不可用" : "--") : nil,
                isStale: false
            )
        }
        let change = value.change24hPercent.map { PriceFormatting.percent($0, signed: true) } ?? "--"
        guard contract.marketKind.isPerpetual else {
            return TideOverviewSupplement(change24h: change, fundingRate: nil,
                                          fundingCountdown: nil, premium: nil,
                                          isStale: now.timeIntervalSince(value.updatedAt) > 120)
        }
        let funding = value.fundingRate.map { PriceFormatting.percent($0 * 100) } ?? "--"
        let countdown = value.nextFundingTime.map { fundingCountdown(to: $0, now: now) } ?? "--"
        let mark = quoteSnapshot.state(for: contract)?.entry.quote
        let risk = PerpetualRiskSnapshot(markQuote: mark, details: value,
                                          referenceSpot: referenceSpots[contract],
                                          now: now, staleAfter: preferences.staleAfter)
        let premium = risk.premiumPercent.map { PriceFormatting.percent($0, signed: true) }
            ?? (contract.marketKind == .inversePerpetual ? "不可用" : "--")
        return TideOverviewSupplement(change24h: change, fundingRate: funding,
                                      fundingCountdown: countdown, premium: premium,
                                      isStale: now.timeIntervalSince(value.updatedAt) > 120)
    }
    private func marketSummaryParts(for contract: Contract, now: Date) -> [String] {
        guard let value = details[contract] else {
            if contract.marketKind.isPerpetual {
                return ["资金费率 --", "距结算 --",
                        contract.marketKind == .inversePerpetual ? "同所溢折价不可用" : "较同所现货 --"]
            }
            return ["行情详情等待加载"]
        }
        var parts: [String] = []
        if let change = value.change24hPercent { parts.append("24h 成交价 \(PriceFormatting.percent(change, signed: true))") }
        if let funding = value.fundingRate { parts.append("资金费率 \(PriceFormatting.percent(funding * 100))") }
        if contract.marketKind.isPerpetual {
            if let time = value.nextFundingTime { parts.append("距结算 \(fundingCountdown(to: time, now: now))") }
            else { parts.append("距结算 --") }
            let mark = quoteSnapshot.state(for: contract)?.entry.quote
            let risk = PerpetualRiskSnapshot(markQuote: mark, details: value,
                                              referenceSpot: referenceSpots[contract],
                                              now: now, staleAfter: preferences.staleAfter)
            if let premium = risk.premiumPercent {
                parts.append("较同所现货 \(PriceFormatting.percent(premium, signed: true))")
            } else {
                parts.append("同所溢折价不可用")
            }
        }
        if now.timeIntervalSince(value.updatedAt) > 120 { parts.append("详情已过期") }
        return parts.isEmpty ? ["暂无补充行情"] : parts
    }
    private func detailText(for contract: Contract, now: Date) -> String {
        let state = quoteState(for: contract, now: now)
        let entry = state.entry
        var lines = ["\(contract.exchange.title) · \(contract.displayTitle)", "\(contract.priceTitle)：\(entry.quote.map { PriceFormatting.exact($0.price) } ?? "--") \(contract.quoteCurrency)"]
        if let quote = entry.quote {
            if entry.isStale(at: now, threshold: preferences.staleAfter) { lines.append("报价已过期，显示上次已知价格") }
            lines.append("数据时间：\(fullDateFormatter.string(from: quote.dataTime))")
        } else { lines.append("等待首个报价") }
        if let error = entry.lastError { lines.append("请求失败：\(error)") }
        if state.possiblyMissed { lines.append("可能漏报：\(state.continuity.description)") }
        return lines.joined(separator: "\n")
    }

    private func fundingCountdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    @objc private func refreshNow() {
        Task { await quoteSession.refreshNow() }
        nextDetailsRefresh.removeAll()
        refreshDetailsIfNeeded()
    }
    private func setCoinIcons(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.symbolStyleKey)
        render()
    }
    private func setAutomaticUpdateChecks(_ enabled: Bool) {
        guard let updateController else { return }
        updateController.setAutomaticallyChecks(enabled)
    }
    @objc private func checkForUpdates() { updateController?.checkNow() }
    @objc private func showAvailableUpdate() { updateController?.presentAvailableUpdate() }
    @objc private func showAboutPanel() {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let credits = NSMutableAttributedString(string: "开源项目 · GitHub\n")
        let linkText = NSAttributedString(
            string: "github.com/realRongCat/TideTicker",
            attributes: [.link: URL(string: "https://github.com/realRongCat/TideTicker")!]
        )
        credits.append(linkText)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "TideTicker",
            .applicationVersion: shortVersion,
            .version: build.isEmpty ? "" : "构建 \(build)",
            .credits: credits,
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc private func showMainWindow() { presentWindow(page: .market, marketMode: .overview) }
    @objc private func showOverview() { presentWindow(page: .market, marketMode: .overview) }
    @objc private func showWatchlist() { presentWindow(page: .market, marketMode: .manage) }
    @objc private func showSource() { presentWindow(page: .source) }
    @objc private func showAlerts() { presentWindow(page: .alerts) }
    @objc private func showExternalDisplay() { presentWindow(page: .externalDisplay) }
    @objc private func showAdvancedSettings() { presentWindow(page: .advanced) }
    @objc private func showSettings() { presentWindow(page: .market, marketMode: .manage) }

    private func presentWindow(page: TideWindowPage? = nil, marketMode: TideMarketMode? = nil) {
        if settingsWindow == nil {
            let controller = TideSettingsWindowController(model: settingsModel,
                                                          kindleModel: kindleController.model)
            controller.onRequestQuoteSnapshot = { [weak self] in self?.updateOverview(now: Date()) }
            controller.onClose = { [weak self] in self?.cancelConnectionDiagnostic() }
            settingsWindow = controller
        }
        settingsWindow?.present(page: page, marketMode: marketMode)
        updateOverview(now: Date())
        if settingsModel.catalogue.isEmpty && !settingsModel.catalogLoading { loadCatalogue(exchange: preferences.exchange) }
        refreshDetailsIfNeeded()
        updateNotificationStatus()
    }

    private func updateOverview(now: Date) {
        guard let settingsWindow, settingsWindow.wantsQuoteUpdates else { return }
        let rows = preferences.watchlist.map { contract in
            let state = quoteState(for: contract, now: now)
            let entry = state.entry
            return TideOverviewQuote(contract: contract, price: entry.quote?.price,
                                     dataTime: entry.quote?.dataTime, receivedAt: entry.quote?.receivedAt,
                                     isStale: state.isStale,
                                     possiblyMissed: state.possiblyMissed,
                                     error: entry.lastError,
                                     supplement: overviewSupplement(for: contract, now: now))
        }
        settingsWindow.updateQuotes(rows, isRefreshing: quoteSnapshot.phase.isBusy || resuming, isPaused: sleeping)
    }
    func menuWillOpen(_ menu: NSMenu) {
        // Render cached state immediately. A delayed system-service reply must
        // never hold up AppKit's synchronous menu-opening callback.
        render()
        loginMonitor.refreshIfNeeded()
        refreshDetailsIfNeeded()
    }

    private func requestNotifications() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            settingsModel.setNotification(.unavailable, status: "通知需要从安装后的 TideTicker.app 使用")
            return
        }
        Task { [weak self] in
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                self?.notificationAuthorizationStatus = granted ? .authorized : .denied
                self?.alertEngine.reset()
                self?.settingsModel.setNotification(
                    granted ? .authorized : .denied,
                    status: granted ? "系统通知已允许" : "系统通知未允许；可在系统设置中开启"
                )
            } catch {
                self?.settingsModel.setNotification(.failed, status: "通知设置失败：\(error.localizedDescription)")
            }
        }
    }

    private func openNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ].compactMap(URL.init(string:))
        guard urls.contains(where: { NSWorkspace.shared.open($0) }) else {
            settingsModel.setMessage("无法打开通知设置，请手动前往系统设置 → 通知 → TideTicker。", kind: .error)
            return
        }
    }

    private func updateNotificationStatus() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        Task { [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self?.notificationAuthorizationStatus = settings.authorizationStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self?.settingsModel.setNotification(.authorized, status: "系统通知已允许")
            case .denied:
                self?.settingsModel.setNotification(.denied, status: "系统通知未允许；可在系统设置中开启")
            case .notDetermined:
                self?.settingsModel.setNotification(.notDetermined, status: "允许系统通知后即可接收到价提醒")
            @unknown default:
                self?.settingsModel.setNotification(.unavailable, status: "暂时无法读取系统通知状态")
            }
        }
    }
    private func processAlerts(_ quote: MarkQuote) async {
        guard Bundle.main.bundleURL.pathExtension == "app",
              preferences.alerts.contains(where: { $0.contract == quote.contract && $0.isEnabled }) else { return }
        let center = UNUserNotificationCenter.current()
        guard !sleeping, !terminating, preferences.watchlist.contains(quote.contract), !Task.isCancelled,
              quoteSnapshot.state(for: quote.contract)?.entry.quote?.dataTime == quote.dataTime else { return }
        guard let authorization = notificationAuthorizationStatus else { return }
        guard authorization == .authorized || authorization == .provisional else {
            // A permission prompt or denial must not consume a single-use rule.
            alertEngine.reset(contractID: quote.contract.id)
            return
        }
        let priorRules = preferences.alerts
        var evaluatedRules = priorRules
        let events = alertEngine.evaluate(quote, rules: &evaluatedRules, now: Date(), staleAfter: preferences.staleAfter)
        guard !events.isEmpty else { return }
        var deliver: [AlertEvent] = []
        for event in events {
            guard priorRules.first(where: { $0.id == event.id })?.requiresAcknowledgement == true,
                  let index = preferences.pendingAlerts.firstIndex(where: { $0.ruleID == event.id }) else {
                deliver.append(event)
                continue
            }
            preferences.pendingAlerts[index].update(with: event)
        }
        if deliver.count != events.count {
            savePreferences()
            settingsModel.preferences = preferences
        }
        guard !deliver.isEmpty else { return }
        let batch = PriceAlertSubmissionBatch(events: deliver, originalRules: priorRules, evaluatedRules: evaluatedRules)
        func message(for event: AlertEvent) -> String {
            "\(event.contract.exchange.title) · \(event.contract.displayTitle) · \(event.contract.priceTitle) \(PriceFormatting.exact(event.price)) \(event.contract.quoteCurrency)"
        }
        await batch.submit(
            isCurrent: {
                !self.sleeping && !self.terminating && self.preferences.watchlist.contains(quote.contract)
                    && !Task.isCancelled
            },
            currentRules: { self.preferences.alerts },
            updateRules: { rules in
                self.preferences.alerts = rules
                self.savePreferences()
                self.settingsModel.preferences = self.preferences
            },
            submitNotification: { event in
                let content = UNMutableNotificationContent()
                content.title = "\(event.contract.exchange.title) · \(event.contract.instrumentID) · \(event.contract.priceTitle) \(event.direction.title) \(PriceFormatting.exact(event.threshold))"
                content.body = message(for: event); content.sound = .default
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            },
            didSubmit: { event in
                if self.preferences.alerts.first(where: { $0.id == event.id })?.requiresAcknowledgement == true {
                    self.preferences.pendingAlerts.removeAll { $0.ruleID == event.id }
                    self.preferences.pendingAlerts.append(PendingAlertEvent(event: event))
                    self.savePreferences()
                    self.settingsModel.preferences = self.preferences
                }
                self.settingsModel.setMessage("提醒已触发：\(message(for: event))", kind: .success, dismissAfter: 6)
            },
            didFail: { error, restored in
                if restored { self.alertEngine.reset() }
                guard !self.sleeping, !self.terminating, self.preferences.watchlist.contains(quote.contract), !Task.isCancelled else { return }
                self.settingsModel.setNotification(.failed, status: "发送通知失败：\(error.localizedDescription)")
            }
        )
    }

    private func acknowledgeAlert(_ ruleID: UUID) {
        guard preferences.pendingAlerts.contains(where: { $0.ruleID == ruleID }) else { return }
        preferences.pendingAlerts.removeAll { $0.ruleID == ruleID }
        alertEngine.reset(ruleID: ruleID)
        savePreferences()
        settingsModel.preferences = preferences
        settingsModel.setMessage("已确认提醒，规则已重新布防。", kind: .success, dismissAfter: 4)
        render()
    }

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    private func cancelMarketTasks() {
        for task in detailsTasks.values { task.cancel() }
        detailsTasks.removeAll()
        cancelConnectionDiagnostic()
    }

    private func cancelConnectionDiagnostic() {
        guard connectionTask != nil || settingsModel.connectionTesting else { return }
        connectionGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        settingsModel.connectionTesting = false
    }
    @objc private func willSleep() {
        sleeping = true; resuming = false; generation &+= 1; catalogueGeneration &+= 1
        resumeTask?.cancel(); catalogueTask?.cancel(); catalogueTask = nil; settingsModel.catalogLoading = false
        cancelMarketTasks(); alertEngine.reset()
        alertContinuityEpochs.removeAll()
        let catalogueClient = catalogueClient, detailsClient = detailsClient
        cancellationTask = Task {
            await self.quoteSession.suspend()
            await catalogueClient.cancelAll(); await detailsClient.cancelAll()
        }
        render()
    }
    @objc private func didWake() {
        guard !terminating else { return }
        loginMonitor.refreshIfNeeded(force: true)
        updateNotificationStatus()
        sleeping = false; resuming = true; generation &+= 1
        cancelMarketTasks()
        let resumeGeneration = generation, cancellation = cancellationTask
        let catalogueClient = catalogueClient, detailsClient = detailsClient
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            await cancellation?.value
            guard !Task.isCancelled else { return }
            await catalogueClient.cancelAll(); await catalogueClient.invalidateNetworkCache()
            await detailsClient.cancelAll(); await detailsClient.invalidateNetworkCache()
            guard let self, !Task.isCancelled, !self.sleeping, !self.terminating, self.generation == resumeGeneration else { return }
            self.resuming = false
            self.nextDetailsRefresh.removeAll()
            try? await self.quoteSession.resume()
            self.refreshDetailsIfNeeded()
        }
        render()
        updateController?.checkIfDue()
    }

    private func configureDefaultLoginItem() {
        guard !suppressDefaultLoginRegistration, Bundle.main.bundleURL.pathExtension == "app", !defaults.bool(forKey: Self.loginConfiguredKey) else {
            loginMonitor.refreshIfNeeded(force: true)
            return
        }
        if loginMonitor.request(operation: .registerIfNeeded) {
            defaults.set(true, forKey: Self.loginConfiguredKey)
        }
    }
    private func renderLoginItem() {
        syncAdvancedSettings()
    }
    private func setLoginItemEnabled(_ enabled: Bool) {
        let isRegistered = loginMonitor.status == .enabled || loginMonitor.status == .requiresApproval
        guard enabled != isRegistered, !terminating, preferencesURL == nil,
              loginMonitor.request(operation: .toggle) else { return }
        defaults.set(true, forKey: Self.loginConfiguredKey)
    }
    private func syncAdvancedSettings() {
        let automaticallyChecks = updateController?.automaticallyChecks
            ?? (defaults.object(forKey: TideUpdateController.automaticChecksKey) as? Bool ?? true)
        settingsModel.setAdvancedSettings(TideAdvancedSettingsState(
            showsCoinIcons: showsCoinIcons,
            automaticallyChecksForUpdates: automaticallyChecks,
            canChangeAutomaticChecks: updateController?.canSetAutomaticChecks == true,
            loginStatus: loginMonitor.status,
            loginError: loginMonitor.error,
            loginIsBusy: loginMonitor.isBusy,
            canManageLoginItem: Bundle.main.bundleURL.pathExtension == "app"
                && !terminating && preferencesURL == nil && loginMonitor.status != .unknown
        ))
    }
    private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        terminating = true; generation &+= 1; catalogueGeneration &+= 1
        loginMonitor.stop()
        updateController?.stop()
        kindleController.stop()
        timer?.invalidate(); cancelMarketTasks(); resumeTask?.cancel(); catalogueTask?.cancel()
        render()
        let catalogueClient = catalogueClient, detailsClient = detailsClient
        Task {
            await quoteSession.stop()
            await catalogueClient.cancelAll(); await detailsClient.cancelAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        loginMonitor.stop()
        updateController?.stop()
        kindleController.stop()
        timer?.invalidate()
        quoteUpdatesTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func writeSnapshot(now: Date) {
        guard let snapshotURL else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let quoteStates: [[String: Any]] = preferences.watchlist.map { contract in
            let quoteState = quoteState(for: contract, now: now)
            let entry = quoteState.entry
            var state: [String: Any] = ["id": contract.id, "exchange": contract.exchange.rawValue, "symbol": contract.symbol,
                "instrumentID": contract.instrumentID, "isStale": quoteState.isStale,
                "possiblyMissed": quoteState.possiblyMissed,
                "continuity": quoteState.continuity.description,
                "route": quoteState.route?.rawValue as Any? ?? NSNull(),
                "error": entry.lastError as Any? ?? NSNull()]
            state["marketKind"] = contract.marketKind.rawValue
            state["priceKind"] = contract.priceKind.rawValue
            state["quoteCurrency"] = contract.quoteCurrency
            state["settlementCurrency"] = contract.settlementCurrency
            if let quote = entry.quote {
                state["price"] = PriceFormatting.exact(quote.price); state["formattedPrice"] = formattedPrice(quote)
                state["dataTime"] = iso.string(from: quote.dataTime); state["receivedAt"] = iso.string(from: quote.receivedAt)
                state["ageSeconds"] = now.timeIntervalSince(quote.dataTime)
            }
            if let value = details[contract] {
                state["details"] = ["change24hPercent": value.change24hPercent.map(PriceFormatting.exact) as Any? ?? NSNull(),
                    "fundingRate": value.fundingRate.map(PriceFormatting.exact) as Any? ?? NSNull(),
                    "nextFundingTime": value.nextFundingTime.map { iso.string(from: $0) } as Any? ?? NSNull(),
                    "premiumPercent": PerpetualRiskSnapshot(markQuote: entry.quote, details: value,
                        referenceSpot: referenceSpots[contract], now: now,
                        staleAfter: preferences.staleAfter).premiumPercent.map(PriceFormatting.exact) as Any? ?? NSNull(),
                    "updatedAt": iso.string(from: value.updatedAt)]
            }
            return state
        }
        let updateStatus: String
        let availableUpdateVersion: Any
        switch updateMenuState {
        case .idle:
            updateStatus = "idle"; availableUpdateVersion = NSNull()
        case .checking:
            updateStatus = "checking"; availableUpdateVersion = NSNull()
        case let .available(release):
            updateStatus = "available"; availableUpdateVersion = release.version.description
        }
        let snapshot: [String: Any] = [
            "renderedAt": iso.string(from: now), "exchange": preferences.exchange.rawValue,
            "networkMode": preferences.networkMode.rawValue,
            "statusLayout": "stacked", "statusSymbolStyle": showsCoinIcons ? "icons" : "text",
            "statusTitle": statusRows.isEmpty ? "TideTicker" : statusRows.map(\.text).joined(separator: "\n"),
            "statusFontSize": CompactStatusImage.fontSize, "statusWidth": statusItem?.length ?? 0,
            "statusImageHeight": statusItem?.button?.image?.size.height ?? 0,
            "statusButtonBounds": statusItem?.button.map { NSStringFromRect($0.bounds) } ?? "",
            "statusImageRect": statusItem?.button.map { NSStringFromRect($0.cell?.imageRect(forBounds: $0.bounds) ?? .zero) } ?? "",
            "statusRows": statusRows.map { ["symbol": $0.symbol, "price": $0.price,
                                             "isStale": $0.isStale,
                                             "possiblyMissed": $0.possiblyMissed] as [String: Any] },
            "statusTooltip": statusItem?.button?.toolTip ?? "", "pinnedIDs": preferences.pinnedIDs,
            "refreshInterval": preferences.refreshInterval, "staleAfter": preferences.staleAfter,
            "activationPolicy": NSApplication.shared.activationPolicy().rawValue,
            "quoteSessionPhase": quoteSnapshot.phase.title,
            "refreshInFlight": quoteSnapshot.phase.isBusy,
            "sleeping": sleeping, "resuming": resuming, "terminating": terminating,
            "loginItemStatus": cachedLoginStatusCode as Any? ?? NSNull(), "loginItemError": loginMonitor.error as Any? ?? NSNull(),
            "loginItemRefreshing": loginMonitor.isBusy,
            "defaultLoginRegistrationSuppressed": suppressDefaultLoginRegistration, "quotes": quoteStates,
            "catalogueCount": settingsModel.catalogue.count, "catalogueLoading": settingsModel.catalogLoading,
            "settingsMessage": settingsModel.message, "notificationStatus": settingsModel.notificationStatus,
            "updateStatus": updateStatus, "availableUpdateVersion": availableUpdateVersion,
            "automaticUpdateChecks": updateController?.automaticallyChecks ?? false,
            "updatePanelVisible": updateController?.isPanelVisible ?? false,
            "lastPresentedNotificationID": lastPresentedNotificationID as Any? ?? NSNull(),
            "alertCount": preferences.alerts.count, "enabledAlertCount": preferences.alerts.filter(\.isEnabled).count,
            "pendingAlertCount": preferences.pendingAlerts.count,
            "windowVisible": settingsWindow?.window?.isVisible ?? false,
            "overviewReceivingQuotes": settingsWindow?.wantsQuoteUpdates ?? false,
            "menu": menuSnapshot(menu),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: snapshotURL, options: .atomic)
        } catch { NSLog("TideTicker could not write UI snapshot: %@", error.localizedDescription) }
    }

    private func menuSnapshot(_ menu: NSMenu) -> [[String: Any]] {
        menu.items.filter { !$0.isSeparatorItem }.map { item in
            var value: [String: Any] = ["title": item.title, "enabled": item.isEnabled, "hidden": item.isHidden,
                                       "state": item.state.rawValue, "shortcut": item.keyEquivalent,
                                       "hasIcon": item.image != nil]
            if let submenu = item.submenu { value["items"] = menuSnapshot(submenu) }
            return value
        }
    }

    private var cachedLoginStatusCode: Int? {
        switch loginMonitor.status {
        case .notRegistered: return SMAppService.Status.notRegistered.rawValue
        case .enabled: return SMAppService.Status.enabled.rawValue
        case .requiresApproval: return SMAppService.Status.requiresApproval.rawValue
        case .notFound: return SMAppService.Status.notFound.rawValue
        case .unknown: return nil
        }
    }
}

private enum SettingsError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

