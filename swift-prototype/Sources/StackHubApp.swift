import SwiftUI
import AppKit
import Combine

private final class StackHubPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StackHubAppDelegate: NSObject, NSApplicationDelegate {
    let store = StackHubStore()
    private let appUpdater = AppUpdater()
    private var statusItem: NSStatusItem?
    private var panelWindow: NSPanel?
    private var statusObservation: AnyCancellable?
    private var localPopoverDismissMonitor: Any?
    private var globalPopoverDismissMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        appUpdater.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // AppKit invokes this delegate callback on the main thread. The store
        // owns the Process instances, so stop them before the app exits.
        store.stopAllServices()
        return .terminateNow
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(togglePanel(_:))
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
        button.toolTip = "StackHub"
        statusItem = item

        // NSPopover always owns a native arrow and bezel. That bezel becomes
        // visible as a light fringe around our fully custom dark surface, so
        // use a borderless panel anchored beneath the status item instead.
        let panel = StackHubPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 640),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Stay above normal windows while allowing native modal alerts above us.
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentViewController = NSHostingController(
            rootView: StackHubPanel().environmentObject(store).environmentObject(appUpdater)
        )
        panelWindow = panel

        statusObservation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let statusItem, let button = statusItem.button else { return }
        let status = store.menuBarPipelineStatus
        let image = MenuBarStatusImage.make(running: status.running, failures: status.unreadFailures)
        button.attributedTitle = NSAttributedString(string: "")
        button.image = image
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(image.accessibilityDescription)
        statusItem.length = image.size.width + 4
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem?.button, let panelWindow else { return }
        if panelWindow.isVisible {
            guard !PanelDismissalPolicy.isPresentingModal(panel: panelWindow, modalWindow: NSApp.modalWindow) else { return }
            panelWindow.orderOut(sender)
            removePopoverDismissMonitors()
        } else {
            showPanel(panelWindow, below: button)
            installPopoverDismissMonitors()
        }
    }

    private func showPanel(_ panel: NSPanel, below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panelFrame = panel.frame
        let horizontalMargin: CGFloat = 8
        let originX = min(
            max(buttonFrame.midX - panelFrame.width / 2, screenFrame.minX + horizontalMargin),
            screenFrame.maxX - panelFrame.width - horizontalMargin
        )
        let originY = max(screenFrame.minY + horizontalMargin, buttonFrame.minY - panelFrame.height - 6)
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // The panel is reused, so reopening it does not fire SwiftUI onAppear.
        // Acknowledge unread failures on every successful presentation.
        store.acknowledgeCIFailures()
        updateStatusItem()
    }

    private func installPopoverDismissMonitors() {
        removePopoverDismissMonitors()
        localPopoverDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panelWindow, panel.isVisible else { return event }
            if PanelDismissalPolicy.shouldDismiss(panel: panel, clickedWindow: event.window, modalWindow: NSApp.modalWindow) {
                panel.orderOut(nil)
                self.removePopoverDismissMonitors()
            }
            return event
        }
        globalPopoverDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let panel = self.panelWindow, panel.isVisible,
                      PanelDismissalPolicy.shouldDismiss(panel: panel, clickedWindow: nil, modalWindow: NSApp.modalWindow)
                else { return }
                panel.orderOut(nil)
                self.removePopoverDismissMonitors()
            }
        }
    }

    private func removePopoverDismissMonitors() {
        if let localPopoverDismissMonitor {
            NSEvent.removeMonitor(localPopoverDismissMonitor)
            self.localPopoverDismissMonitor = nil
        }
        if let globalPopoverDismissMonitor {
            NSEvent.removeMonitor(globalPopoverDismissMonitor)
            self.globalPopoverDismissMonitor = nil
        }
    }
}

@main
struct StackHubApp {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let appDelegate = StackHubAppDelegate()
        application.delegate = appDelegate
        application.run()
    }
}

// MARK: - Models

enum PanelTab: String, CaseIterable, Identifiable {
    case projects = "项目"
    case ci = "CI"
    var id: String { rawValue }
    var title: String { L(rawValue) }
}

struct LanguageSelector: View {
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.system.rawValue

    var body: some View {
        Menu {
            Picker(L("语言"), selection: $languageRawValue) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.menuTitle).tag(language.rawValue)
                }
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(PanelHeaderIconButtonStyle())
        .help(L("切换语言"))
        .accessibilityLabel(L("切换语言"))
    }
}

enum PanelDestination: Equatable {
    case projectEditor
    case ciInstanceManagement
    case githubAuthorization
    case gitLabEditor
}

/// MenuBarExtra does not reliably route Escape through SwiftUI's
/// `onExitCommand`, especially while a text field is focused. Use an AppKit
/// local monitor for the short-lived full-panel detail views instead.
struct EscapeKeyCloseHandler: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, !event.isARepeat else { return event }
                DispatchQueue.main.async { self?.onEscape() }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}

extension View {
    func closesOnEscape(perform action: @escaping () -> Void) -> some View {
        background(EscapeKeyCloseHandler(onEscape: action).frame(width: 0, height: 0))
    }
}

enum ServiceStatus: String, Codable {
    case running, starting, warning, stopped, failed
    var color: Color {
        switch self {
        case .running: return .green
        case .starting: return .orange
        case .warning: return .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }
    var label: String {
        switch self {
        case .running: return L("运行中")
        case .starting: return L("启动中")
        case .warning: return L("警告")
        case .stopped: return L("已停止")
        case .failed: return L("失败")
        }
    }

    var hasManagedProcess: Bool {
        self == .starting || self == .running || self == .warning
    }
}

struct Service: Identifiable, Codable {
    let id: String
    let name: String
    let command: String
    let url: String
    var status: ServiceStatus
    // Optional so saved services from earlier versions keep decoding and
    // continue to use their project's working directory.
    var directory: String? = nil
    // An empty list means startup leaves every port untouched. Older saved
    // services used a single `port`; custom decoding migrates it to this list.
    var ports: [Int] = []

    private enum CodingKeys: String, CodingKey {
        case id, name, command, url, status, directory, ports, port
    }

    init(id: String, name: String, command: String, url: String, status: ServiceStatus, directory: String? = nil, ports: [Int] = []) {
        self.id = id
        self.name = name
        self.command = command
        self.url = url
        self.status = status
        self.directory = directory
        self.ports = ports
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        url = try container.decode(String.self, forKey: .url)
        status = try container.decode(ServiceStatus.self, forKey: .status)
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
        if let configuredPorts = try container.decodeIfPresent([Int].self, forKey: .ports) {
            ports = configuredPorts
        } else if let legacyPort = try container.decodeIfPresent(Int.self, forKey: .port) {
            ports = [legacyPort]
        } else {
            ports = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(url, forKey: .url)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(directory, forKey: .directory)
        try container.encode(ports, forKey: .ports)
    }
}

struct Project: Identifiable, Codable {
    let id: String
    let name: String
    let initial: String
    let serviceCount: Int
    let issue: Bool
    var isExpanded: Bool
    var services: [Service]
    var directory: String
}

enum ProjectRuntimeState: Equatable {
    case ready, partial, stopped, issue

    var label: String {
        switch self {
        case .ready: return L("已就绪")
        case .partial: return L("部分运行")
        case .stopped: return L("已停止")
        case .issue: return L("服务警告")
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .partial: return .orange
        case .stopped: return .gray
        case .issue: return .orange
        }
    }
}

extension Project {
    var hasServiceIssue: Bool {
        issue || services.contains { $0.status == .warning || $0.status == .failed }
    }

    var runtimeState: ProjectRuntimeState {
        if hasServiceIssue { return .issue }
        guard !services.isEmpty else { return .stopped }
        if services.allSatisfy({ $0.status == .running }) { return .ready }
        if services.contains(where: { $0.status.hasManagedProcess }) { return .partial }
        return .stopped
    }
}

struct GitLabInstance: Identifiable, Codable {
    let id: UUID
    var name: String
    var host: String
    var project: String
    var isConnected: Bool = true
}

/// CI 关注项目与本地开发项目是两套独立的数据源。
/// 本地 Project 只服务于“项目”页；这里的项目只描述要关注的远端流水线。
struct CIMonitoredProject: Identifiable, Codable {
    let id: String
    var name: String
    var provider: String
    var repository: String
    var branch: String
    var instanceName: String?
}

/// 已建立索引、但不一定被用户关注的远端项目。
/// 这份缓存用于 CI 页底部的跨项目活动列表，避免每次刷新都重新遍历项目。
struct CIAccessibleProject: Identifiable, Codable {
    let id: String
    var name: String
    var provider: String
    var repository: String
    var branch: String
    var instanceName: String?
    // GitHub's repository `updated_at`, used as the incremental sync cursor.
    // GitLab does not populate this field.
    var updatedAt: Date? = nil
    // Optional for decoding older indexes, which included collaborator/org
    // repositories and must be rediscovered before showing GitHub projects.
    var isOwnedByCurrentUser: Bool? = nil

    var isInRepositoryScope: Bool {
        provider != "GitHub Actions" || isOwnedByCurrentUser == true
    }
}

enum PipelineState: String, Codable {
    case success, failed, running
    var color: Color {
        switch self {
        case .success: return .green
        case .failed: return .red
        case .running: return .blue
        }
    }
    var label: String {
        switch self {
        case .success: return L("成功")
        case .failed: return L("失败")
        case .running: return L("运行中")
        }
    }
}

struct PipelineStage: Identifiable, Codable {
    let id: String
    let name: String
    let duration: String
    let state: PipelineState
    let log: String
    /// CI providers expose individual jobs. GitLab also assigns those jobs to
    /// a named stage, which lets the UI present one stage with dynamic jobs
    /// underneath instead of treating every job as a linear pipeline step.
    let group: String?

    init(
        id: String,
        name: String,
        duration: String,
        state: PipelineState,
        log: String,
        group: String? = nil
    ) {
        self.id = id
        self.name = name
        self.duration = duration
        self.state = state
        self.log = log
        self.group = group
    }
}

struct PipelineStageGroup: Identifiable {
    let id: String
    let name: String
    let jobs: [PipelineStage]

    var state: PipelineState {
        if jobs.contains(where: { $0.state == .failed }) { return .failed }
        if jobs.contains(where: { $0.state == .running }) { return .running }
        return .success
    }
}

extension Array where Element == PipelineStage {
    /// Preserve the provider response order while grouping GitLab's jobs by
    /// their stage. A missing group is a single standalone job (as returned
    /// by GitHub Actions and legacy cached data).
    var groupedPipelineStages: [PipelineStageGroup] {
        var names: [String] = []
        var jobsByName: [String: [PipelineStage]] = [:]

        for job in self {
            let normalizedGroup = job.group?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = normalizedGroup.flatMap { $0.isEmpty ? nil : $0 } ?? job.name
            if jobsByName[name] == nil { names.append(name) }
            jobsByName[name, default: []].append(job)
        }

        return names.enumerated().map { index, name in
            PipelineStageGroup(id: "\(index)-\(name)", name: name, jobs: jobsByName[name] ?? [])
        }
    }
}

struct Pipeline: Identifiable, Codable {
    let id: String
    let projectID: String
    let provider: String
    let repository: String
    let branch: String
    let commit: String
    let duration: String
    let state: PipelineState
    let stages: [PipelineStage]
    let updatedAt: Date?
    let startedAt: Date?
    let webURL: String?
    /// Summary cards start with a single placeholder stage. This flag keeps
    /// that placeholder distinct from real job/stage data.
    let hasLoadedStages: Bool

    init(
        id: String,
        projectID: String,
        provider: String,
        repository: String,
        branch: String,
        commit: String,
        duration: String,
        state: PipelineState,
        stages: [PipelineStage],
        updatedAt: Date?,
        webURL: String?,
        startedAt: Date? = nil,
        hasLoadedStages: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.provider = provider
        self.repository = repository
        self.branch = branch
        self.commit = commit
        self.duration = duration
        self.state = state
        self.stages = stages
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.webURL = webURL
        self.hasLoadedStages = hasLoadedStages
    }
}

extension Pipeline {
    /// The compact execution-time copy used by followed-project cards.
    var executionDurationLabel: String? {
        guard duration != "—" else { return nil }
        return LF("执行 %@", duration)
    }

    /// Prefer the actual start time when a provider exposes it; older cached
    /// runs fall back to their update time so the card still has useful timing.
    var executionTimestampLabel: String {
        guard let date = startedAt ?? updatedAt else { return L("执行时间未知") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.selected.locale
        formatter.unitsStyle = .short
        return LF("执行于 %@", formatter.localizedString(for: date, relativeTo: Date()))
    }
}

@MainActor
final class StackHubStore: ObservableObject {
    private struct CredentialBundle: Codable {
        var githubAccessToken: String?
        var githubRefreshToken: String?
        var gitLabTokens: [String: String]

        init(githubAccessToken: String? = nil, githubRefreshToken: String? = nil, gitLabTokens: [String: String] = [:]) {
            self.githubAccessToken = githubAccessToken
            self.githubRefreshToken = githubRefreshToken
            self.gitLabTokens = gitLabTokens
        }
    }

    private static let projectIndexOrderVersion = 1
    private static let projectIndexOrderVersionKey = "stackhub.ci.index-order-version"
    private static let stagePrefetchProjectLimit = 8
    private static let githubRepositoryLimit = GitHubAPIClient.recentRepositoryLimit
    private static let githubFullDiscoveryInterval: TimeInterval = 24 * 60 * 60
    private static let pipelineCacheKey = "stackhub.ci.pipeline-cache"
    private static let githubRepositorySyncDateKey = "stackhub.ci.github-repository-sync-date"
    private static let githubFullDiscoveryDateKey = "stackhub.ci.github-full-discovery-date"
    private static let gitLabPipelineSyncDateKey = "stackhub.ci.gitlab-pipeline-sync-dates"
    private static let gitLabProjectPipelineSyncDateKey = "stackhub.ci.gitlab-project-pipeline-sync-dates"
    private static let gitLabGlobalPipelineCapabilityKey = "stackhub.ci.gitlab-global-pipeline-capabilities"
    private static let acknowledgedFailedPipelineIDsKey = "stackhub.ci.acknowledged-failure-ids"
    // The global GitLab feed filters by creation time. Keep a small overlap so
    // a refresh that lands on the cursor boundary cannot lose a pipeline.
    private static let gitLabPipelineSyncOverlap: TimeInterval = 90
    private static let githubConnectedMetadataKey = "stackhub.github.connected"
    private static let credentialBundleAccount = "ci.credentials.v1"
    static let ciRefreshInterval: TimeInterval = 30

    @Published var tab: PanelTab = .projects
    @Published var projects: [Project] = []
    @Published var instances: [GitLabInstance] = []
    // CI 关注项目独立于 projects；增删/选择它们不会影响本地项目页。
    @Published var ciProjects: [CIMonitoredProject] = []
    /// 首次同步后保存在本地的可访问项目索引，刷新时只增量更新这份列表。
    @Published var accessibleCIProjects: [CIAccessibleProject] = []
    @Published var pipelineCache: [String: [Pipeline]] = [:]
    @Published var isRefreshingCI = false
    @Published var lastCIRefresh: Date?
    @Published var lastCIProjectDiscovery: Date?
    @Published var ciError: String?
    private(set) var lastGitHubRepositorySync: Date?
    private(set) var lastGitHubFullDiscovery: Date?
    private var gitLabPipelineSyncDates: [String: Date] = [:]
    private var gitLabProjectPipelineSyncDates: [String: Date] = [:]
    /// `GET /pipelines` exists only on newer GitLab releases. Remember a
    /// confirmed 404/405 so older instances do not pay for the same failed
    /// feature probe on every 30-second refresh.
    private var gitLabGlobalPipelineCapabilities: [String: Bool] = [:]
    /// Detail lookups are demand-loaded for visible activity cards. Keep the
    /// in-flight set separate from the refresh cursor so opening a long list
    /// never creates duplicate per-pipeline requests.
    private var hydratingGitLabPipelineTimingIDs: Set<String> = []
    /// Failures remain visible in the menu bar until the panel has been
    /// opened. Persist this small acknowledgement set so a relaunch does not
    /// re-notify failures the user has already seen.
    @Published private(set) var acknowledgedFailedPipelineIDs: Set<String> = []
    @Published var selectedInstanceID: UUID?
    @Published var selectedCIProjectID: String?
    @Published var expandedStageID: String? = "test"
    @Published var selectedPipeline: Pipeline?
    @Published var selectedServiceLogID: String?
    /// Credential state is non-sensitive metadata for the UI. Reading Keychain
    /// is deferred until an action actually needs a token.
    @Published private(set) var isGitHubConnected = false
    @Published private(set) var gitLabCredentialHosts: Set<String> = []
    private var toastDismissTask: Task<Void, Never>?
    @Published var toast: String? {
        didSet {
            toastDismissTask?.cancel()
            guard let message = toast else { return }
            toastDismissTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    return
                }
                guard let self, self.toast == message else { return }
                self.toast = nil
            }
        }
    }
    @Published var serviceLogs: [String: String] = [:]
    @Published private(set) var loadingStageIDs: Set<String> = []
    private var runningProcesses: [String: Process] = [:]
    private var intentionallyStoppingServiceIDs: Set<String> = []
    private var restartPendingServiceIDs: Set<String> = []
    private var githubAccessTokenCache: String?
    private var githubRefreshTokenCache: String?
    private var gitLabTokenCache: [String: String] = [:]
    private var credentialBundle = CredentialBundle()
    private var didLoadCredentialBundle = false
    private let defaults: UserDefaults
    private let ciSession: URLSession
    private let ciCredentialProvider: CICredentialProvider?
    private let ciRefreshScheduler: CIRefreshScheduler
    private var ciRefreshTasks: [CISource: Task<Void, Never>] = [:]
    private var ciSourceErrors: [CISource: String] = [:]
    private var offlineCISources: Set<CISource> = []

    init(defaults: UserDefaults = .standard, ciSession: URLSession = CIHTTPTransport.session,
         ciCredentialProvider: CICredentialProvider? = nil, ciRefreshScheduler: CIRefreshScheduler? = nil) {
        self.defaults = defaults
        self.ciSession = ciSession
        self.ciCredentialProvider = ciCredentialProvider
        self.ciRefreshScheduler = ciRefreshScheduler ?? CIRefreshScheduler()
        loadPersistedState()
        loadCredentialMetadata()
        selectedInstanceID = instances.first?.id
        selectedCIProjectID = ciProjects.first?.id
    }

    var selectedInstance: GitLabInstance? {
        instances.first(where: { $0.id == selectedInstanceID }) ?? instances.first
    }

    var selectedCIProject: CIMonitoredProject? {
        ciProjects.first(where: { $0.id == selectedCIProjectID }) ?? ciProjects.first
    }

    var selectedServiceLog: Service? {
        projects.lazy.flatMap(\.services).first(where: { $0.id == selectedServiceLogID })
    }

    var visibleFollowedCIProjects: [CIMonitoredProject] {
        let ownedGitHubIDs = Set(accessibleCIProjects.filter {
            $0.provider == "GitHub Actions" && $0.isInRepositoryScope
        }.map(\.id))
        // Keep saved follow preferences; only hide out-of-scope GitHub entries.
        return ciProjects.filter {
            $0.provider != "GitHub Actions" || ownedGitHubIDs.contains($0.id)
        }
    }

    var selectedGitLabCIProject: CIMonitoredProject? {
        ciProjects.first(where: { $0.provider == "GitLab CI" && $0.instanceName == selectedInstance?.name })
            ?? ciProjects.first(where: { $0.provider == "GitLab CI" })
    }

    /// 关注项目只读取本地缓存的最近流水线，不触发项目发现。
    func recentPipelines(for project: CIMonitoredProject) -> [Pipeline] {
        (pipelineCache[project.id] ?? []).sorted(by: CIActivityOrdering.newestFirst)
    }

    var recentCIActivities: [CIProjectActivity] {
        CIActivityOrdering.latestActivities(projects: accessibleCIProjects, pipelineCache: pipelineCache)
    }

    var menuBarPipelineStatus: CIPipelineStatusCounts {
        CIPipelineStatusCounter.counts(
            in: pipelineCache,
            acknowledgedFailureIDs: acknowledgedFailedPipelineIDs
        )
    }

    func acknowledgeCIFailures() {
        let failedIDs = CIPipelineStatusCounter.failedPipelineIDs(in: pipelineCache)
        guard acknowledgedFailedPipelineIDs != failedIDs else { return }
        acknowledgedFailedPipelineIDs = failedIDs
        defaults.set(Array(failedIDs).sorted(), forKey: Self.acknowledgedFailedPipelineIDsKey)
    }

    func hasGitLabCredential(_ instance: GitLabInstance) -> Bool {
        gitLabCredentialHosts.contains(instance.host)
    }

    private func loadCredentialMetadata() {
        // Older installations do not have the GitHub flag. A saved GitHub
        // project index is enough to display its previous connection without
        // prompting for Keychain access on app launch.
        isGitHubConnected = defaults.bool(forKey: Self.githubConnectedMetadataKey)
            || accessibleCIProjects.contains(where: { $0.provider == "GitHub Actions" })
        gitLabCredentialHosts = Set(instances.filter(\.isConnected).map(\.host))
    }

    /// Reads one Keychain item only when a credential is actually needed. The
    /// bundle replaces the old per-provider items for new and migrated tokens.
    private func loadCredentialBundle() -> CredentialBundle {
        guard !didLoadCredentialBundle else { return credentialBundle }
        didLoadCredentialBundle = true
        guard let data = KeychainVault.shared.readData(account: Self.credentialBundleAccount),
              let decoded = try? JSONDecoder().decode(CredentialBundle.self, from: data) else {
            return credentialBundle
        }
        credentialBundle = decoded
        return decoded
    }

    private func saveCredentialBundle(_ bundle: CredentialBundle) throws {
        let data = try JSONEncoder().encode(bundle)
        try KeychainVault.shared.save(data: data, account: Self.credentialBundleAccount)
        credentialBundle = bundle
        didLoadCredentialBundle = true
    }

    func loadPersistedState() {
        if let data = defaults.data(forKey: "stackhub.local.projects"),
           let saved = try? JSONDecoder().decode([Project].self, from: data) {
            projects = saved
        }
        if let data = defaults.data(forKey: "stackhub.gitlab.instances"),
           let saved = try? JSONDecoder().decode([GitLabInstance].self, from: data) {
            instances = saved
        }
        if let data = defaults.data(forKey: "stackhub.ci.followed"),
           let saved = try? JSONDecoder().decode([CIMonitoredProject].self, from: data) {
            ciProjects = saved.filter { !$0.id.hasPrefix("ci-") }
        }
        if let data = defaults.data(forKey: "stackhub.ci.accessible"),
           let saved = try? JSONDecoder().decode([CIAccessibleProject].self, from: data) {
            accessibleCIProjects = saved.filter { !$0.id.hasPrefix("ci-") && $0.isInRepositoryScope }
        }
        if let data = defaults.data(forKey: Self.pipelineCacheKey),
           let saved = try? JSONDecoder().decode([String: [Pipeline]].self, from: data) {
            pipelineCache = saved
        }
        acknowledgedFailedPipelineIDs = Set(
            defaults.stringArray(forKey: Self.acknowledgedFailedPipelineIDsKey) ?? []
        )
        reconcileAcknowledgedFailures()
        // Older indexes were persisted in arbitrary dictionary order. Rebuild
        // once so limited repository requests also keep the API's recent order.
        if defaults.integer(forKey: Self.projectIndexOrderVersionKey) == Self.projectIndexOrderVersion {
            lastCIProjectDiscovery = defaults.object(forKey: "stackhub.ci.discovery-date") as? Date
        } else {
            lastCIProjectDiscovery = nil
        }
        lastGitHubRepositorySync = defaults.object(forKey: Self.githubRepositorySyncDateKey) as? Date
        lastGitHubFullDiscovery = defaults.object(forKey: Self.githubFullDiscoveryDateKey) as? Date
        if let data = defaults.data(forKey: Self.gitLabPipelineSyncDateKey),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            gitLabPipelineSyncDates = saved
        }
        if let data = defaults.data(forKey: Self.gitLabProjectPipelineSyncDateKey),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            gitLabProjectPipelineSyncDates = saved
        }
        if let data = defaults.data(forKey: Self.gitLabGlobalPipelineCapabilityKey),
           let saved = try? JSONDecoder().decode([String: Bool].self, from: data) {
            gitLabGlobalPipelineCapabilities = saved
        }
    }

    func persistCIState() {
        reconcileAcknowledgedFailures()
        if let data = try? JSONEncoder().encode(projects) { defaults.set(data, forKey: "stackhub.local.projects") }
        if let data = try? JSONEncoder().encode(instances) { defaults.set(data, forKey: "stackhub.gitlab.instances") }
        if let data = try? JSONEncoder().encode(ciProjects) { defaults.set(data, forKey: "stackhub.ci.followed") }
        if let data = try? JSONEncoder().encode(accessibleCIProjects) { defaults.set(data, forKey: "stackhub.ci.accessible") }
        if let data = try? JSONEncoder().encode(pipelineCache) { defaults.set(data, forKey: Self.pipelineCacheKey) }
        defaults.set(lastCIProjectDiscovery, forKey: "stackhub.ci.discovery-date")
        defaults.set(lastGitHubRepositorySync, forKey: Self.githubRepositorySyncDateKey)
        defaults.set(lastGitHubFullDiscovery, forKey: Self.githubFullDiscoveryDateKey)
        if let data = try? JSONEncoder().encode(gitLabPipelineSyncDates) {
            defaults.set(data, forKey: Self.gitLabPipelineSyncDateKey)
        }
        if let data = try? JSONEncoder().encode(gitLabProjectPipelineSyncDates) {
            defaults.set(data, forKey: Self.gitLabProjectPipelineSyncDateKey)
        }
        if let data = try? JSONEncoder().encode(gitLabGlobalPipelineCapabilities) {
            defaults.set(data, forKey: Self.gitLabGlobalPipelineCapabilityKey)
        }
        defaults.set(Array(acknowledgedFailedPipelineIDs).sorted(), forKey: Self.acknowledgedFailedPipelineIDsKey)
    }

    private func reconcileAcknowledgedFailures() {
        acknowledgedFailedPipelineIDs.formIntersection(
            CIPipelineStatusCounter.failedPipelineIDs(in: pipelineCache)
        )
    }

    private func clearGitLabRefreshState(for instanceID: UUID) {
        invalidateCIRefresh(.gitlab(instanceID))
        let instanceKey = instanceID.uuidString
        gitLabPipelineSyncDates.removeValue(forKey: instanceKey)
        gitLabGlobalPipelineCapabilities.removeValue(forKey: instanceKey)
        let projectKeyPrefix = "\(instanceKey):gitlab:\(instanceKey):"
        gitLabProjectPipelineSyncDates = gitLabProjectPipelineSyncDates.filter {
            !$0.key.hasPrefix(projectKeyPrefix)
        }
    }

    func saveGitHubToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            var bundle = loadCredentialBundle()
            bundle.githubAccessToken = trimmed
            bundle.githubRefreshToken = nil
            try saveCredentialBundle(bundle)
            KeychainVault.shared.delete(account: "github")
            KeychainVault.shared.delete(account: "github.refresh")
            UserDefaults.standard.removeObject(forKey: GitHubOAuthConfiguration.accessTokenExpiryKey)
            githubAccessTokenCache = trimmed
            githubRefreshTokenCache = nil
            isGitHubConnected = true
            defaults.set(true, forKey: Self.githubConnectedMetadataKey)
            invalidateGitHubProjectIndex()
            // The settings page reflects the connected state. Avoid a
            // persistent success toast in the menu-bar footer.
            toast = nil
        } catch {
            ciError = error.localizedDescription
            toast = "GitHub 凭据保存失败"
        }
    }

    func saveGitHubCredential(_ credential: GitHubOAuthCredential, resetProjectIndex: Bool = true) {
        let trimmed = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            var bundle = loadCredentialBundle()
            bundle.githubAccessToken = trimmed
            if let refreshToken = credential.refreshToken, !refreshToken.isEmpty {
                bundle.githubRefreshToken = refreshToken
            }
            try saveCredentialBundle(bundle)
            KeychainVault.shared.delete(account: "github")
            KeychainVault.shared.delete(account: "github.refresh")
            githubAccessTokenCache = trimmed
            if let refreshToken = credential.refreshToken, !refreshToken.isEmpty {
                githubRefreshTokenCache = refreshToken
            } else {
                githubRefreshTokenCache = nil
            }
            if let expiresIn = credential.expiresIn {
                UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(expiresIn)), forKey: GitHubOAuthConfiguration.accessTokenExpiryKey)
            }
            isGitHubConnected = true
            defaults.set(true, forKey: Self.githubConnectedMetadataKey)
            if resetProjectIndex { invalidateGitHubProjectIndex() }
            // The settings page reflects the connected state. Avoid a
            // persistent success toast in the menu-bar footer.
            toast = nil
        } catch {
            ciError = error.localizedDescription
            toast = "GitHub 凭据保存失败"
        }
    }

    private func invalidateGitHubProjectIndex() {
        invalidateCIRefresh(.github)
        // Reauthorization may select another account; never reuse its predecessor's
        // owner-only index or pipeline data.
        accessibleCIProjects.removeAll { $0.provider == "GitHub Actions" }
        pipelineCache = pipelineCache.filter { !$0.key.hasPrefix("github:") }
        lastGitHubRepositorySync = nil
        lastGitHubFullDiscovery = nil
        if selectedPipeline?.provider == "GitHub Actions" { selectedPipeline = nil }
        persistCIState()
    }

    func disconnectGitHub() {
        do {
            var bundle = loadCredentialBundle()
            bundle.githubAccessToken = nil
            bundle.githubRefreshToken = nil
            try saveCredentialBundle(bundle)
        } catch {
            ciError = error.localizedDescription
            toast = "GitHub 凭据更新失败"
            return
        }
        KeychainVault.shared.delete(account: "github")
        KeychainVault.shared.delete(account: "github.refresh")
        UserDefaults.standard.removeObject(forKey: GitHubOAuthConfiguration.accessTokenExpiryKey)
        githubAccessTokenCache = nil
        githubRefreshTokenCache = nil
        invalidateCIRefresh(.github)
        isGitHubConnected = false
        defaults.set(false, forKey: Self.githubConnectedMetadataKey)
        accessibleCIProjects.removeAll { $0.provider == "GitHub Actions" }
        ciProjects.removeAll { $0.provider == "GitHub Actions" }
        pipelineCache = pipelineCache.filter { key, _ in accessibleCIProjects.contains { $0.id == key } }
        lastGitHubRepositorySync = nil
        lastGitHubFullDiscovery = nil
        persistCIState()
        toast = "GitHub 已断开"
    }

    func refreshCI(forceProjectDiscovery: Bool = false) {
        scheduleCIRefresh(manual: true, forceProjectDiscovery: forceProjectDiscovery)
    }

    func refreshCIIfNeeded() {
        scheduleCIRefresh(manual: false, forceProjectDiscovery: false)
    }

    private func scheduleCIRefresh(manual: Bool, forceProjectDiscovery: Bool) {
        // Create every source task before awaiting any network response. Token
        // reads and result publication remain serialized on the main actor.
        startCIRefresh(source: .github, manual: manual) { requestID in
            await self.refreshGitHub(requestID: requestID, forceProjectDiscovery: forceProjectDiscovery)
        }
        for instance in instances {
            startCIRefresh(source: .gitlab(instance.id), manual: manual) { requestID in
                await self.refreshGitLab(instance, requestID: requestID, forceProjectDiscovery: forceProjectDiscovery)
            }
        }
    }

    private func startCIRefresh(source: CISource, manual: Bool, operation: @escaping @MainActor (UUID) async -> Void) {
        guard let requestID = ciRefreshScheduler.begin(source, manual: manual) else { return }
        isRefreshingCI = true
        ciRefreshTasks[source] = Task { @MainActor [weak self] in
            await operation(requestID)
            guard let self, self.ciRefreshScheduler.isCurrent(source, requestID: requestID) else { return }
            self.ciRefreshScheduler.finish(source, requestID: requestID, connectionFailed: self.offlineCISources.contains(source))
            self.ciRefreshTasks.removeValue(forKey: source)
            self.isRefreshingCI = self.ciRefreshScheduler.isRefreshing
        }
    }

    private func invalidateCIRefresh(_ source: CISource) {
        ciRefreshTasks.removeValue(forKey: source)?.cancel()
        ciRefreshScheduler.invalidate(source)
        offlineCISources.remove(source)
        ciSourceErrors.removeValue(forKey: source)
        ciError = ciSourceErrors.isEmpty ? nil : ciSourceErrors.values.sorted().joined(separator: "\n")
        isRefreshingCI = ciRefreshScheduler.isRefreshing
    }

    private func publishCIResult(source: CISource, requestID: UUID, projects: [CIAccessibleProject], pipelines: [String: [Pipeline]]) {
        guard ciRefreshScheduler.isCurrent(source, requestID: requestID), !Task.isCancelled else { return }
        let uniqueProjects = CIActivityOrdering.uniqueProjects(projects)
        let validIDs = Set(uniqueProjects.map(\.id))
        accessibleCIProjects = CIActivityOrdering.uniqueProjects(
            accessibleCIProjects.filter { !source.contains(projectID: $0.id) } + uniqueProjects
        )
        // Merge against the live cache, never replace another source's result
        // with the snapshot taken before a slow request. Retain demand-loaded logs.
        var updatedCache = pipelineCache.filter { !source.contains(projectID: $0.key) || validIDs.contains($0.key) }
        for (projectID, refreshed) in pipelines where source.contains(projectID: projectID) && validIDs.contains(projectID) {
            updatedCache[projectID] = refreshed.map { pipeline in
                CIPipelineCache.merging(pipeline, with: updatedCache[projectID]?.first { $0.id == pipeline.id })
            }
        }
        pipelineCache = updatedCache
        if let selected = selectedPipeline,
           source.contains(projectID: selected.projectID),
           let refreshed = updatedCache[selected.projectID]?.first(where: { $0.id == selected.id }) {
            selectedPipeline = refreshed
        }
        reconcileAcknowledgedFailures()
        lastCIRefresh = Date()
    }

    private func finishCIRefresh(source: CISource, requestID: UUID, connectionFailed: Bool, errors: [String], profiler: CIRefreshProfiler) {
        guard ciRefreshScheduler.isCurrent(source, requestID: requestID), !Task.isCancelled else { return }
        if connectionFailed { offlineCISources.insert(source) }
        else { offlineCISources.remove(source) }
        ciSourceErrors[source] = errors.isEmpty ? nil : errors.joined(separator: "\n")
        ciError = ciSourceErrors.isEmpty ? nil : ciSourceErrors.values.sorted().joined(separator: "\n")
        let persistenceStartedAt = Date()
        persistCIState()
        profiler.record("保存本地状态", duration: Date().timeIntervalSince(persistenceStartedAt))
        CIRefreshDiagnostics.write(profiler.report(
            projectCount: accessibleCIProjects.filter { source.contains(projectID: $0.id) }.count,
            pipelineCount: pipelineCache.filter { source.contains(projectID: $0.key) }.values.reduce(0) { $0 + $1.count },
            errorCount: errors.count
        ))
    }

    private func refreshGitHub(requestID: UUID, forceProjectDiscovery: Bool) async {
        let source = CISource.github
        let cachedProjects = accessibleCIProjects.filter { source.contains(projectID: $0.id) }
        var projects = cachedProjects
        var pipelines = pipelineCache.filter { source.contains(projectID: $0.key) }
        var errors: [String] = []
        var connectionFailed = false
        var didGitHubRepositorySync = false
        var didGitHubFullDiscovery = false
        let startedAt = Date()
        let profiler = CIRefreshProfiler()
        defer {
            finishCIRefresh(source: source, requestID: requestID, connectionFailed: connectionFailed, errors: errors, profiler: profiler)
        }
        if let token = await self.githubAccessTokenForRequest(), !token.isEmpty {
            let cachedGitHubProjects = cachedProjects.filter { $0.provider == "GitHub Actions" && $0.isInRepositoryScope }
            var githubProjects = cachedGitHubProjects
            do {
                let client = GitHubAPIClient(token: token, session: ciSession)
                // Keep repository discovery incremental. Actions status uses
                // its own polling below because completing or rerunning a
                // workflow need not update the repository's timestamp.
                let fullDiscovery = forceProjectDiscovery || lastGitHubRepositorySync == nil || cachedGitHubProjects.isEmpty ||
                    lastGitHubFullDiscovery.map { Date().timeIntervalSince($0) > Self.githubFullDiscoveryInterval } ?? true
                let discovered = try await profiler.measure("GitHub · 仓库索引", requests: 1) {
                    try await client.ownedProjects(
                        limit: fullDiscovery ? Self.githubRepositoryLimit : 100,
                        since: fullDiscovery ? nil : self.lastGitHubRepositorySync?.addingTimeInterval(-60)
                    )
                }
                let changed = discovered.map {
                    CIAccessibleProject(
                        id: $0.id, name: $0.name, provider: $0.provider,
                        repository: $0.repository, branch: $0.branch,
                        instanceName: nil, updatedAt: $0.updatedAt,
                        isOwnedByCurrentUser: true
                    )
                }
                if fullDiscovery {
                    githubProjects = Array(changed.prefix(Self.githubRepositoryLimit))
                } else {
                    githubProjects = CIActivityOrdering.mergedRecentProjects(
                        changed: changed,
                        cached: cachedGitHubProjects,
                        limit: Self.githubRepositoryLimit
                    )
                }
                projects = githubProjects

                let projectsToRefresh = CIActivityOrdering.projectsRequiringPipelineRefresh(
                    retained: githubProjects, pipelineCache: pipelines
                )
                // Requests within this account stay serial; other accounts
                // refresh in their own main-actor tasks.
                var didFetchAllChangedPipelines = true
                for project in projectsToRefresh {
                    try Task.checkCancellation()
                    let parts = project.repository.split(separator: "/", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    do {
                        let remote = try await profiler.measure("GitHub · 流水线", requests: 1) {
                            try await client.recentRuns(owner: parts[0], repository: parts[1], projectID: project.id)
                        }
                        let refreshed = remote.map(self.makePipeline)
                        let previous = pipelines[project.id] ?? []
                        pipelines[project.id] = refreshed.map { pipeline in
                            CIPipelineCache.merging(pipeline, with: previous.first { $0.id == pipeline.id })
                        }
                        publishCIResult(source: source, requestID: requestID, projects: githubProjects, pipelines: pipelines)
                    } catch {
                        // Do not advance the repository cursor: this
                        // change must be retried on the next refresh.
                        didFetchAllChangedPipelines = false
                        if CIConnectionFailure.shouldStopRequests(error) { throw error }
                        errors.append("GitHub \(project.repository)：\(error.localizedDescription)")
                    }
                }
                didGitHubRepositorySync = didFetchAllChangedPipelines
                didGitHubFullDiscovery = fullDiscovery && didFetchAllChangedPipelines
            } catch {
                connectionFailed = CIConnectionFailure.isOffline(error)
                errors.append("GitHub：\(error.localizedDescription)")
                return
            }
            projects = githubProjects
        }

        guard ciRefreshScheduler.isCurrent(source, requestID: requestID), !Task.isCancelled else { return }
        if didGitHubRepositorySync { lastGitHubRepositorySync = startedAt }
        if didGitHubFullDiscovery { lastGitHubFullDiscovery = startedAt }
        if !projects.isEmpty || didGitHubRepositorySync {
            publishCIResult(source: source, requestID: requestID, projects: projects, pipelines: pipelines)
        }
    }

    private func refreshGitLab(_ instance: GitLabInstance, requestID: UUID, forceProjectDiscovery: Bool) async {
        let source = CISource.gitlab(instance.id)
        let cachedProjects = accessibleCIProjects.filter { source.contains(projectID: $0.id) }
        var projects: [CIAccessibleProject] = []
        var pipelines = pipelineCache.filter { source.contains(projectID: $0.key) }
        var errors: [String] = []
        var connectionFailed = false
        var didDiscover = false
        let profiler = CIRefreshProfiler()
        defer {
            finishCIRefresh(source: source, requestID: requestID, connectionFailed: connectionFailed, errors: errors, profiler: profiler)
        }
        guard let token = self.gitLabToken(for: instance) else { return }
        do {
            let client = try GitLabAPIClient(instanceURL: instance.host, token: token, session: ciSession, projectIDPrefix: instance.id.uuidString)
            let syncKey = instance.id.uuidString
            var globalCapability = self.gitLabGlobalPipelineCapabilities[syncKey]
            var projectSyncDates = self.gitLabProjectPipelineSyncDates.filter { $0.key.hasPrefix("\(syncKey):") }
            let syncStartedAt = Date()
            let instanceProjectPrefix = "gitlab:\(syncKey):"
            var gitLabProjects = cachedProjects
            var advancesPipelineCursor = false
            var remotePipelines: [RemotePipeline] = []

            if globalCapability != false {
                do {
                    // GitLab has a cross-project pipeline feed, so the
                    // normal path starts here rather than enumerating
                    // `/projects`. Its cursor is creation-based; a
                    // short overlap handles requests at the boundary.
                    let cursor = forceProjectDiscovery ? nil : self.gitLabPipelineSyncDates[syncKey]
                    let createdAfter = cursor?.addingTimeInterval(-Self.gitLabPipelineSyncOverlap)
                    remotePipelines = try await profiler.measure("\(instance.name) · 全局流水线", requests: 1) {
                        try await client.recentPipelines(limit: 100, createdAfter: createdAfter)
                    }
                    advancesPipelineCursor = true
                    globalCapability = true

                    // The global cursor only returns newly created
                    // pipelines. Refresh cached running ones directly
                    // so their final result still reaches the card.
                    let runningCached = pipelines.values
                        .flatMap { $0 }
                        .filter { $0.provider == "GitLab CI" && $0.projectID.hasPrefix(instanceProjectPrefix) && $0.state == .running }
                    for pipeline in runningCached {
                        let pipelineID = pipeline.id.split(separator: "-").last.map(String.init) ?? pipeline.id
                        let refreshed = try await optionalCIRequest {
                            try await profiler.measure("\(instance.name) · 运行中流水线", requests: 1) {
                                try await client.pipeline(projectID: pipeline.projectID, pipelineID: pipelineID)
                            }
                        }
                        if let refreshed {
                            remotePipelines.append(refreshed)
                        }
                    }
                } catch let CIIntegrationError.http(code, _) where code == 404 || code == 405 {
                    // The authenticated probe confirms that this
                    // instance is older than the cross-project API.
                    // Persist it so later polls do not repeat 404.
                    globalCapability = false
                } catch {
                    throw error
                }
            }

            guard ciRefreshScheduler.isCurrent(source, requestID: requestID), !Task.isCancelled else { return }
            self.gitLabGlobalPipelineCapabilities[syncKey] = globalCapability

            if globalCapability == false {
                // Old GitLab has no instance-wide activity feed.
                // Reuse its persisted project index; only a first
                // sync or an explicit discovery refresh enumerates
                // `/projects` again.
                if forceProjectDiscovery || gitLabProjects.isEmpty {
                    let discovered = try await profiler.measure("\(instance.name) · 项目索引（兼容）", requests: 1) {
                        try await client.accessibleProjects()
                    }
                    gitLabProjects = discovered.map {
                        CIAccessibleProject(
                            id: $0.id, name: $0.name, provider: $0.provider,
                            repository: $0.repository, branch: $0.branch,
                            instanceName: instance.name
                        )
                    }
                    didDiscover = true
                }
                let fallbackProjects = Array(gitLabProjects.prefix(GitLabAPIClient.legacyFallbackProjectLimit))
                for project in fallbackProjects {
                    try Task.checkCancellation()
                    let projectSyncKey = "\(syncKey):\(project.id)"
                    let cachedCursor = pipelines[project.id]?.compactMap(\.updatedAt).max()
                    let cursor = forceProjectDiscovery ? nil : (projectSyncDates[projectSyncKey] ?? cachedCursor)
                    let syncStartedAt = Date()
                    do {
                        let projectPipelines = try await profiler.measure("\(instance.name) · 项目流水线（兼容）", requests: 1) {
                            try await client.recentPipelines(
                                projectID: project.id,
                                limit: cursor == nil ? 5 : 100,
                                updatedAfter: cursor
                            )
                        }
                        remotePipelines.append(contentsOf: projectPipelines)
                        // Advance only after a successful response;
                        // a failed request remains eligible next time.
                        projectSyncDates[projectSyncKey] = syncStartedAt
                    } catch {
                        if CIConnectionFailure.shouldStopRequests(error) { throw error }
                        errors.append("\(instance.name) \(project.repository)：\(error.localizedDescription)")
                    }
                }
            }

            // A global response can contain the same running
            // pipeline as the direct refresh above. Let the direct
            // response win and never duplicate the card.
            var remotesByID: [String: RemotePipeline] = [:]
            for remote in remotePipelines {
                remotesByID["\(remote.projectID):\(remote.id)"] = remote
            }
            remotePipelines = Array(remotesByID.values)

            // New GitLab versions include `project` metadata in
            // the global feed. For older responses, resolve only
            // those individual unseen project IDs, never the full
            // project list.
            var projectsByID = Dictionary(uniqueKeysWithValues: gitLabProjects.map { ($0.id, $0) })
            var resolvedAllProjects = true
            for remote in remotePipelines where projectsByID[remote.projectID] == nil {
                if let project = self.makeGitLabProject(remote, instance: instance) {
                    projectsByID[project.id] = project
                } else {
                    do {
                        let resolved = try await profiler.measure("\(instance.name) · 项目元数据", requests: 1) {
                            try await client.project(projectID: remote.projectID)
                        }
                        projectsByID[remote.projectID] = CIAccessibleProject(
                            id: remote.projectID, name: resolved.name, provider: resolved.provider,
                            repository: resolved.repository, branch: resolved.branch,
                            instanceName: instance.name
                        )
                    } catch {
                        resolvedAllProjects = false
                        if CIConnectionFailure.shouldStopRequests(error) { throw error }
                        errors.append("\(instance.name)：\(error.localizedDescription)")
                    }
                }
            }

            var orderedProjectIDs: [String] = []
            for remote in remotePipelines where projectsByID[remote.projectID] != nil {
                if !orderedProjectIDs.contains(remote.projectID) { orderedProjectIDs.append(remote.projectID) }
            }
            for project in gitLabProjects where projectsByID[project.id] != nil {
                if !orderedProjectIDs.contains(project.id) { orderedProjectIDs.append(project.id) }
            }
            gitLabProjects = orderedProjectIDs.compactMap { projectsByID[$0] }
            projects = gitLabProjects

            let cacheMergeStartedAt = Date()
            let grouped = Dictionary(grouping: remotePipelines, by: \.projectID)
            for (projectID, remotes) in grouped {
                guard let project = projectsByID[projectID] else { continue }
                let refreshed = remotes.map { self.makePipeline($0, project: project) }
                pipelines[projectID] = CIPipelineCache.mergingRecent(
                    refreshed, with: pipelines[projectID] ?? []
                )
            }
            profiler.record("本地索引与缓存合并", duration: Date().timeIntervalSince(cacheMergeStartedAt))
            publishCIResult(source: source, requestID: requestID, projects: projects, pipelines: pipelines)

            // GitLab's list endpoint omits duration and start time
            // on older instances. Fill those fields only for the
            // current completed pipeline of a followed project,
            // then retain the detail in the local cache. This is
            // at most one extra request per affected card, not a
            // history-wide re-query on every refresh.
            let followedProjectIDs = Set(self.ciProjects.compactMap { project in
                source.contains(projectID: project.id) ? project.id : nil
            })
            for projectID in followedProjectIDs {
                guard let project = projectsByID[projectID],
                      let latest = pipelines[projectID]?.sorted(by: CIActivityOrdering.newestFirst).first,
                      latest.duration == "—",
                      latest.state != .running else { continue }
                let pipelineID = latest.id.split(separator: "-").last.map(String.init) ?? latest.id
                let detailed = try await optionalCIRequest {
                    try await profiler.measure("\(instance.name) · 关注流水线详情（耗时）", requests: 1) {
                        try await client.pipeline(projectID: projectID, pipelineID: pipelineID)
                    }
                }
                guard let detailed else { continue }
                let refreshed = self.makePipeline(detailed, project: project)
                pipelines[projectID] = CIPipelineCache.mergingRecent(
                    [refreshed], with: pipelines[projectID] ?? []
                )
            }

            // Re-fetch jobs only for a newly seen pipeline or one
            // still in flight. Completed, already-loaded jobs stay
            // in the local cache and add no request to this cycle.
            var stageCandidates: [(String, Pipeline)] = []
            var stageCandidateIDs = Set<String>()
            for remote in remotePipelines {
                guard let pipeline = pipelines[remote.projectID]?.first(where: { $0.id == remote.id }),
                      pipeline.state == .running || !pipeline.hasLoadedStages else { continue }
                let key = "\(remote.projectID):\(pipeline.id)"
                if stageCandidateIDs.insert(key).inserted {
                    stageCandidates.append((remote.projectID, pipeline))
                }
            }
            let stageUpdates = try await prefetchPipelineStages(
                candidates: stageCandidates,
                limit: Self.stagePrefetchProjectLimit
            ) { pipeline in
                let pipelineID = pipeline.id.split(separator: "-").last.map(String.init) ?? pipeline.id
                return try await optionalCIRequest {
                    try await profiler.measure("\(instance.name) · 作业步骤", requests: 1) {
                        try await client.jobs(projectID: pipeline.projectID, pipelineID: pipelineID)
                    }
                } ?? []
            }
            for (projectID, staged) in stageUpdates {
                pipelines[projectID] = CIPipelineCache.mergingRecent(
                    [staged], with: pipelines[projectID] ?? []
                )
            }
            guard ciRefreshScheduler.isCurrent(source, requestID: requestID), !Task.isCancelled else { return }
            self.gitLabGlobalPipelineCapabilities[syncKey] = globalCapability
            self.gitLabProjectPipelineSyncDates.merge(projectSyncDates) { _, refreshed in refreshed }
            if advancesPipelineCursor && resolvedAllProjects {
                self.gitLabPipelineSyncDates[syncKey] = syncStartedAt
            }
        } catch {
            // Keep the live cache, including any summaries already published
            // before an optional detail request lost its connection.
            connectionFailed = CIConnectionFailure.isOffline(error)
            errors.append("\(instance.name)：\(error.localizedDescription)")
            return
        }

        guard ciRefreshScheduler.isCurrent(source, requestID: requestID), !Task.isCancelled else { return }
        publishCIResult(source: source, requestID: requestID, projects: projects, pipelines: pipelines)
        if didDiscover {
            lastCIProjectDiscovery = Date()
            defaults.set(Self.projectIndexOrderVersion, forKey: Self.projectIndexOrderVersionKey)
        }
    }

    /// GitLab's collection endpoint intentionally omits execution timing on
    /// some versions. Fetch details only when an activity card is actually
    /// visible, then merge the result into the existing cache for later views.
    func loadGitLabPipelineTimingIfNeeded(for pipeline: Pipeline) {
        let hydrationID = "\(pipeline.projectID)|\(pipeline.id)"
        guard pipeline.provider == "GitLab CI",
              pipeline.duration == "—",
              pipeline.state != .running,
              let project = accessibleCIProjects.first(where: { $0.id == pipeline.projectID }),
              let instance = instances.first(where: {
                  pipeline.projectID.hasPrefix("gitlab:\($0.id.uuidString):")
              }),
              !offlineCISources.contains(.gitlab(instance.id)),
              hydratingGitLabPipelineTimingIDs.insert(hydrationID).inserted else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            defer { self.hydratingGitLabPipelineTimingIDs.remove(hydrationID) }
            guard let token = self.gitLabToken(for: instance) else { return }
            let pipelineID = pipeline.id.split(separator: "-").last.map(String.init) ?? pipeline.id
            guard let client = try? GitLabAPIClient(
                instanceURL: instance.host,
                token: token,
                projectIDPrefix: instance.id.uuidString
            ), let detailed = try? await client.pipeline(projectID: pipeline.projectID, pipelineID: pipelineID) else {
                return
            }

            let refreshed = self.makePipeline(detailed, project: project)
            self.pipelineCache[pipeline.projectID] = CIPipelineCache.mergingRecent(
                [refreshed], with: self.pipelineCache[pipeline.projectID] ?? []
            )
            self.persistCIState()
        }
    }

    private func githubAccessTokenForRequest() async -> String? {
        if let ciCredentialProvider { return await ciCredentialProvider.github() }
        var bundle = loadCredentialBundle()
        let storedToken: String?
        if let cached = githubAccessTokenCache, !cached.isEmpty {
            storedToken = cached
        } else if let bundled = bundle.githubAccessToken, !bundled.isEmpty {
            storedToken = bundled
        } else if let legacy = KeychainVault.shared.read(account: "github"), !legacy.isEmpty {
            // Migrate only the token being used. Other legacy entries stay
            // untouched until their provider is explicitly used.
            bundle.githubAccessToken = legacy
            do {
                try saveCredentialBundle(bundle)
                KeychainVault.shared.delete(account: "github")
            } catch { }
            storedToken = legacy
        } else {
            storedToken = nil
        }
        guard let token = storedToken, !token.isEmpty else { return nil }
        githubAccessTokenCache = token
        let expiry = UserDefaults.standard.object(forKey: GitHubOAuthConfiguration.accessTokenExpiryKey) as? Date
        guard let expiry, expiry < Date().addingTimeInterval(300) else {
            return token
        }
        let storedRefreshToken: String?
        if let cached = githubRefreshTokenCache, !cached.isEmpty {
            storedRefreshToken = cached
        } else if let bundled = bundle.githubRefreshToken, !bundled.isEmpty {
            storedRefreshToken = bundled
        } else if let legacy = KeychainVault.shared.read(account: "github.refresh"), !legacy.isEmpty {
            bundle.githubRefreshToken = legacy
            do {
                try saveCredentialBundle(bundle)
                KeychainVault.shared.delete(account: "github.refresh")
            } catch { }
            storedRefreshToken = legacy
        } else {
            storedRefreshToken = nil
        }
        guard let refreshToken = storedRefreshToken, !refreshToken.isEmpty else { return token }
        githubRefreshTokenCache = refreshToken
        do {
            let clientID = UserDefaults.standard.string(forKey: GitHubOAuthConfiguration.clientIDKey) ?? GitHubOAuthConfiguration.defaultClientID
            let credential = try await GitHubOAuthClient(session: ciSession).refreshAccessToken(clientID: clientID, refreshToken: refreshToken)
            guard !Task.isCancelled else { return nil }
            saveGitHubCredential(credential, resetProjectIndex: false)
            return credential.accessToken
        } catch {
            // Keep the existing token for one last attempt; the API error will
            // be surfaced by refreshCI/openPipeline if it has already expired.
            return token
        }
    }

    private func gitLabToken(for instance: GitLabInstance) -> String? {
        if let ciCredentialProvider { return ciCredentialProvider.gitlab(instance) }
        if let cached = gitLabTokenCache[instance.host], !cached.isEmpty { return cached }
        var bundle = loadCredentialBundle()
        if let bundled = bundle.gitLabTokens[instance.host], !bundled.isEmpty {
            gitLabTokenCache[instance.host] = bundled
            return bundled
        }
        guard let token = KeychainVault.shared.read(account: "gitlab:\(instance.host)"), !token.isEmpty else {
            gitLabCredentialHosts.remove(instance.host)
            return nil
        }
        bundle.gitLabTokens[instance.host] = token
        do {
            try saveCredentialBundle(bundle)
            KeychainVault.shared.delete(account: "gitlab:\(instance.host)")
        } catch { }
        gitLabTokenCache[instance.host] = token
        return token
    }

    private func makePipeline(_ remote: RemotePipeline) -> Pipeline {
        Pipeline(
            id: remote.id,
            projectID: remote.projectID,
            provider: remote.provider,
            repository: remote.repository,
            branch: remote.branch,
            commit: remote.commit,
            duration: remote.duration,
            state: remote.state,
            stages: [PipelineStage(id: "\(remote.id)-summary", name: "流水线", duration: remote.duration, state: remote.state, log: "")],
            updatedAt: remote.updatedAt,
            webURL: remote.webURL,
            startedAt: remote.startedAt
        )
    }

    private func makePipeline(_ remote: RemotePipeline, project: CIAccessibleProject) -> Pipeline {
        Pipeline(
            id: remote.id,
            projectID: remote.projectID,
            provider: remote.provider,
            repository: project.repository,
            branch: remote.branch.isEmpty ? project.branch : remote.branch,
            commit: remote.commit,
            duration: remote.duration,
            state: remote.state,
            stages: [PipelineStage(id: "\(remote.id)-summary", name: "流水线", duration: remote.duration, state: remote.state, log: "")],
            updatedAt: remote.updatedAt,
            webURL: remote.webURL,
            startedAt: remote.startedAt
        )
    }

    /// The cross-project GitLab response now carries `project.path_with_namespace`
    /// on supported instances. Derive the small index entry from that payload
    /// rather than making a separate repository-list request.
    private func makeGitLabProject(_ remote: RemotePipeline, instance: GitLabInstance) -> CIAccessibleProject? {
        let repository = remote.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repository.isEmpty else { return nil }
        let name = repository.split(separator: "/").last.map(String.init) ?? repository
        return CIAccessibleProject(
            id: remote.projectID, name: name, provider: remote.provider,
            repository: repository, branch: remote.branch.isEmpty ? "main" : remote.branch,
            instanceName: instance.name
        )
    }

    /// 打开详情时只请求 jobs/stage 状态；点击具体阶段后才请求该阶段日志。
    func openPipeline(_ pipeline: Pipeline) {
        selectedPipeline = pipeline
        expandedStageID = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let jobs: [RemoteJob]
                if pipeline.provider == "GitHub Actions" {
                    guard let token = await self.githubAccessTokenForRequest() else { throw CIIntegrationError.missingToken }
                    let parts = pipeline.repository.split(separator: "/", maxSplits: 1).map(String.init)
                    let runID = pipeline.id.split(separator: "-").last.map(String.init) ?? pipeline.id
                    guard parts.count == 2 else { throw CIIntegrationError.invalidURL }
                    jobs = try await GitHubAPIClient(token: token, session: ciSession).jobs(owner: parts[0], repository: parts[1], runID: runID)
                } else {
                    guard let project = accessibleCIProjects.first(where: { $0.id == pipeline.projectID }),
                          let instance = instances.first(where: { $0.name == project.instanceName }),
                          let token = gitLabToken(for: instance) else { throw CIIntegrationError.missingToken }
                    let pipelineID = pipeline.id.split(separator: "-").last.map(String.init) ?? pipeline.id
                    jobs = try await GitLabAPIClient(instanceURL: instance.host, token: token, session: ciSession).jobs(projectID: project.id, pipelineID: pipelineID)
                }

                // Jobs may return after the summary refresh has completed.
                // Attach them to the live pipeline, retaining its current
                // overall status and duration rather than the opening snapshot.
                let selected = self.selectedPipeline.flatMap {
                    $0.id == pipeline.id && $0.projectID == pipeline.projectID ? $0 : nil
                }
                guard let current = self.pipelineCache[pipeline.projectID]?.first(where: { $0.id == pipeline.id }) ?? selected,
                      let staged = CIPipelineCache.withJobs(current, jobs: jobs) else { return }
                let detailed = CIPipelineCache.merging(staged, with: current)
                self.pipelineCache[pipeline.projectID] = self.pipelineCache[pipeline.projectID]?.map { $0.id == pipeline.id ? detailed : $0 }
                if selected != nil { self.selectedPipeline = detailed }
            } catch {
                self.ciError = error.localizedDescription
            }
        }
    }

    func isLoadingStage(_ stageID: String) -> Bool {
        loadingStageIDs.contains(stageID)
    }

    /// Fetch one job trace after the user explicitly selects its stage.
    func loadStageLog(for pipeline: Pipeline, stage: PipelineStage) {
        guard pipeline.hasLoadedStages, stage.log.isEmpty, !loadingStageIDs.contains(stage.id) else { return }
        loadingStageIDs.insert(stage.id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingStageIDs.remove(stage.id) }
            do {
                let log: String
                if pipeline.provider == "GitHub Actions" {
                    guard let token = await self.githubAccessTokenForRequest() else { throw CIIntegrationError.missingToken }
                    let parts = pipeline.repository.split(separator: "/", maxSplits: 1).map(String.init)
                    let jobID = stage.id.split(separator: "-").last.map(String.init) ?? stage.id
                    guard parts.count == 2 else { throw CIIntegrationError.invalidURL }
                    log = try await GitHubAPIClient(token: token).jobLog(owner: parts[0], repository: parts[1], jobID: jobID)
                } else {
                    guard let project = self.accessibleCIProjects.first(where: { $0.id == pipeline.projectID }),
                          let instance = self.instances.first(where: { $0.name == project.instanceName }),
                          let token = self.gitLabToken(for: instance) else { throw CIIntegrationError.missingToken }
                    let jobID = stage.id.split(separator: "-").last.map(String.init) ?? stage.id
                    log = try await GitLabAPIClient(instanceURL: instance.host, token: token).jobLog(projectID: project.id, jobID: jobID)
                }

                let update: (Pipeline) -> Pipeline = { current in
                    let stages = current.stages.map { currentStage in
                        guard currentStage.id == stage.id else { return currentStage }
                        return PipelineStage(
                            id: currentStage.id,
                            name: currentStage.name,
                            duration: currentStage.duration,
                            state: currentStage.state,
                            log: log,
                            group: currentStage.group
                        )
                    }
                    return Pipeline(
                        id: current.id,
                        projectID: current.projectID,
                        provider: current.provider,
                        repository: current.repository,
                        branch: current.branch,
                        commit: current.commit,
                        duration: current.duration,
                        state: current.state,
                        stages: stages,
                        updatedAt: current.updatedAt,
                        webURL: current.webURL,
                        startedAt: current.startedAt,
                        hasLoadedStages: current.hasLoadedStages
                    )
                }
                self.pipelineCache[pipeline.projectID] = self.pipelineCache[pipeline.projectID]?.map { current in
                    current.id == pipeline.id ? update(current) : current
                }
                if self.selectedPipeline?.id == pipeline.id, let current = self.selectedPipeline {
                    self.selectedPipeline = update(current)
                }
            } catch {
                self.ciError = error.localizedDescription
            }
        }
    }

    func isFollowing(_ projectID: String) -> Bool {
        ciProjects.contains { $0.id == projectID }
    }

    func followProject(_ projectID: String) {
        guard !isFollowing(projectID), let project = accessibleCIProjects.first(where: { $0.id == projectID }) else { return }
        ciProjects.append(CIMonitoredProject(id: project.id, name: project.name, provider: project.provider, repository: project.repository, branch: project.branch, instanceName: project.instanceName))
        selectedCIProjectID = project.id
        persistCIState()
        toast = LF("已关注 %@", project.name)
    }

    func unfollowProject(_ projectID: String) {
        guard let project = ciProjects.first(where: { $0.id == projectID }) else { return }
        ciProjects.removeAll { $0.id == projectID }
        if selectedCIProjectID == projectID { selectedCIProjectID = ciProjects.first?.id }
        persistCIState()
        toast = LF("已取消关注 %@", project.name)
    }

    func toggle(project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].isExpanded.toggle()
    }

    func serviceAction(_ service: Service) {
        guard let project = projects.first(where: { $0.services.contains { $0.id == service.id } }) else { return }
        if runningProcesses[service.id] != nil {
            stopService(service, in: project)
        } else {
            startService(service, in: project)
        }
    }

    /// Stop the tracked process and launch a replacement only after the old
    /// process actually terminates, so the two copies cannot compete for a port.
    func restartService(_ service: Service) {
        guard let project = projects.first(where: { $0.services.contains { $0.id == service.id } }) else { return }
        guard let process = runningProcesses[service.id], process.isRunning else {
            runningProcesses.removeValue(forKey: service.id)
            startService(service, in: project)
            return
        }
        restartPendingServiceIDs.insert(service.id)
        intentionallyStoppingServiceIDs.insert(service.id)
        updateService(service.id, in: project.id, status: .starting)
        process.terminate()
    }

    func stopAllServices() {
        guard !runningProcesses.isEmpty else { return }
        restartPendingServiceIDs.removeAll()
        intentionallyStoppingServiceIDs.formUnion(runningProcesses.keys)
        for process in runningProcesses.values where process.isRunning {
            process.terminate()
        }
        runningProcesses.removeAll()
        for projectIndex in projects.indices {
            for serviceIndex in projects[projectIndex].services.indices where projects[projectIndex].services[serviceIndex].status != .stopped {
                projects[projectIndex].services[serviceIndex].status = .stopped
            }
        }
        persistCIState()
    }

    func clearServiceLog(_ service: Service) {
        serviceLogs[service.id] = ""
    }

    func openServiceLog(_ service: Service) {
        selectedServiceLogID = service.id
    }

    func openService(_ service: Service) {
        let raw = service.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            toast = "该服务没有配置访问地址"
            return
        }
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            toast = LF("访问地址无效：%@", raw)
            return
        }
        if !NSWorkspace.shared.open(url) { toast = "无法打开访问地址" }
    }

    func startAll() {
        for project in projects {
            for service in project.services where runningProcesses[service.id] == nil {
                startService(service, in: project)
            }
        }
    }

    func projectAction(_ project: Project, action: String) {
        if action == "启动" {
            for service in project.services where runningProcesses[service.id] == nil { startService(service, in: project) }
        } else {
            for service in project.services where runningProcesses[service.id] != nil { stopService(service, in: project) }
        }
    }

    func addProject(name: String, directory: String, serviceName: String, command: String, url: String) -> Bool {
        addProject(name: name, directory: directory, services: [ProjectServiceDraft(name: serviceName, command: command, url: url)])
    }

    func addProject(name: String, directory: String, services drafts: [ProjectServiceDraft]) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let validDrafts = drafts.filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !trimmedName.isEmpty, !trimmedDirectory.isEmpty, !validDrafts.isEmpty else {
            toast = "请填写项目名称、目录和至少一个启动命令"
            return false
        }
        guard validDrafts.allSatisfy({ ServicePortGuard.hasValidConfiguration($0.ports) }) else {
            toast = "服务端口须为 1–65535 的逗号分隔列表，或留空"
            return false
        }
        let services = validDrafts.map {
            Service(id: UUID().uuidString,
                    name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "服务" : $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    command: $0.command.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: $0.url.trimmingCharacters(in: .whitespacesAndNewlines),
                    status: .stopped,
                    directory: WorkingDirectory.normalizedOverride($0.directory),
                    ports: ServicePortGuard.configuredPorts(from: $0.ports) ?? [])
        }
        let project = Project(id: UUID().uuidString, name: trimmedName, initial: String(trimmedName.prefix(1)).uppercased(), serviceCount: services.count, issue: false, isExpanded: true, services: services, directory: (trimmedDirectory as NSString).expandingTildeInPath)
        projects.append(project)
        persistCIState()
        toast = LF("已添加项目 %@", trimmedName)
        return true
    }

    func updateProject(_ project: Project, name: String, directory: String, serviceName: String, command: String, url: String) -> Bool {
        updateProject(project, name: name, directory: directory, services: [ProjectServiceDraft(name: serviceName, command: command, url: url)])
    }

    func updateProject(_ project: Project, name: String, directory: String, services drafts: [ProjectServiceDraft]) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let validDrafts = drafts.filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !trimmedName.isEmpty, !trimmedDirectory.isEmpty, !validDrafts.isEmpty,
              let projectIndex = projects.firstIndex(where: { $0.id == project.id }) else {
            toast = "请填写项目名称、目录和至少一个启动命令"
            return false
        }
        guard validDrafts.allSatisfy({ ServicePortGuard.hasValidConfiguration($0.ports) }) else {
            toast = "服务端口须为 1–65535 的逗号分隔列表，或留空"
            return false
        }

        let services = validDrafts.map { draft in
            let current = project.services.first(where: { $0.id == draft.id })
            let serviceName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return Service(id: current?.id ?? UUID().uuidString,
                           name: serviceName.isEmpty ? (current?.name ?? "服务") : serviceName,
                           command: draft.command.trimmingCharacters(in: .whitespacesAndNewlines),
                           url: draft.url.trimmingCharacters(in: .whitespacesAndNewlines),
                           status: current?.status ?? .stopped,
                           directory: WorkingDirectory.normalizedOverride(draft.directory),
                           ports: ServicePortGuard.configuredPorts(from: draft.ports) ?? [])
        }
        projects[projectIndex] = Project(id: project.id, name: trimmedName, initial: String(trimmedName.prefix(1)).uppercased(), serviceCount: services.count, issue: project.issue, isExpanded: project.isExpanded, services: services, directory: (trimmedDirectory as NSString).expandingTildeInPath)
        persistCIState()
        toast = "已保存项目"
        return true
    }

    func removeProject(_ project: Project) {
        // 先停止该项目的进程，再移除配置，避免设置页删除后仍有孤儿进程。
        projectAction(project, action: "停止")
        projects.removeAll { $0.id == project.id }
        persistCIState()
    }

    private func startService(_ service: Service, in project: Project) {
        let directory = WorkingDirectory.resolve(service.directory, projectDirectory: project.directory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            updateService(service.id, in: project.id, status: .failed)
            toast = LF("%@ 的启动目录不存在或不是文件夹：%@", service.name, directory.path)
            return
        }
        updateService(service.id, in: project.id, status: .starting)
        serviceLogs[service.id] = ""
        do {
            let releasedByPort = try ServicePortGuard.release(ports: service.ports)
            for port in service.ports {
                let releasedPIDs = releasedByPort[port] ?? []
                if !releasedPIDs.isEmpty {
                    serviceLogs[service.id, default: ""].append("[StackHub] 端口 \(port) 被 PID \(releasedPIDs.map(String.init).joined(separator: ", ")) 占用，已释放。\n")
                }
            }
        } catch {
            updateService(service.id, in: project.id, status: .failed)
            let message = "配置端口无法释放：\(error.localizedDescription)"
            serviceLogs[service.id] = "[StackHub] \(message)\n"
            toast = LF("%@ %@", service.name, message)
            persistCIState()
            return
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // exec makes the tracked Process the actual command instead of leaving
        // an intermediate shell around when a service is stopped.
        process.arguments = ["-lc", "exec \(service.command)"]
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self, weak process] in
                guard let self, let process else { return }
                if let current = self.runningProcesses[service.id], current !== process { return }
                self.serviceLogs[service.id, default: ""].append(chunk)
                guard self.runningProcesses[service.id] === process else { return }
                self.applyStartupEvidence(
                    from: String((self.serviceLogs[service.id] ?? "").suffix(2_048)),
                    for: service,
                    in: project
                )
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                let wasIntentionallyStopped = self.intentionallyStoppingServiceIDs.remove(service.id) != nil
                let shouldRestart = self.restartPendingServiceIDs.remove(service.id) != nil
                if let current = self.runningProcesses[service.id], current !== process {
                    return
                }
                self.runningProcesses.removeValue(forKey: service.id)
                if shouldRestart {
                    self.updateService(service.id, in: project.id, status: .starting)
                    self.persistCIState()
                    self.startService(service, in: project)
                    return
                }
                let status: ServiceStatus = wasIntentionallyStopped || process.terminationStatus == 0 ? .stopped : .failed
                self.updateService(service.id, in: project.id, status: status)
                self.persistCIState()
            }
        }
        do {
            try process.run()
            runningProcesses[service.id] = process
        } catch {
            updateService(service.id, in: project.id, status: .failed)
            toast = LF("启动失败：%@", error.localizedDescription)
        }
    }

    private func stopService(_ service: Service, in project: Project) {
        restartPendingServiceIDs.remove(service.id)
        if runningProcesses[service.id] != nil {
            intentionallyStoppingServiceIDs.insert(service.id)
        }
        runningProcesses[service.id]?.terminate()
        runningProcesses.removeValue(forKey: service.id)
        updateService(service.id, in: project.id, status: .stopped)
        persistCIState()
    }

    private func applyStartupEvidence(from log: String, for service: Service, in project: Project) {
        guard runningProcesses[service.id] != nil,
              let currentStatus = serviceStatus(service.id, in: project.id),
              let evidence = ServiceStartupEvidence.classify(log: log) else { return }
        switch evidence {
        case .warning:
            updateService(service.id, in: project.id, status: .warning)
        case .ready where currentStatus == .starting:
            updateService(service.id, in: project.id, status: .running)
        case .ready:
            break
        }
    }

    private func serviceStatus(_ serviceID: String, in projectID: String) -> ServiceStatus? {
        guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
        return project.services.first(where: { $0.id == serviceID })?.status
    }

    private func updateService(_ serviceID: String, in projectID: String, status: ServiceStatus) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }), let serviceIndex = projects[projectIndex].services.firstIndex(where: { $0.id == serviceID }) else { return }
        projects[projectIndex].services[serviceIndex].status = status
    }

    func addInstance(name: String, host: String, project: String, token: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty, !trimmedToken.isEmpty,
              let endpoint = normalizedEndpoint(trimmedHost) else {
            toast = "请填写有效的实例名称、地址和 Access Token"
            return false
        }
        guard !instances.contains(where: { normalizedEndpoint($0.host)?.absoluteString == endpoint.absoluteString }) else {
            toast = "该 GitLab 实例已经添加"
            return false
        }
        let instance = GitLabInstance(id: UUID(), name: trimmedName, host: endpoint.absoluteString, project: project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未选择项目" : project)
        do {
            var bundle = loadCredentialBundle()
            bundle.gitLabTokens[instance.host] = trimmedToken
            try saveCredentialBundle(bundle)
            KeychainVault.shared.delete(account: "gitlab:\(instance.host)")
        } catch {
            toast = "GitLab Token 保存失败"
            return false
        }
        gitLabCredentialHosts.insert(instance.host)
        gitLabTokenCache[instance.host] = trimmedToken
        instances.append(instance)
        persistCIState()
        selectedInstanceID = instance.id
        toast = "GitLab 实例已添加"
        return true
    }

    func updateInstance(_ instance: GitLabInstance, name: String, host: String, project: String, token: String) -> Bool {
        guard let index = instances.firstIndex(where: { $0.id == instance.id }) else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? instance.name : trimmedName
        guard let endpoint = normalizedEndpoint(trimmedHost.isEmpty ? instance.host : trimmedHost) else {
            toast = "请输入有效的 GitLab 实例地址"
            return false
        }
        let resolvedHost = endpoint.absoluteString
        guard !instances.contains(where: { $0.id != instance.id && normalizedEndpoint($0.host)?.absoluteString == resolvedHost }) else {
            toast = "该 GitLab 实例已经添加"
            return false
        }
        let hadExistingToken = gitLabCredentialHosts.contains(instance.host)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard instance.host == resolvedHost || !trimmedToken.isEmpty else {
            toast = "地址已变更，请填写新实例的 Access Token"
            return false
        }
        let hasTokenAfterSave = !trimmedToken.isEmpty || (instance.host == resolvedHost && hadExistingToken)
        var bundle = loadCredentialBundle()
        var shouldSaveBundle = false
        if instance.host != resolvedHost {
            bundle.gitLabTokens.removeValue(forKey: instance.host)
            shouldSaveBundle = true
        }
        if !trimmedToken.isEmpty {
            bundle.gitLabTokens[resolvedHost] = trimmedToken
            shouldSaveBundle = true
        } else if !hasTokenAfterSave {
            bundle.gitLabTokens.removeValue(forKey: resolvedHost)
            shouldSaveBundle = true
        }
        if shouldSaveBundle {
            do { try saveCredentialBundle(bundle) }
            catch { toast = "GitLab Token 保存失败"; return false }
        }
        if instance.host != resolvedHost {
            KeychainVault.shared.delete(account: "gitlab:\(instance.host)")
            gitLabCredentialHosts.remove(instance.host)
            gitLabTokenCache.removeValue(forKey: instance.host)
            clearGitLabRefreshState(for: instance.id)
        }
        if !trimmedToken.isEmpty {
            gitLabCredentialHosts.insert(resolvedHost)
            gitLabTokenCache[resolvedHost] = trimmedToken
        } else if !hasTokenAfterSave {
            gitLabCredentialHosts.remove(resolvedHost)
        }
        invalidateCIRefresh(.gitlab(instance.id))
        instances[index] = GitLabInstance(id: instance.id, name: resolvedName, host: resolvedHost, project: project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? instance.project : project, isConnected: hasTokenAfterSave)
        persistCIState()
        toast = "已保存 GitLab 实例"
        return true
    }

    private func normalizedEndpoint(_ raw: String) -> URL? {
        var value = raw
        if !value.contains("://") { value = "https://\(value)" }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        components.scheme = scheme
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    func removeInstance(_ instance: GitLabInstance) {
        do {
            var bundle = loadCredentialBundle()
            bundle.gitLabTokens.removeValue(forKey: instance.host)
            try saveCredentialBundle(bundle)
        } catch {
            toast = "GitLab 凭据更新失败"
            return
        }
        KeychainVault.shared.delete(account: "gitlab:\(instance.host)")
        gitLabCredentialHosts.remove(instance.host)
        gitLabTokenCache.removeValue(forKey: instance.host)
        clearGitLabRefreshState(for: instance.id)
        instances.removeAll { $0.id == instance.id }
        let source = CISource.gitlab(instance.id)
        accessibleCIProjects.removeAll { source.contains(projectID: $0.id) }
        ciProjects.removeAll { source.contains(projectID: $0.id) }
        pipelineCache = pipelineCache.filter { !source.contains(projectID: $0.key) }
        persistCIState()
    }
}

// MARK: - Panel

struct StackHubPanel: View {
    @EnvironmentObject private var store: StackHubStore
    @EnvironmentObject private var appUpdater: AppUpdater
    @StateObject private var settingsState = SettingsPanelState()
    @StateObject private var githubOAuth = GitHubOAuthController()
    @State private var selectedDestination: PanelDestination?
    @AppStorage("stackhub.panel.height") private var panelHeight = 640.0
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.system.rawValue

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: languageRawValue) ?? .system
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if let service = store.selectedServiceLog {
                    ServiceLogDetailView(service: service) {
                        withAnimation(.easeOut(duration: 0.18)) { store.selectedServiceLogID = nil }
                    }
                    .id(service.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let destination = selectedDestination {
                    destinationContent(destination)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    mainPanelContent
                }
                PanelResizeHandle(height: $panelHeight)
                    .frame(height: 16)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 410, height: panelHeight)
            .background(Color(red: 0.055, green: 0.075, blue: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.52), radius: 28, y: 18)

            PanelWindowTuner(height: $panelHeight).frame(width: 0, height: 0)

            if let toast = store.toast {
                Text(L(toast))
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.12, green: 0.15, blue: 0.22), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.16)))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.locale, selectedLanguage.locale)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.18), value: store.toast)
        .alert(item: Binding(
            get: { appUpdater.driver.failure },
            set: { appUpdater.driver.failure = $0 }
        )) { failure in
            Alert(title: Text(L("更新失败")), message: Text(failure.message), dismissButton: .default(Text(L("好"))))
        }
        .onChange(of: store.tab) { _, tab in
            if tab == .ci { store.acknowledgeCIFailures() }
        }
    }

    private var mainPanelContent: some View {
        VStack(spacing: 0) {
            contentHeader
            TabStrip(selection: $store.tab)
                .padding(.horizontal, 16)
                .padding(.bottom, 13)
            if let pipeline = store.selectedPipeline, store.tab == .ci {
                // Keep the detail screen outside the page ScrollView so
                // the log viewer receives a bounded height and its own
                // vertical scroll gesture.
                PipelineDetailView(pipeline: pipeline) { store.selectedPipeline = nil }
                    .id(pipeline.id)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                OverlayScrollView {
                    Group {
                        switch store.tab {
                        case .projects:
                            ProjectsView(
                                onEditProject: openProjectEditor
                            )
                        case .ci:
                            CIView()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: .infinity)
            }
            HStack {
                QuitStackHubButton()
                Spacer()
                switch store.tab {
                case .projects:
                    FooterActionButton(title: "添加项目", systemName: "plus") { openNewProjectEditor() }
                case .ci:
                    FooterActionButton(title: "实例管理", systemName: "server.rack") { openCIInstanceManagement() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
        }
    }

    private var contentHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L(store.tab == .projects ? "项目" : "CI 活动"))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(L(store.tab == .projects ? "本地开发堆栈" : "查看各平台的构建与发布"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.46))
            }
            Spacer()
            LanguageSelector()
            AppUpdateButton()
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func destinationContent(_ destination: PanelDestination) -> some View {
        switch destination {
        case .projectEditor:
            if let draft = settingsState.projectDraft {
                ProjectEditorDetailView(draft: draft, onClose: closeDestination)
            }
        case .ciInstanceManagement:
            CIInstanceManagementDetailView(
                onManageGitHub: openGitHubAuthorization,
                onAddGitLab: openNewGitLabEditor,
                onEditGitLab: openGitLabEditor,
                onClose: closeDestination
            )
        case .githubAuthorization:
            GitHubAuthorizationDetailView(oauth: githubOAuth, onClose: closeDestination)
        case .gitLabEditor:
            if let draft = settingsState.gitlabDraft {
                GitLabInstanceDetailView(draft: draft, onClose: closeDestination)
            }
        }
    }

    private func openNewProjectEditor() {
        settingsState.beginNewProject()
        withAnimation(.easeOut(duration: 0.18)) { selectedDestination = .projectEditor }
    }

    private func openProjectEditor(_ project: Project) {
        settingsState.beginEditProject(project)
        withAnimation(.easeOut(duration: 0.18)) { selectedDestination = .projectEditor }
    }

    private func openCIInstanceManagement() {
        withAnimation(.easeOut(duration: 0.18)) { selectedDestination = .ciInstanceManagement }
    }

    private func openGitHubAuthorization() {
        withAnimation(.easeOut(duration: 0.18)) { selectedDestination = .githubAuthorization }
    }

    private func openNewGitLabEditor() {
        settingsState.beginNewInstance()
        withAnimation(.easeOut(duration: 0.18)) { selectedDestination = .gitLabEditor }
    }

    private func openGitLabEditor(_ instance: GitLabInstance) {
        settingsState.beginEditInstance(instance, hasExistingToken: store.hasGitLabCredential(instance))
        withAnimation(.easeOut(duration: 0.18)) { selectedDestination = .gitLabEditor }
    }

    private func closeDestination() {
        settingsState.cancelEditor()
        withAnimation(.easeOut(duration: 0.18)) { selectedDestination = nil }
    }
}

private struct QuitStackHubButton: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? .red : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .background(isHovering ? Color.red.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isHovering ? Color.red.opacity(0.2) : .clear)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(L("退出 StackHub"))
        .accessibilityLabel(L("退出 StackHub"))
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - Projects

struct MenuOverviewView: View {
    @EnvironmentObject private var store: StackHubStore

    var body: some View {
        let allServices = store.projects.flatMap(\.services)
        let runningServices = allServices.filter { $0.status == .running }.count
        let pipelines = store.pipelineCache.values.flatMap { $0 }
        let failedPipelines = pipelines.filter { $0.state == .failed }.count
        VStack(alignment: .leading, spacing: 13) {
            SectionLabel(title: "推荐")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    RecommendationCard(
                        icon: "arrow.clockwise.circle.fill",
                        title: "刷新 CI 活动",
                        detail: "同步已连接账号可访问的项目与流水线",
                        actionTitle: "立即刷新",
                        accent: .teal
                    ) { store.refreshCI() }
                    RecommendationCard(
                        icon: "plus.circle.fill",
                        title: "添加本地项目",
                        detail: "配置工作目录、服务和启动命令",
                        actionTitle: "前往项目",
                        accent: .orange
                    ) { store.tab = .projects }
                    RecommendationCard(
                        icon: "key.fill",
                        title: "连接 CI 账号",
                        detail: store.isGitHubConnected || !store.instances.isEmpty ? "认证已配置，可刷新流水线" : "在 CI 页面中添加 GitHub 或 GitLab",
                        actionTitle: "前往 CI",
                        accent: .blue
                    ) { store.tab = .ci }
                }
            }

            SectionLabel(title: "堆栈概览", trailing: LF("%ld 个本地项目", store.projects.count))
            OverviewFeatureCard(projectCount: store.projects.count, runningServices: runningServices, totalServices: allServices.count)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                MetricCard(icon: "square.grid.2x2.fill", title: "项目", value: "\(store.projects.count)", detail: "本地开发项目", tint: .blue) {
                    store.tab = .projects
                }
                MetricCard(icon: "server.rack", title: "服务", value: "\(runningServices) / \(allServices.count)", detail: allServices.isEmpty ? "尚未配置服务" : "正在运行", tint: .green) {
                    store.tab = .projects
                }
                MetricCard(icon: "bolt.horizontal.fill", title: "CI 流水线", value: "\(pipelines.count)", detail: failedPipelines == 0 ? "暂无失败" : LF("%ld 个失败", failedPipelines), tint: .orange) {
                    store.tab = .ci
                }
                MetricCard(icon: "shippingbox.fill", title: "GitLab 实例", value: "\(store.instances.count)", detail: "已连接", tint: .teal) {
                    store.tab = .ci
                }
            }
        }
    }
}

struct RecommendationCard: View {
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(accent)
                    Text(L(title))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .padding(.top, 11)
                    Text(L(detail))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(2)
                .padding(.top, 5)
            Spacer(minLength: 13)
            Button(L(actionTitle), action: action)
                .buttonStyle(RecommendationButtonStyle(accent: accent))
        }
        .padding(13)
        .frame(width: 186, height: 148, alignment: .leading)
        .background(
            LinearGradient(colors: [accent.opacity(0.12), Color.white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.16)))
    }
}

struct OverviewFeatureCard: View {
    let projectCount: Int
    let runningServices: Int
    let totalServices: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(totalServices == 0 || runningServices == totalServices ? .green : .orange)
                    Text("本地开发堆栈").font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Label(totalServices == 0 ? "未配置" : (runningServices == totalServices ? "健康" : "需要关注"), systemImage: totalServices == 0 ? "minus" : "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(totalServices == 0 || runningServices == totalServices ? .green : .orange)
            }
            Text(totalServices == 0 ? L("还没有配置本地项目") : LF("%ld / %ld 个服务运行中", runningServices, totalServices))
                .font(.system(size: 14, weight: .semibold))
            Text(L(projectCount == 0 ? "从项目页添加工作目录和服务后，这里会显示实时状态。" : "状态来自本机进程监控；服务启动、停止和健康检查将在此处汇总。"))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.48))
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.07)))
    }
}

struct MetricCard: View {
    let icon: String
    let title: String
    let value: String
    let detail: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).foregroundStyle(tint)
                    Spacer()
                    Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                Text(L(title)).font(.system(size: 12, weight: .semibold))
                Text(L(detail)).font(.caption2).foregroundStyle(.white.opacity(0.44))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.065)))
        }
        .buttonStyle(.plain)
    }
}

struct CompactProjectRow: View {
    @EnvironmentObject private var store: StackHubStore
    let project: Project
    private var state: ProjectRuntimeState { project.runtimeState }

    var body: some View {
        Button { store.toggle(project: project) } label: {
            HStack(spacing: 10) {
                Text(project.initial).font(.system(size: 14, weight: .bold, design: .rounded))
                    .frame(width: 30, height: 30)
                    .background(state == .issue ? .orange.opacity(0.82) : .indigo.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.subheadline.weight(.medium))
                    Text(LF("%ld 个服务", project.serviceCount)).font(.caption2).foregroundStyle(.white.opacity(0.46))
                }
                Spacer()
                HStack(spacing: 5) {
                    ForEach(0..<project.serviceCount, id: \.self) { _ in Circle().fill(state.color).frame(width: 6, height: 6) }
                }
                if state == .issue {
                    Circle()
                        .fill(.yellow)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("服务警告")
                } else {
                    Text(state.label).font(.caption2.weight(.medium)).foregroundStyle(state.color)
                }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.065)))
        }
        .buttonStyle(.plain)
    }
}

struct CompactCIBadge: View {
    let provider: String
    let title: String
    let state: PipelineState

    var body: some View {
        HStack(spacing: 8) {
            Text(provider).font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24).background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.caption.weight(.medium))
                Text(state.label).font(.caption2).foregroundStyle(state.color)
            }
            Spacer()
            Circle().fill(state.color).frame(width: 7, height: 7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.065)))
    }
}

struct ProjectsView: View {
    @EnvironmentObject private var store: StackHubStore
    let onEditProject: (Project) -> Void
    @State private var deletingProject: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "项目", trailing: LF("%ld 个项目 · %ld 个服务", store.projects.count, store.projects.flatMap(\.services).count))
            if store.projects.isEmpty {
                EmptyStateCard(icon: "folder.badge.plus", title: "还没有本地项目", detail: "点击“添加项目”，配置工作目录和服务。")
            } else {
                ForEach(store.projects) { project in
                    ProjectCard(
                        project: project,
                        onEdit: { onEditProject(project) },
                        onDelete: { deletingProject = project }
                    )
                }
            }
        }
        .alert("移除本地项目？", isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } })) {
            Button("移除项目", role: .destructive) {
                if let project = deletingProject { store.removeProject(project) }
                deletingProject = nil
            }
            Button("取消", role: .cancel) { deletingProject = nil }
        } message: {
            Text("只移除 StackHub 配置，不会删除磁盘上的项目文件。")
        }
    }
}

struct ProjectCard: View {
    @EnvironmentObject private var store: StackHubStore
    let project: Project
    let onEdit: () -> Void
    let onDelete: () -> Void
    private var projectIsRunning: Bool {
        project.services.contains { $0.status.hasManagedProcess }
    }
    private var state: ProjectRuntimeState { project.runtimeState }
    private var verifiedServiceCount: Int {
        project.services.filter { $0.status == .running }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { store.toggle(project: project) } label: {
                    HStack(spacing: 11) {
                    Text(project.initial)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .frame(width: 34, height: 34)
                        .background(state == .issue ? Color.orange.opacity(0.8) : Color.indigo.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(LF("%ld / %ld 个服务已就绪", verifiedServiceCount, project.serviceCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(minWidth: 0, alignment: .leading)
                    Spacer(minLength: 8)
                    Circle()
                        .fill(state == .issue ? .yellow : state.color)
                        .frame(width: 9, height: 9)
                        .accessibilityLabel(state.label)
                        .help(state == .issue ? "服务出现警告，查看日志了解详情" : state.label)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(project.isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    HoverIconButton(systemName: "pencil", help: "编辑项目", action: onEdit)
                    HoverIconButton(systemName: "trash", help: "移除项目", action: onDelete)
                    HoverIconButton(
                        systemName: projectIsRunning ? "stop.fill" : "play.fill",
                        help: projectIsRunning ? "停止" : "启动"
                    ) {
                        store.projectAction(project, action: projectIsRunning ? "停止" : "启动")
                    }
                }
            }
            .padding(12)
            if project.isExpanded {
                VStack(spacing: 0) {
                    ForEach(project.services) { service in ServiceRow(service: service) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
    }
}

struct ServiceRow: View {
    @EnvironmentObject private var store: StackHubStore
    let service: Service

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Circle().fill(service.status.color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(service.name).font(.subheadline)
                        Text(service.status.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(service.status.color)
                    }
                    Text(service.command)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 5) {
                    HoverIconButton(systemName: "doc.text", help: "打开日志") {
                        withAnimation(.easeOut(duration: 0.18)) { store.openServiceLog(service) }
                    }
                    HoverIconButton(systemName: "arrow.up.right", help: "打开服务") { store.openService(service) }
                    HoverIconButton(systemName: "arrow.clockwise", help: "重启服务") { store.restartService(service) }
                    HoverIconButton(systemName: service.status.hasManagedProcess ? "stop.fill" : "play.fill", help: service.status.hasManagedProcess ? "停止服务" : "启动服务") { store.serviceAction(service) }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 7)
        }
        .overlay(alignment: .top) { Divider().opacity(0.35) }
    }
}

struct ServiceLogDetailView: View {
    @EnvironmentObject private var store: StackHubStore
    let service: Service
    let onClose: () -> Void

    private var log: String {
        let value = store.serviceLogs[service.id] ?? ""
        // Keep the inline viewer responsive when a development server is
        // verbose while retaining the newest output users need to inspect.
        let limit = 24_000
        guard value.count > limit else { return value }
        return "…较早日志已截断…\n" + String(value.suffix(limit))
    }

    private var lineCount: Int {
        log.isEmpty ? 0 : log.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private var displayedLog: AttributedString {
        guard !log.isEmpty else {
            var placeholder = AttributedString("服务尚未输出日志。启动后 stdout/stderr 会实时显示。")
            placeholder.foregroundColor = .secondary
            return placeholder
        }
        return ANSILogRenderer.attributedString(from: log)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Label("返回", systemImage: "chevron.left")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(StackSecondaryButtonStyle())
                .controlSize(.small)
                .accessibilityLabel("返回项目")

                Image(systemName: "terminal")
                    .font(.title3)
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("运行日志").font(.subheadline.weight(.semibold))
                    Text(LF("%@ · %@", service.name, lineCount == 0 ? L("暂无输出") : LF("%ld 行", lineCount)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(service.status.label, systemImage: "circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(service.status.color)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: true, vertical: false)

                Button {
                    store.serviceAction(service)
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(StackIconButtonStyle())
                .disabled(service.status.hasManagedProcess)
                .accessibilityLabel("启动服务")
                .help(service.status.hasManagedProcess ? "服务正在运行" : "启动服务")

                Button {
                    store.restartService(service)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(StackIconButtonStyle())
                .accessibilityLabel("重启服务")
                .help("重启服务")
                Button("清空") { store.clearServiceLog(service) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .disabled(log.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }

            OverlayScrollView {
                Text(displayedLog)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.26))
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.12))
        .closesOnEscape(perform: onClose)
    }
}

// MARK: - CI

struct CIView: View {
    @EnvironmentObject private var store: StackHubStore
    @State private var expandedProjectID: String?
    private let refreshTimer = Timer.publish(every: StackHubStore.ciRefreshInterval, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "关注项目", trailing: "与本地项目独立")
            if store.visibleFollowedCIProjects.isEmpty {
                EmptyStateCard(icon: "eye.slash", title: "还没有关注项目", detail: "在下方流水线列表中点击“关注项目”即可添加。")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.visibleFollowedCIProjects) { project in
                        CIProjectCard(
                            project: project,
                            runs: store.recentPipelines(for: project),
                            isExpanded: expandedProjectID == project.id,
                            onToggle: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    expandedProjectID = expandedProjectID == project.id ? nil : project.id
                                    store.selectedCIProjectID = project.id
                                }
                            },
                            onOpen: { pipeline in store.openPipeline(pipeline) },
                            onStageTap: { pipeline, _ in store.openPipeline(pipeline) }
                        )
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(L("全部流水线"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                CIRefreshStatusButton()
            }
            .padding(.horizontal, 2)
            .padding(.top, 5)
            Text("来自已连接账号触发的最近活动；关注项目后会在上方持续跟踪最近 5 条。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            LazyVStack(spacing: 8) {
                ForEach(store.recentCIActivities) { activity in
                    CIActivityRow(
                        project: activity.project,
                        pipeline: activity.pipeline,
                        isFollowing: store.isFollowing(activity.project.id),
                        onFollow: {
                            if store.isFollowing(activity.project.id) {
                                store.unfollowProject(activity.project.id)
                            } else {
                                store.followProject(activity.project.id)
                            }
                        },
                        onOpen: { store.openPipeline(activity.pipeline) },
                        onStageTap: { _ in store.openPipeline(activity.pipeline) }
                    )
                }
            }
            if store.accessibleCIProjects.isEmpty {
                EmptyStateCard(icon: "arrow.down.circle", title: store.isGitHubConnected || !store.instances.isEmpty ? "正在同步流水线" : "先连接 CI 账号", detail: store.ciError ?? "打开 CI 页面后会自动加载你有权限查看的项目和流水线。")
            }
        }
        .onAppear {
            store.acknowledgeCIFailures()
            store.refreshCIIfNeeded()
        }
        .onReceive(refreshTimer) { _ in store.refreshCIIfNeeded() }
    }
}

private struct CIRefreshStatusButton: View {
    @EnvironmentObject private var store: StackHubStore

    var body: some View {
        Button { store.refreshCI() } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Image(systemName: store.isRefreshingCI ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    Text(updateAge(at: context.date))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(minHeight: 20)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(store.ciError ?? L("点击立即刷新 CI"))
        .accessibilityLabel(L("立即刷新 CI"))
    }

    private func updateAge(at date: Date) -> String {
        if store.isRefreshingCI { return L("刷新中") }
        if store.ciError != nil { return L("部分连接失败") }
        guard let lastRefresh = store.lastCIRefresh else { return L("尚未更新") }
        let elapsedSeconds = max(0, Int(date.timeIntervalSince(lastRefresh)))
        if elapsedSeconds < 60 { return LF("%ld 秒前", elapsedSeconds) }
        return LF("%ld 分钟前", elapsedSeconds / 60)
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title)).font(.subheadline.weight(.semibold))
                Text(L(detail)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(13)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.07)))
    }
}

struct CIActivityRow: View {
    @EnvironmentObject private var store: StackHubStore
    let project: CIAccessibleProject
    let pipeline: Pipeline
    let isFollowing: Bool
    let onFollow: () -> Void
    let onOpen: () -> Void
    let onStageTap: ((PipelineStage) -> Void)?

    init(
        project: CIAccessibleProject,
        pipeline: Pipeline,
        isFollowing: Bool,
        onFollow: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onStageTap: ((PipelineStage) -> Void)? = nil
    ) {
        self.project = project
        self.pipeline = pipeline
        self.isFollowing = isFollowing
        self.onFollow = onFollow
        self.onOpen = onOpen
        self.onStageTap = onStageTap
    }

    private var providerCode: String { project.provider.hasPrefix("GitHub") ? "GH" : "GL" }
    private var timeLabel: String {
        guard let date = pipeline.updatedAt else { return L("时间未知") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.selected.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(providerCode)
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(project.provider) · \(project.name)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("\(project.repository) / \(project.branch) · \(timeLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 5)
                HStack(spacing: 5) {
                    Circle().fill(pipeline.state.color).frame(width: 7, height: 7)
                    Text(pipeline.state.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(pipeline.state.color)
                }
            }

            HStack(spacing: 7) {
                Text(L(pipeline.id.hasPrefix("github") ? "构建与测试" : "发布流水线"))
                    .font(.caption.weight(.semibold))
                CIStageProgress(stages: pipeline.stages, isLoaded: pipeline.hasLoadedStages, onStageTap: onStageTap)
                Spacer(minLength: 2)
                if pipeline.duration != "—" {
                    Text(pipeline.duration)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button(action: onFollow) {
                    Image(systemName: isFollowing ? "star.fill" : "star")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(CIFollowButtonStyle(isFollowing: isFollowing))
                .accessibilityLabel(isFollowing ? "取消关注项目" : "关注项目")
                .accessibilityHint("点击切换关注状态")
                .help(isFollowing ? "取消关注项目" : "关注项目")
                Button(L("查看"), action: onOpen)
                    .buttonStyle(StackSecondaryButtonStyle())
                    .controlSize(.small)
                    .help(L(pipeline.provider == "GitHub Actions" ? "查看运行" : "查看流水线"))
                    .accessibilityLabel(L(pipeline.provider == "GitHub Actions" ? "查看运行" : "查看流水线"))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.075)))
        .onAppear { store.loadGitLabPipelineTimingIfNeeded(for: pipeline) }
    }
}

struct CIFollowButtonStyle: ButtonStyle {
    let isFollowing: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isFollowing ? .yellow : .white.opacity(0.6))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CIProjectCard: View {
    @EnvironmentObject private var store: StackHubStore
    let project: CIMonitoredProject
    let runs: [Pipeline]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onOpen: (Pipeline) -> Void
    let onStageTap: (Pipeline, PipelineStage) -> Void

    private var latest: Pipeline? { runs.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Text(project.provider.hasPrefix("GitHub") ? "GH" : "GL")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.subheadline.weight(.semibold))
                        Text(project.provider + (project.instanceName.map { " · \($0)" } ?? ""))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        if let latest {
                            HStack(spacing: 5) {
                                Circle().fill(latest.state.color).frame(width: 8, height: 8)
                                Text(latest.state.label).font(.caption2.weight(.medium)).foregroundStyle(latest.state.color)
                            }
                            if let duration = latest.executionDurationLabel {
                                Text(duration)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("尚无同步数据").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(.leading, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let latest {
                HStack(spacing: 7) {
                    Text("最新流水线")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    CIStageProgress(
                        stages: latest.stages,
                        isLoaded: latest.hasLoadedStages,
                        onStageTap: { stage in onStageTap(latest, stage) }
                    )
                    Spacer()
                    Text(latest.executionTimestampLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 7)
            } else {
                Text("刷新后显示最近流水线")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 7)
            }

            if isExpanded && !runs.isEmpty {
                Divider().padding(.vertical, 8)
                VStack(spacing: 0) {
                    ForEach(Array(runs.prefix(5).enumerated()), id: \.element.id) { index, pipeline in
                        CIRunRow(
                            pipeline: pipeline,
                            timeLabel: runTimeLabel(index),
                            onOpen: { onOpen(pipeline) },
                            onStageTap: { stage in onStageTap(pipeline, stage) }
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isExpanded ? Color.purple.opacity(0.34) : Color.white.opacity(0.075)))
    }

    private func runTimeLabel(_ index: Int) -> String {
        guard runs.indices.contains(index), let date = runs[index].updatedAt else { return L("时间未知") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.selected.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct CIStageProgress: View {
    let stages: [PipelineStage]
    let isLoaded: Bool
    let onStageTap: ((PipelineStage) -> Void)?

    init(stages: [PipelineStage], isLoaded: Bool = true, onStageTap: ((PipelineStage) -> Void)? = nil) {
        self.stages = stages
        self.isLoaded = isLoaded
        self.onStageTap = onStageTap
    }

    var body: some View {
        HStack(spacing: 7) {
            if !isLoaded {
                if let summary = stages.first, let onStageTap {
                    Button { onStageTap(summary) } label: {
                        indicator(systemName: "ellipsis", color: .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("流水线摘要，点击查看步骤"))
                } else {
                    indicator(systemName: "ellipsis", color: .secondary)
                }
            } else {
                ForEach(stages.groupedPipelineStages) { stage in
                    stageIndicator(stage)
                }
            }
        }
    }

    @ViewBuilder
    private func stageIndicator(_ stage: PipelineStageGroup) -> some View {
        let content = HStack(spacing: 3) {
            indicator(color: stage.state.color)
            if stage.jobs.count > 1 {
                // This is not a separator between fixed dots. It appears only
                // when a provider stage fans out into real child jobs.
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(stage.jobs.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }

        if let onStageTap, let firstJob = stage.jobs.first {
            Button { onStageTap(firstJob) } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel(LF("阶段 %@，%@，%ld 个作业，点击查看步骤", stage.name, stage.state.label, stage.jobs.count))
        } else {
            content
        }
    }

    @ViewBuilder
    private func indicator(systemName: String? = nil, color: Color) -> some View {
        if let systemName {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 15, height: 15)
                .background(color.opacity(0.12), in: Circle())
        } else {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .padding(3)
                .background(color.opacity(0.16), in: Circle())
        }
    }
}

struct CIRunRow: View {
    let pipeline: Pipeline
    let timeLabel: String
    let onOpen: () -> Void
    let onStageTap: ((PipelineStage) -> Void)?

    init(
        pipeline: Pipeline,
        timeLabel: String,
        onOpen: @escaping () -> Void,
        onStageTap: ((PipelineStage) -> Void)? = nil
    ) {
        self.pipeline = pipeline
        self.timeLabel = timeLabel
        self.onOpen = onOpen
        self.onStageTap = onStageTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(pipeline.state.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(pipeline.id.hasPrefix("github") ? "构建与测试" : "发布流水线"))
                        .font(.caption.weight(.medium))
                    Text("\(pipeline.commit) · \(timeLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(pipeline.duration).font(.caption2).foregroundStyle(.secondary)
                Button("查看") { onOpen() }
                    .buttonStyle(StackSecondaryButtonStyle())
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                Text("阶段")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                CIStageProgress(stages: pipeline.stages, isLoaded: pipeline.hasLoadedStages, onStageTap: onStageTap)
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider().opacity(0.25) }
    }
}

struct PipelineCard: View {
    @EnvironmentObject private var store: StackHubStore
    let pipeline: Pipeline
    var monitoredProject: CIMonitoredProject?
    var instanceName: String?

    private var providerTitle: String {
        let provider = monitoredProject?.provider ?? pipeline.provider
        guard let instance = instanceName ?? monitoredProject?.instanceName else { return provider }
        return "\(provider) · \(instance)"
    }

    private var repositorySummary: String {
        let repository = monitoredProject?.repository ?? pipeline.repository
        let branch = monitoredProject?.branch ?? pipeline.branch
        return LF("%@ / %@ · 17 分钟前", repository, branch)
    }

    private var pipelineTitle: String {
        L(pipeline.id.hasPrefix("github") ? "构建与测试" : "发布流水线")
    }

    private var providerBadge: some View {
        Text(pipeline.provider == "GitHub Actions" ? "GH" : "GL")
            .font(.caption.weight(.bold))
            .frame(width: 28, height: 28)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var cardHeader: some View {
        HStack {
            HStack(spacing: 9) {
                providerBadge
                VStack(alignment: .leading, spacing: 3) {
                    Text(providerTitle).font(.subheadline.weight(.semibold))
                    Text(repositorySummary).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Label(pipeline.state.label, systemImage: "circle.fill")
                .font(.caption2)
                .foregroundStyle(pipeline.state.color)
        }
        .padding(.bottom, 11)
    }

    private var pipelineSummary: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pipelineTitle).font(.headline)
                Text(pipeline.commit).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(pipeline.duration).font(.caption2).foregroundStyle(.secondary)
                Button(L(pipeline.provider == "GitHub Actions" ? "查看运行" : "查看流水线")) {
                    store.openPipeline(pipeline)
                }
                .buttonStyle(StackSecondaryButtonStyle())
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var gitLabStages: some View {
        if pipeline.provider == "GitLab CI" {
            Divider().padding(.vertical, 8)
            ForEach(pipeline.stages) { stage in
                StageRow(stage: stage)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            pipelineSummary
            gitLabStages
        }
        .padding(13)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
    }
}

struct StageRow: View {
    @EnvironmentObject private var store: StackHubStore
    let stage: PipelineStage
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { store.expandedStageID = store.expandedStageID == stage.id ? nil : stage.id } label: {
                HStack {
                    Circle().fill(stage.state.color).frame(width: 9, height: 9)
                    Text(stage.name).font(.subheadline)
                    Spacer()
                    Text(stage.duration).font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary).rotationEffect(.degrees(store.expandedStageID == stage.id ? 180 : 0))
                }
            }.buttonStyle(.plain)
            if store.expandedStageID == stage.id {
                Text(stage.log)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Pipeline detail

struct PipelineDetailView: View {
    @EnvironmentObject private var store: StackHubStore
    let pipeline: Pipeline
    let onClose: () -> Void
    @State private var selectedStageID: String?
    @State private var expandedStageGroupID: String?

    init(pipeline: Pipeline, onClose: @escaping () -> Void) {
        self.pipeline = pipeline
        self.onClose = onClose
        // Opening a pipeline is intentionally a steps-only view. A stage is
        // selected only when the user clicks a stage chip in this detail view.
        _selectedStageID = State(initialValue: nil)
        _expandedStageGroupID = State(initialValue: nil)
    }

    private var selectedStage: PipelineStage? {
        guard let selectedStageID else { return nil }
        return pipeline.stages.first(where: { $0.id == selectedStageID })
    }

    private var displayedLog: String {
        guard pipeline.hasLoadedStages else { return L("正在加载作业日志…") }
        guard let selectedStage else { return L("暂无作业日志") }
        guard !selectedStage.log.isEmpty else {
            return store.isLoadingStage(selectedStage.id) ? L("正在加载该步骤日志…") : L("该阶段暂无日志")
        }
        return "[\(selectedStage.name)]\n\(selectedStage.log)"
    }

    private var logLineCount: Int {
        guard pipeline.hasLoadedStages, selectedStage?.log.isEmpty == false else { return 0 }
        return displayedLog.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text(L(pipeline.provider == "GitHub Actions" ? "构建与测试" : "发布流水线")).font(.headline); Text("\(pipeline.repository) / \(pipeline.branch)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("返回", action: onClose).buttonStyle(StackSecondaryButtonStyle()) }
            PipelineStageGroupList(
                pipeline: pipeline,
                selectedStageID: $selectedStageID,
                expandedGroupID: $expandedStageGroupID
            )
            if let selectedStage {
                HStack {
                    Text("作业日志").font(.subheadline.weight(.semibold))
                    Text("· \(selectedStage.name)").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(logLineCount == 0 ? L(pipeline.hasLoadedStages ? "暂无日志" : "正在加载") : LF("%ld 行", logLineCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                OverlayScrollView {
                    Text(displayedLog)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Button("复制日志") { copyLog() }
                        .buttonStyle(StackSecondaryButtonStyle())
                        .disabled(logLineCount == 0)
                    Spacer()
                    Button(LF("在 %@ 中打开", pipeline.provider == "GitHub Actions" ? "GitHub" : "GitLab")) { openExternal() }
                        .buttonStyle(StackPrimaryButtonStyle())
                        .disabled(pipeline.webURL == nil)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("请选择一个步骤查看日志")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("先查看步骤状态，再按需加载对应作业日志")
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.75))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Spacer()
                    Button(LF("在 %@ 中打开", pipeline.provider == "GitHub Actions" ? "GitHub" : "GitLab")) { openExternal() }
                        .buttonStyle(StackPrimaryButtonStyle())
                        .disabled(pipeline.webURL == nil)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(.dark)
        .onChange(of: pipeline.stages.map(\.id)) { _, stageIDs in
            guard !stageIDs.isEmpty else {
                selectedStageID = nil
                return
            }
            guard let selectedStageID, stageIDs.contains(selectedStageID) else {
                // A normal "查看流水线" action remains steps-only even after
                // the async job list replaces the summary placeholder.
                selectedStageID = nil
                return
            }
        }
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedLog, forType: .string)
    }

    private func openExternal() {
        guard let value = pipeline.webURL, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PipelineStageGroupList: View {
    @EnvironmentObject private var store: StackHubStore
    let pipeline: Pipeline
    @Binding var selectedStageID: String?
    @Binding var expandedGroupID: String?

    private var groups: [PipelineStageGroup] { pipeline.stages.groupedPipelineStages }

    var body: some View {
        Group {
            if !pipeline.hasLoadedStages {
                HStack(spacing: 8) {
                    CIStageProgress(stages: pipeline.stages, isLoaded: false)
                    Text(L("正在加载步骤…"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                OverlayScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groups) { group in
                            stageGroup(group)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: selectedStageID == nil ? 210 : 150, alignment: .topLeading)
        .onAppear { selectFirstAvailableGroupIfNeeded() }
        .onChange(of: groups.map(\.id)) { _, _ in selectFirstAvailableGroupIfNeeded() }
    }

    private func stageGroup(_ group: PipelineStageGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    expandedGroupID = expandedGroupID == group.id ? nil : group.id
                }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(group.state.color).frame(width: 9, height: 9)
                    Text(LF("阶段：%@", group.name)).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(LF("%ld 个作业", group.jobs.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expandedGroupID == group.id ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LF("阶段 %@，%ld 个作业", group.name, group.jobs.count))

            if expandedGroupID == group.id {
                VStack(spacing: 0) {
                    ForEach(group.jobs) { job in
                        Button {
                            selectedStageID = job.id
                            store.loadStageLog(for: pipeline, stage: job)
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(job.state.color).frame(width: 7, height: 7)
                                Text(job.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text(job.duration)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if selectedStageID == job.id {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(job.state.color)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(selectedStageID == job.id ? job.state.color.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LF("作业 %@，%@，点击查看日志", job.name, job.state.label))
                    }
                }
                .padding(.leading, 17)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07)))
    }

    private func selectFirstAvailableGroupIfNeeded() {
        let groupIDs = Set(groups.map(\.id))
        if let expandedGroupID, groupIDs.contains(expandedGroupID) { return }
        expandedGroupID = groups.first?.id
    }
}

// MARK: - Components

struct StackInputFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            // macOS 的默认 TextField 会再绘制一层原生背景；与自定义
            // material 叠加后会出现“双层输入框”。统一使用 plain 样式，
            // 只保留 StackHub 自己的单层容器。
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white.opacity(0.11), lineWidth: 1))
    }
}

struct TabStrip: View {
    @Binding var selection: PanelTab

    var body: some View {
        HStack(spacing: 3) {
            ForEach(PanelTab.allCases) { tab in
                Button { selection = tab } label: {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .foregroundStyle(selection == tab ? .white : .white.opacity(0.48))
                .background(selection == tab ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.1)))
    }
}

struct SidebarItem: View {
    let title: String
    let systemImage: String
    let selected: Bool
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                Text(L(title)).font(.system(size: 12, weight: selected ? .semibold : .medium))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected ? .white : .white.opacity(0.45))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(selected ? .purple.opacity(0.8) : .white.opacity(0.08), in: Capsule())
                }
            }
            .foregroundStyle(selected ? .white : .white.opacity(0.52))
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .background(selected ? .purple.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(.purple).frame(width: 3, height: 22)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
    }
}

struct StackSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.7 : 0.9))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StackPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                LinearGradient(colors: [Color(red: 0.52, green: 0.43, blue: 0.98), Color(red: 0.39, green: 0.3, blue: 0.82)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .shadow(color: .purple.opacity(0.2), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StackPrimaryIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Color.purple.opacity(configuration.isPressed ? 0.62 : 0.9), in: RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RecommendationButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(accent.opacity(configuration.isPressed ? 0.58 : 0.82), in: RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SectionLabel: View {
    let title: String
    var trailing: String?
    var body: some View { HStack { Text(L(title)).font(.subheadline.weight(.semibold)); Spacer(); if let trailing { Text(L(trailing)).font(.caption2).foregroundStyle(.secondary) } }.padding(.horizontal, 2).padding(.top, 5) }
}

struct SmallIconButton: View {
    let systemName: String
    let action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: systemName).frame(width: 28, height: 28) }.buttonStyle(StackIconButtonStyle()) }
}

private struct HoverIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isHovering ? 0.92 : 0.7))
        .background(isHovering ? Color.white.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isHovering ? .white.opacity(0.085) : .clear))
        .onHover { isHovering = $0 }
        .help(L(help))
        .accessibilityLabel(L(help))
    }
}

private struct FooterActionButton: View {
    let title: String
    let systemName: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .medium))
                Text(L(title))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isHovering ? 0.92 : 0.7))
        .background(isHovering ? Color.white.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isHovering ? .white.opacity(0.085) : .clear))
        .onHover { isHovering = $0 }
        .help(L(title))
        .accessibilityLabel(L(title))
    }
}

struct StackIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.65 : 0.8))
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.065), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.085)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
