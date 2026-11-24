import AppKit
import Foundation
import GozarCore
import Observation
import Network
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    let demo: Bool
    let snapshot: Bool
    let paths = StatePaths.resolve()
    var windowVisible = false
    private(set) var vpn = VPNStatus()
    private(set) var router: RouterStatus?
    private(set) var totals = RouterTotals()
    private(set) var domains: [DomainStat] = []
    private(set) var rules: [Rule] = []
    private(set) var exits = ExitListing()
    private(set) var exitsFailure: String?
    private(set) var exitTests: [String: ExitTestResult] = [:]
    private(set) var testingExits: Set<String> = []
    var setupPresented = false
    var addExitPresented = false
    var addSitePresented = false
    var destination: Screen = .overview
    private(set) var rulesFailure: String?
    private(set) var statusFailure: String?
    private(set) var grafana: GrafanaResponse?
    private(set) var grafanaFailure: String?
    private(set) var hasToken = false
    private(set) var settingsRevision = 0
    private(set) var loginEnabled = false
    private(set) var working = false
    private(set) var connecting = false
    private(set) var outputLine = ""
    private(set) var toast: String?
    private(set) var toastFailed = false
    var failure: String?
    var about = false

    private(set) var vpnPath: String
    private(set) var grafanaURL: String
    var menuRate: Bool {
        didSet { if !demo { defaults.set(menuRate, forKey: "menuRate") } }
    }

    private(set) var paused = false
    private(set) var unseen = 0
    private var rows: [Int: ConnStat] = [:]
    private var frozenRows: [ConnStat] = []
    private var routeRates: [Route: [MetricPoint]] = [:]
    private var domainRates: [String: [MetricPoint]] = [:]
    private var probeHistory: [String: [MetricPoint]] = [:]
    @ObservationIgnored private var probeSampleTime: [String: Date] = [:]
    @ObservationIgnored private var recentRates: [Int: Date] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var watcher: DispatchSourceTimer?
    @ObservationIgnored private var grafanaTask: Task<Void, Never>?
    @ObservationIgnored private var rulesReadID = UUID()
    @ObservationIgnored private var statusReadID = UUID()
    @ObservationIgnored private var exitsReadID = UUID()
    @ObservationIgnored private var routerStart: Date?
    @ObservationIgnored private var actionID: UUID?
    @ObservationIgnored private var toastID = UUID()

    private let defaults = UserDefaults.standard
    private let grafanaClient = GrafanaClient()
    private let client: RouterClient
    private let eventClient: RouterClient
    private var cli: CLI { CLI(vpnPath: vpnPath, paths: paths) }
    private var demoTick = 0
    private var demoDraft = DemoData.connection

    var on: Bool { vpn.socks && vpn.proxy }
    var problem: Bool {
        statusFailure != nil || (!on && (vpn.loop || vpn.stopped != nil)) ||
            (on && vpn.router.enabled && router == nil) || (router?.upstreamUp == false && on)
    }

    var classic: Bool { on && !vpn.router.enabled && router == nil }
    var rowsVisible: [ConnStat] {
        paused ? frozenRows : rows.values.sorted {
            ($0.startedAt, $0.id) > ($1.startedAt, $1.id)
        }
    }

    var topDomains: [DomainStat] { domains.sorted { $0.rateDown > $1.rateDown } }
    var box: [String: String] { grafana?.series["box"]?.first?.labels ?? [:] }
    var dashboardURL: URL? { GrafanaClient.baseURL(grafanaURL)?.appendingPathComponent("d/egress-tunnels") }

    init(demo: Bool, snapshot: Bool = false) {
        self.demo = demo || snapshot
        self.snapshot = snapshot
        let local = URLSessionConfiguration.ephemeral
        local.connectionProxyDictionary = [:]
        local.timeoutIntervalForRequest = 2
        local.timeoutIntervalForResource = 3
        client = RouterClient(paths: paths, session: URLSession(configuration: local))
        eventClient = RouterClient(paths: paths)
        let defaultVPN = AppResources.defaultVPN
        let defaultGrafana = "https://grafana.example.com"
        vpnPath = self.demo ? "~/Applications/Gozar.app/Contents/Resources/cli/laptop-vpn.sh" :
            defaults.string(forKey: "vpnPath") ?? defaultVPN
        grafanaURL = self.demo ? defaultGrafana : defaults.string(forKey: "grafanaURL") ?? defaultGrafana
        menuRate = self.demo ? true : defaults.object(forKey: "menuRate") as? Bool ?? true
        if self.demo { seedDemo(at: snapshot ? DemoData.reference : Date()) }
    }

    func start() {
        guard tasks.isEmpty, !snapshot else { return }
        if demo {
            poll(every: 1) { app in app.advanceDemo() }
            return
        }

        loginEnabled = SMAppService.mainApp.status == .enabled
        let configured = FileManager.default.fileExists(atPath: paths.connection.path)
        setupPresented = !configured || setupHasNoExits
        poll(every: 2) { await $0.refreshRouter() }
        poll(every: 3) { await $0.refreshDomains() }
        poll(every: 15) { await $0.refreshVPN() }
        poll(every: 15) {
            if !$0.working { await $0.refreshExits() }
        }
        tasks.append(Task { [weak self] in await self?.stream() })
        tasks.append(Task { [weak self] in await self?.refreshRules() })
        watcher = ConfigStore(paths: paths).watch { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settingsRevision += 1
                await self.refreshRules()
            }
        }
        scheduleGrafana()
    }

    func updateWindowVisibility(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        if !demo { scheduleGrafana() }
    }

    func routeHistory(_ route: Route) -> [MetricPoint] { routeRates[route] ?? [] }
    func domainHistory(_ domain: String) -> [MetricPoint] { domainRates[domain] ?? [] }
    func probe(_ name: String) -> ProbeStat? { router?.probes.first { $0.name == name } }
    func history(_ name: String) -> [MetricPoint] { probeHistory[name] ?? [] }

    func togglePause() {
        if paused {
            paused = false
            frozenRows.removeAll()
            unseen = 0
        } else {
            frozenRows = rowsVisible
            paused = true
        }
    }

    func toggleConnection() {
        if on || vpn.loop { vpnAction(["off"], connecting: false) }
        else { vpnAction(["on"], connecting: true) }
    }

    func backToNormal() { vpnAction(["on"], connecting: true) }
    func resetHostKey() { vpnAction(["reset-hostkey"], showToast: true) }
    func forgetPassword() { vpnAction(["forget"], showToast: true) }

    func tryBox(_ ip: String) {
        guard isIPAddress(ip) else { failure = L.invalidIP; return }
        vpnAction(["try", ip], connecting: true)
    }

    func changeRoute(_ domain: String, to route: Route?) {
        changeRoutes(route.map { ["set", domain, $0.rawValue] } ?? ["unset", domain])
    }

    private func changeRoutes(_ args: [String]) {
        perform(showToast: true) { cli, progress in
            if self.demo {
                self.editDemo(args)
            } else {
                _ = try await cli.run(args, progress: progress).checked()
                try await self.reloadRoutes(using: cli, progress: progress)
            }
        }
    }

    func editRules(_ args: [String], followedBy: [String]? = nil) {
        perform(showToast: true) { cli, progress in
            if self.demo {
                self.editDemo(args)
                if let followedBy { self.editDemo(followedBy) }
            } else {
                _ = try await cli.configuration(args, progress: progress).checked()
                if let followedBy { _ = try await cli.configuration(followedBy, progress: progress).checked() }
                try await self.reloadRoutes(using: cli, progress: progress)
            }
        }
    }

    func addSite(_ command: AddSiteCommand) {
        switch command {
        case let .vpn(args): changeRoutes(args)
        case let .configuration(args): editRules(args)
        }
    }

    func checkSite(_ site: String) async throws -> RouteDecision {
        if demo {
            let host = URLComponents(string: site.contains("://") ? site : "https://" + site)?.host ?? site
            return demoDecision(host)
        }
        var args = ["check", "--json"]
        if router?.ciscoUp ?? vpn.cisco { args.append("--cisco") }
        return try await cli.configuration(args + ["--", site]).decode(CLICheck.self).decision
    }

    func checkDomain(_ domain: String) async throws -> RouteDecision {
        if demo { return demoDecision(domain) }
        return try await client.check(host: domain).decision
    }

    func discover(_ site: String, progress: @escaping @Sendable (String) -> Void) async throws -> DomainDiscovery {
        if demo {
            progress(L.demoWork)
            try await Task.sleep(for: .milliseconds(650))
            return DemoData.discovery(site, rules: rules)
        }
        // The command adds its own Cisco flag, so validate before passing a positional site.
        guard !site.hasPrefix("-") else { throw AppError(L.sitePrompt) }
        let args = ["domains", "--json"] + ((router?.ciscoUp ?? vpn.cisco) ? ["--cisco"] : [])
        return try await cli.configuration(args + ["--", site], progress: progress).decode(DomainDiscovery.self)
    }

    func loadDraft() throws -> (draft: ConnectionDraft, original: Data?) {
        if demo { return (demoDraft, nil) }
        let original = try connectionData()
        let data = try original ?? Data(contentsOf: cli.confDir.appendingPathComponent("connection.default.json"))
        return (try ConnectionDraft(data), original)
    }

    func saveConnection(_ draft: ConnectionDraft, original: Data?) {
        perform(showToast: true) { cli, progress in
            if self.demo {
                self.demoDraft = draft
                self.vpn.router.enabled = draft.routerEnabled
                self.vpn.router.running = draft.routerEnabled && self.on
                self.router = self.vpn.router.running ? DemoData.router(self.demoTick, at: Date()) : nil
                if !self.vpn.router.running { self.clearRouterData() }
                self.settingsRevision += 1
                return
            }
            try await self.writeConnection(draft, original: original, using: cli)

            // The CLI's apply also handles restarting the tunnel when ports change.
            _ = try await cli.run(["apply"], progress: progress).checked()
            await self.refreshVPN()
        }
    }

    func enableRouterMode() {
        do {
            var (draft, original) = try loadDraft()
            draft.routerEnabled = true
            saveConnection(draft, original: original)
        } catch {
            failure = error.localizedDescription
        }
    }

    @discardableResult
    func savePreferences(path: String, grafana url: String) -> Bool {
        guard !working else { return false }
        guard let base = GrafanaClient.baseURL(url) else { failure = L.invalidGrafanaURL; return false }
        let newPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath = newPath.isEmpty ? AppResources.defaultVPN : newPath
        let pathChanged = vpnPath != resolvedPath
        let grafanaChanged = grafanaURL != base.absoluteString
        vpnPath = resolvedPath
        grafanaURL = base.absoluteString
        if !demo {
            defaults.set(resolvedPath == AppResources.defaultVPN ? nil : resolvedPath, forKey: "vpnPath")
            defaults.set(grafanaURL, forKey: "grafanaURL")
            if pathChanged {
                settingsRevision += 1
                Task { await refreshRules() }
                Task { await refreshVPN() }
                Task { await refreshExits() }
            }
            if grafanaChanged { scheduleGrafana(clear: true) }
        }
        announce(L.applied)
        return true
    }

    @discardableResult
    func saveToken(_ token: String) -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        do {
            if !demo { try Keychain.set(token, service: Keychain.grafanaService, account: Keychain.grafanaAccount) }
            hasToken = true
            if !demo { scheduleGrafana(clear: true) }
            announce(L.applied)
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func savePassword(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        do {
            if !demo {
                guard let exit = exits.activeExit, exit.kind == .ssh else { throw AppError(L.sshRequired) }
                let account = exit.id == "relay" ? try loadDraft().draft.relayUser : exit.id
                try Keychain.set(password, service: exit.id == "relay" ? Keychain.relayService : Keychain.sshService,
                                 account: account)
            }
            announce(L.applied)
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            try updateLogin(enabled)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func connectionData() throws -> Data? {
        do { return try Data(contentsOf: paths.connection) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func writeConnection(_ draft: ConnectionDraft, original: Data?, using cli: CLI) async throws {
        if try connectionData() != original { throw AppError(L.configChanged) }
        let base = try original ?? Data(contentsOf: cli.confDir.appendingPathComponent("connection.default.json"))
        let updated = try draft.applying(to: base)
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("gozar-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        try updated.write(to: temp.appendingPathComponent("connection.json"), options: .atomic)
        let shippedRoutes = cli.confDir.appendingPathComponent("routes.default.json")
        let routes = fm.fileExists(atPath: paths.routes.path) ? paths.routes : shippedRoutes
        try fm.copyItem(at: routes, to: temp.appendingPathComponent("routes.json"))
        if fm.fileExists(atPath: exitsFile.path) {
            // Validate the migrated config shape without copying exit credentials.
            let marker = Data(#"{"active":null,"exits":[],"subscriptions":[]}"#.utf8)
            try marker.write(to: temp.appendingPathComponent("exits.json"))
        }
        _ = try await cli.configuration(["validate"], state: temp).checked()

        if try connectionData() != original { throw AppError(L.configChanged) }
        try fm.createDirectory(at: paths.stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try updated.write(to: paths.connection, options: .atomic)
        settingsRevision += 1
    }

    private func perform(
        connecting: Bool = false, showToast: Bool = false,
        _ action: @escaping @MainActor (CLI, @escaping @Sendable (String) -> Void) async throws -> Void
    ) {
        guard !working else { return }
        working = true
        self.connecting = connecting
        outputLine = ""
        let id = UUID()
        actionID = id
        let activeCLI = cli
        Task {
            defer {
                self.actionID = nil
                self.working = false
                self.connecting = false
                self.outputLine = ""
            }
            do {
                if demo {
                    outputLine = L.demoWork
                    try await Task.sleep(for: .milliseconds(550))
                }
                try await action(activeCLI) { [weak self] line in
                    Task { @MainActor in
                        guard self?.actionID == id else { return }
                        self?.outputLine = line
                    }
                }
                if showToast { announce(L.applied) }
            } catch {
                if showToast { announce(error.localizedDescription, failed: true) }
                else { failure = error.localizedDescription }
                if !demo { await refreshRules() }
            }
        }
    }

    private func vpnAction(_ args: [String], connecting: Bool = false, showToast: Bool = false) {
        perform(connecting: connecting, showToast: showToast) { cli, progress in
            if self.demo {
                switch args.first {
                case "off":
                    self.vpn = VPNStatus(router: .init(enabled: self.demoDraft.routerEnabled, running: false))
                    self.clearRouterData()
                case "on", "try":
                    self.vpn = DemoData.status
                    self.vpn.router.enabled = self.demoDraft.routerEnabled
                    self.vpn.router.running = self.demoDraft.routerEnabled
                    self.vpn.via = args.count > 1 ? args[1] : nil
                    if let via = self.vpn.via { self.vpn.exitIP = via }
                    if self.vpn.router.enabled { self.advanceDemo() }
                default: break
                }
            } else {
                do { _ = try await cli.run(args, progress: progress).checked() }
                catch { await self.refreshVPN(); throw error }
                await self.refreshVPN()
                await self.refreshRouter()
            }
        }
    }

    private func reloadRoutes(using cli: CLI, progress: @escaping @Sendable (String) -> Void) async throws {
        await refreshRules()
        if router != nil {
            try await client.reload()
            await refreshDomains()
            return
        }
        let current = try await cli.run(["status", "--json", "--no-ip"]).decode(VPNStatus.self)
        if current.router.running {
            try await client.reload()
            await refreshDomains()
        } else if current.socks && current.proxy && !current.router.enabled {
            _ = try await cli.run(["apply"], progress: progress).checked()
        }
    }

    private func announce(_ message: String, failed: Bool = false) {
        let id = UUID()
        toastID = id
        toast = message
        toastFailed = failed
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(failed ? 6 : 3))
            if self?.toastID == id { self?.toast = nil }
        }
    }

    private func poll(every seconds: Int, using action: @escaping @MainActor (AppModel) async -> Void) {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                if let self { await action(self) }
                else { return }
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return }
            }
        })
    }

    private func refreshVPN() async {
        let request = UUID()
        statusReadID = request
        let result = await cli.run(["status", "--json"])
        guard statusReadID == request else { return }
        do {
            let updated = try result.decode(VPNStatus.self)
            let ciscoChanged = vpn.cisco != updated.cisco
            vpn = updated
            if statusFailure != nil { statusFailure = nil }
            if ciscoChanged { await refreshRules() }
        } catch {
            statusFailure = error.localizedDescription
        }
    }

    private func refreshRules() async {
        let request = UUID()
        rulesReadID = request
        let useCisco = router?.ciscoUp ?? vpn.cisco
        let args = ["routes", "--json"] + (useCisco ? ["--cisco"] : [])
        let result = await cli.configuration(args)
        guard rulesReadID == request else { return }
        do {
            let updated = try result.decode(RulesListing.self)
            rules = updated.rules
            rulesFailure = nil
        } catch {
            rulesFailure = error.localizedDescription
        }
    }

    private func refreshRouter() async {
        do {
            let status = try await client.status()
            if routerStart != status.startedAt {
                clearRouterData()
                routerStart = status.startedAt
            }
            router = status
            totals = status.totals
            recordProbes(status.probes, at: Date())
        } catch {
            if router != nil { clearRouterData() }
        }
    }

    private func recordProbes(_ probes: [ProbeStat], at time: Date) {
        for probe in probes {
            guard let value = probe.lastMs else { continue }
            if let last = probeSampleTime[probe.name], time.timeIntervalSince(last) < 9 { continue }
            probeSampleTime[probe.name] = time
            probeHistory[probe.name, default: []].append(MetricPoint(at: time, value: value))
            if probeHistory[probe.name, default: []].count > 30 { probeHistory[probe.name]?.removeFirst() }
        }
    }

    private func refreshDomains() async {
        guard let generation = router?.startedAt,
              let result = try? await client.domains(), router?.startedAt == generation else { return }
        domains = result
    }

    private func stream() async {
        while !Task.isCancelled {
            if let generation = router?.startedAt {
                do {
                    // Buffer new events while fetching the initial history.
                    let events = eventClient.events()
                    let initial = try await client.connections(limit: 2000)
                    guard router?.startedAt == generation else { continue }
                    for row in initial { record(row, isNew: false) }
                    for try await event in events {
                        guard router?.startedAt == generation else { break }
                        consume(event)
                    }
                } catch {
                    // The next attempt re-seeds from the router after a restart or disconnect.
                }
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }

    private func consume(_ event: RouterEvent) {
        switch event {
        case .open(let row), .close(let row): record(row, isNew: true)
        case .tick(let tick):
            totals = tick.totals
            for update in tick.openUpdates {
                guard var row = rows[update.id], row.state == .open else { continue }
                row.bytesUp = update.bytesUp
                row.bytesDown = update.bytesDown
                row.rateUp = update.rateUp
                row.rateDown = update.rateDown
                rows[row.id] = row
                recentRates[row.id] = tick.at
            }
            let cutoff = tick.at.addingTimeInterval(-3)
            let expired = recentRates.filter { $0.value <= cutoff }.map(\.key)
            for id in expired {
                rows[id]?.rateDown = 0
                rows[id]?.rateUp = 0
                recentRates.removeValue(forKey: id)
            }

            var rates: [String: Double] = [:]
            for id in recentRates.keys {
                if let row = rows[id], row.state == .open {
                    rates[registrableDomain(row.host), default: 0] += row.rateDown
                }
            }
            let cutoffHistory = tick.at.addingTimeInterval(-120)
            for domain in Set(domainRates.keys).union(rates.keys) {
                var history = domainRates[domain] ?? []
                history.removeAll { $0.at < cutoffHistory }
                let rate = rates[domain] ?? 0
                if rate > 0 || history.contains(where: { $0.value > 0 }) {
                    history.append(MetricPoint(at: tick.at, value: rate))
                    domainRates[domain] = history
                } else {
                    domainRates.removeValue(forKey: domain)
                }
            }
            for route in Route.ordered {
                routeRates[route, default: []].append(MetricPoint(at: tick.at, value: totals[route].rateDown))
                routeRates[route]?.removeAll { $0.at < cutoffHistory }
            }
        }
    }

    private func record(_ row: ConnStat, isNew: Bool) {
        if let previous = rows[row.id], previous.endedAt != nil, row.endedAt == nil { return }
        if isNew && paused && rows[row.id] == nil {
            unseen += 1
        }
        rows[row.id] = row
        if row.state == .open && (row.rateDown > 0 || row.rateUp > 0) {
            recentRates[row.id] = Date()
        } else if row.state != .open {
            recentRates.removeValue(forKey: row.id)
        }
        if rows.count > 5_000 {
            let expired = rows.values.sorted { $0.id < $1.id }.prefix(rows.count - 4_900)
            if paused {
                let expiredIDs = Set(expired.map(\.id))
                frozenRows.removeAll { expiredIDs.contains($0.id) }
            }
            for entry in expired {
                rows.removeValue(forKey: entry.id)
                recentRates.removeValue(forKey: entry.id)
            }
        }
    }

    private func clearRouterData() {
        routerStart = nil
        router = nil
        totals = RouterTotals()
        domains.removeAll()
        rows.removeAll()
        frozenRows.removeAll()
        unseen = 0
        recentRates.removeAll()
        routeRates.removeAll()
        domainRates.removeAll()
        probeHistory.removeAll()
        probeSampleTime.removeAll()
    }

    private func scheduleGrafana(clear: Bool = false) {
        grafanaTask?.cancel()
        if clear { grafana = nil }
        grafanaTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshGrafana()
                do { try await Task.sleep(for: .seconds(self.windowVisible ? 15 : 60)) }
                catch { return }
            }
        }
    }

    private func refreshGrafana() async {
        do {
            let token = try Keychain.get(service: Keychain.grafanaService, account: Keychain.grafanaAccount)
            hasToken = token?.isEmpty == false
            guard let token, !token.isEmpty else { grafana = nil; grafanaFailure = nil; return }
            guard let base = GrafanaClient.baseURL(grafanaURL) else { throw AppError(L.invalidGrafanaURL) }
            let sample = try await grafanaClient.fetch(base: base, token: token)
            guard !Task.isCancelled else { return }
            grafana = sample
            grafanaFailure = sample.failedQueries.isEmpty ? nil : sample.failedQueries.sorted().joined(separator: ", ")
        } catch {
            guard !Task.isCancelled else { return }
            grafanaFailure = error.localizedDescription
        }
    }

    private func seedDemo(at: Date) {
        rules = DemoData.rules
        exits = DemoData.exits
        exitTests = DemoData.exitTests
        vpn = DemoData.status
        router = DemoData.router(0, at: at)
        totals = DemoData.totals(0)
        grafana = DemoData.grafana(0, at: at)
        hasToken = true
        domains = DemoData.domains(0, at: at, rules: rules)
        for (index, domain) in domains.enumerated() {
            let row = DemoData.connectionRow(id: domains.count - index, at: at.addingTimeInterval(Double(-index * 2)),
                                             domain: domain, rank: index)
            rows[row.id] = row
            domainRates[domain.domain] = (-30...0).map { tick in
                let sample = DemoData.rate(domain.route, tick: tick * 4)
                return MetricPoint(at: at.addingTimeInterval(Double(tick) * 4), value: sample * domain.rateDown / 5_000_000)
            }
        }
        for route in Route.ordered {
            routeRates[route] = (-60...0).map { tick in
                MetricPoint(at: at.addingTimeInterval(Double(tick) * 2), value: DemoData.rate(route, tick: tick * 2))
            }
        }
        for probe in router?.probes ?? [] {
            guard let median = probe.medianMs else { continue }
            probeHistory[probe.name] = (-24 ..< 0).map { tick in
                let value = median * (1 + 0.16 * sin(Double(tick)) + 0.12 * cos(Double(tick) / 4))
                return MetricPoint(at: at.addingTimeInterval(Double(tick) * 10), value: value)
            }
        }
        recordProbes(router?.probes ?? [], at: at)
    }

    private func advanceDemo() {
        demoTick += 1
        let now = Date()
        grafana = DemoData.grafana(demoTick, at: now)
        guard on && vpn.router.enabled else { return }
        let snapshot = DemoData.router(demoTick, at: now)
        router = snapshot
        recordProbes(snapshot.probes, at: now)
        domains = DemoData.domains(demoTick, at: now, rules: rules)
        if demoTick.isMultiple(of: 2), !domains.isEmpty {
            let index = demoTick / 2 % domains.count
            let id = (rows.keys.max() ?? 0) + 1
            let row = DemoData.connectionRow(id: id, at: now, domain: domains[index], rank: index)
            record(row, isNew: true)
            let oldestOpen = rows.values.filter { $0.state == .open }.min(by: { $0.id < $1.id })
            if var ended = oldestOpen, now.timeIntervalSince(ended.startedAt) > 20 {
                ended.state = .closed
                ended.endedAt = now
                ended.rateDown = 0
                ended.rateUp = 0
                record(ended, isNew: false)
            }
        }
        let byDomain = Dictionary(uniqueKeysWithValues: domains.map { ($0.domain, $0) })
        let updates = rows.values.compactMap { row -> OpenUpdate? in
            guard row.state == .open, let domain = byDomain[registrableDomain(row.host)] else { return nil }
            let down = domain.rateDown / 3
            let up = domain.rateUp / 3
            return OpenUpdate(id: row.id, bytesUp: row.bytesUp + UInt64(up), bytesDown: row.bytesDown + UInt64(down),
                              rateUp: up, rateDown: down)
        }
        consume(.tick(Tick(at: now, totals: DemoData.totals(demoTick), openUpdates: updates)))
    }

    func demoDecision(_ host: String) -> RouteDecision {
        (try? RuleEngine(rules: rules).decide(host, ciscoUp: vpn.cisco)) ?? .init(route: .vpn)
    }

    private func editDemo(_ args: [String]) {
        guard let command = args.first else { return }
        func index(_ name: String) -> Int? { rules.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        func remove(_ sites: Set<String>, keep: String? = nil) {
            rules = rules.compactMap { rule in
                let domains = rule.domains.filter { !sites.contains($0) }
                let hosts = rule.hosts.filter { !sites.contains($0) }
                guard !domains.isEmpty || !hosts.isEmpty || rule.name == keep else { return nil }
                return Rule(name: rule.name, route: rule.route, withoutCisco: rule.withoutCisco, enabled: rule.enabled,
                            note: rule.note, domains: domains, hosts: hosts)
            }
        }
        switch command {
        case "set", "add-to", "unset":
            let values = Array(args.dropFirst().filter { $0 != "--" })
            if command == "unset", let site = values.first {
                remove([site])
                return
            }
            guard values.count >= 2, let route = Route(rawValue: values[1]) else { return }
            let name = command == "set" ? L.route(route) : values[0]
            let raw = command == "set" ? [values[0]] : Array(values.dropFirst(2))
            let sites = raw.map { input -> String in
                guard input.contains("://"), let url = URL(string: input), let host = url.host else { return input }
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            let currentName = index(name).map { rules[$0].name } ?? name
            remove(Set(sites), keep: currentName)
            let position = index(name)
            let old = position.map { rules[$0] } ?? Rule(name: name, route: route)
            let domainSites = sites.filter { $0.contains(".") }
            let hostSites = sites.filter { !$0.contains(".") }
            let new = Rule(name: old.name, route: old.route, withoutCisco: old.withoutCisco, enabled: old.enabled,
                           note: old.note, domains: old.domains + domainSites, hosts: old.hosts + hostSites)
            if let position { rules[position] = new } else { rules.append(new) }
        case "rule-delete":
            if let position = args.last.flatMap(index) { rules.remove(at: position) }
        case "rule-move":
            if let position = args.last.flatMap(index), args.count >= 3, let to = Int(args[2]), rules.indices.contains(to) {
                rules.insert(rules.remove(at: position), at: to)
            }
        case "rule-set":
            guard let position = args.last.flatMap(index) else { return }
            let old = rules[position]
            func option(_ key: String) -> String? {
                let prefix = "--" + key + "="
                return args.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            }
            let route = option("route").flatMap(Route.init(rawValue:)) ?? old.route
            let fallback = option("without-cisco").map(Route.init(rawValue:)) ?? old.withoutCisco
            rules[position] = Rule(name: option("rename") ?? old.name, route: route, withoutCisco: route == .cisco ? fallback : nil,
                                   enabled: option("enabled").map { $0 == "true" } ?? old.enabled,
                                   note: option("note") ?? old.note, domains: old.domains, hosts: old.hosts)
        default: break
        }
    }
}

private func isIPAddress(_ value: String) -> Bool {
    IPv4Address(value) != nil || IPv6Address(value) != nil
}
extension AppModel {
    private var exitsFile: URL { paths.stateDir.appendingPathComponent("exits.json") }

    private var setupHasNoExits: Bool {
        guard let data = try? Data(contentsOf: exitsFile),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = document["exits"] as? [Any] else {
            return !FileManager.default.fileExists(atPath: exitsFile.path)
        }
        return entries.isEmpty
    }

    private func refreshExits() async {
        do { try await readExits(using: cli) }
        catch { exitsFailure = publicExitError(error.localizedDescription) }
    }

    private func readExits(using cli: CLI) async throws {
        guard !demo else { return }
        let request = UUID()
        exitsReadID = request
        let result = await cli.configuration(["exits", "--json"])
        guard exitsReadID == request else { return }
        let listing = try result.decode(ExitListing.self)
        exits = listing
        exitsFailure = nil
        let ids = Set(listing.exits.map(\.id))
        exitTests = exitTests.filter { ids.contains($0.key) }
    }

    func addExit(_ input: ExitInput) async throws -> [String] {
        try await runExitAction { cli in
            if demo { return addDemoExit(input) }
            if try setupHasNoExits || connectionData() == nil {
                _ = try await cli.configuration(["init"]).checked()
                settingsRevision += 1
            }

            let ids: [String]
            switch input {
            case .links(let links):
                ids = try await cli.configuration(["exit-add", "--json", "--"] + links).decode(AddedExits.self).ids
            case .subscription(let url):
                let added = try await cli.configuration(["sub-add", "--json", "--", url]).decode(AddedSubscription.self)
                try await readExits(using: cli)
                ids = exits.exits.filter { $0.subscription == added.id }.map(\.id)
            case let .ssh(host, port, user, password):
                let added = try await cli.configuration(["exit-add-ssh", "--json", "--", host, String(port), user])
                    .decode(AddedExits.self)
                guard let id = added.ids.first else { throw AppError(L.noExitAdded) }
                do {
                    try Keychain.set(password, service: Keychain.sshService, account: id)
                } catch {
                    let credentialError = error
                    do { _ = try await cli.configuration(ExitMutation.remove(id).command).checked() }
                    catch { throw AppError(credentialError.localizedDescription + "\n" + error.localizedDescription) }
                    throw credentialError
                }
                ids = added.ids
            }
            try await readExits(using: cli)
            guard !ids.isEmpty else { throw AppError(L.noExitAdded) }
            return ids
        }
    }

    func mutateExit(_ mutation: ExitMutation) {
        guard !working else { return }
        Task {
            _ = try? await runExitAction { cli in
                if demo {
                    editDemoExit(mutation)
                } else if case .activate(let id) = mutation {
                    _ = try await cli.run(["exit", "use", id]).checked()
                    await refreshVPN()
                    await refreshRouter()
                } else {
                    _ = try await cli.configuration(mutation.command).checked()
                }
                try await readExits(using: cli)
            }
        }
    }

    func testExits(_ ids: [String], all: Bool = false) async throws -> [ExitTestResult] {
        try await runExitAction(successToast: false) { cli in
            let selected = all ? exits.exits.map(\.id) : ids
            testingExits = Set(selected)
            defer { testingExits.removeAll() }
            let results: [ExitTestResult]
            if demo {
                try await Task.sleep(for: .milliseconds(500))
                results = selected.map { exitTests[$0] ?? .init(id: $0, ok: true, connectMs: 92, mbps: 31.4) }
            } else {
                let args = all ? ["exit-test", "--all", "--json"] : ["exit-test", "--json", "--"] + ids
                results = try await cli.configuration(args).decode([ExitTestResult].self)
            }
            for test in results { exitTests[test.id] = test }
            return results
        }
    }

    func saveWizardSettings(routerMode: Bool, launch: Bool, terminalCommand: Bool) async throws {
        try await runExitAction(successToast: false) { cli in
            if demo {
                demoDraft.routerEnabled = routerMode
            } else {
                if try setupHasNoExits || connectionData() == nil {
                    _ = try await cli.configuration(["init"]).checked()
                }
                var (draft, original) = try loadDraft()
                if draft.routerEnabled != routerMode {
                    draft.routerEnabled = routerMode
                    try await writeConnection(draft, original: original, using: cli)
                }
                if terminalCommand { try installTerminalCommand() }
            }
            try updateLogin(launch)
        }
    }

    func connectFromSetup(exit id: String) async throws {
        try await runExitAction(successToast: false, connecting: true) { cli in
            if demo {
                try await Task.sleep(for: .milliseconds(600))
                editDemoExit(.activate(id))
                vpn = DemoData.status
                vpn.router.enabled = demoDraft.routerEnabled
                vpn.router.running = demoDraft.routerEnabled
                if vpn.router.running { advanceDemo() }
                else { clearRouterData() }
                return
            }
            // The wizard owns the final start, so selecting an exit here does not restart the tunnel first.
            if exits.active != id {
                _ = try await cli.configuration(ExitMutation.activate(id).command).checked()
                try await readExits(using: cli)
            }
            _ = try await cli.run(["on"]).checked()
            await refreshVPN()
            await refreshRouter()
            guard on else { throw AppError(statusFailure ?? vpn.stopped ?? L.setupConnectionFailed) }
        }
    }

    private func updateLogin(_ enabled: Bool) throws {
        guard enabled != loginEnabled else { return }
        if !demo {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        }
        loginEnabled = demo ? enabled : SMAppService.mainApp.status == .enabled
    }

    private func installTerminalCommand() throws {
        let fm = FileManager.default
        let target = AppResources.bundledCLI
        guard AppResources.isPackaged, fm.isExecutableFile(atPath: target.path) else {
            throw AppError(L.terminalBundleMissing)
        }
        let directory = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("vpn")
        if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let existing = URL(fileURLWithPath: destination, relativeTo: directory).standardizedFileURL
            guard existing.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() else {
                throw AppError(L.terminalPathTaken)
            }
            return
        }
        do { try fm.createSymbolicLink(at: link, withDestinationURL: target) }
        catch let error as CocoaError where error.code == .fileWriteFileExists { throw AppError(L.terminalPathTaken) }
    }

    private func runExitAction<Result>(
        successToast: Bool = true, connecting: Bool = false,
        _ action: (CLI) async throws -> Result
    ) async throws -> Result {
        guard !working else { throw AppError(L.working) }
        working = true
        self.connecting = connecting
        outputLine = ""
        defer {
            working = false
            self.connecting = false
            outputLine = ""
        }
        do {
            let result = try await action(cli)
            if successToast { announce(L.applied) }
            return result
        } catch {
            if !demo { await refreshExits() }
            let message = publicExitError(error.localizedDescription)
            announce(message, failed: true)
            throw AppError(message)
        }
    }

    private func addDemoExit(_ input: ExitInput) -> [String] {
        let subscription: String?
        let entries: [ExitListing.Exit]
        switch input {
        case .links(let links):
            subscription = nil
            entries = links.map { link in
                let url = URLComponents(string: link)
                let family = url?.scheme.flatMap(ExitListing.Transport.init(rawValue:)) ?? .vless
                return .init(id: UUID().uuidString, name: url?.fragment ?? family.label,
                             kind: .xray, transport: family, address: url?.host ?? "edge.example.net", port: url?.port ?? 443)
            }
        case .subscription(let url):
            let id = UUID().uuidString
            let host = URLComponents(string: url)?.host ?? "edge.example.net"
            subscription = id
            entries = [
                .init(id: UUID().uuidString, name: "Frankfurt", kind: .xray, transport: .vless, address: "fra.example.net", port: 443, subscription: id),
                .init(id: UUID().uuidString, name: "Helsinki", kind: .xray, transport: .trojan, address: "hel.example.net", port: 443, subscription: id)
            ]
            exits.subscriptions.append(.init(id: id, name: host, host: host, count: entries.count,
                                             updatedAt: ISO8601DateFormatter().string(from: Date()), error: nil))
        case let .ssh(host, port, _, _):
            subscription = nil
            entries = [.init(id: UUID().uuidString, name: host, kind: .ssh, transport: .ssh, address: host, port: port)]
        }
        exits.exits.append(contentsOf: entries)
        if exits.active == nil, subscription == nil { exits.active = entries.first?.id }
        return entries.map(\.id)
    }

    private func editDemoExit(_ mutation: ExitMutation) {
        switch mutation {
        case .activate(let id):
            exits.active = id
            exits.exits.removeAll { $0.id != id && $0.stale }
        case .rename(let id, let name):
            if let index = exits.exits.firstIndex(where: { $0.id == id }) { exits.exits[index].name = name }
        case .remove(let id):
            if let group = exits.exits.first(where: { $0.id == id })?.subscription,
               let index = exits.subscriptions.firstIndex(where: { $0.id == group }) {
                exits.subscriptions[index].count -= 1
            }
            exits.exits.removeAll { $0.id == id }
            exitTests[id] = nil
        case .updateSubscription(let id):
            if let index = exits.subscriptions.firstIndex(where: { $0.id == id }) {
                exits.subscriptions[index].updatedAt = ISO8601DateFormatter().string(from: Date())
                exits.subscriptions[index].error = nil
            }
        case .removeSubscription(let id):
            exits.subscriptions.removeAll { $0.id == id }
            for exit in exits.exits where exit.subscription == id { exitTests[exit.id] = nil }
            exits.exits.removeAll { $0.subscription == id }
        }
    }
}
