import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    let driver = UpdateUserDriver()
    @Published private(set) var canCheckForUpdates = false
    private var updater: SPUUpdater?
    private var observations = Set<AnyCancellable>()

    override init() {
        super.init()
        driver.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &observations)
    }

    func start() {
        // swift run and unit tests are not installed application bundles.
        guard updater == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observations)
        do {
            try updater.start()
            if updater.automaticallyChecksForUpdates {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            NSLog("StackHub updater could not start: %@", error.localizedDescription)
        }
    }

    func installUpdate() {
        guard let updater, canCheckForUpdates, driver.beginInstallation() else { return }
        updater.checkForUpdates()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        driver.clearAvailableUpdate()
    }
}

struct UpdateFailure: Identifiable {
    let id = UUID()
    let message: String
}

/// Sparkle owns downloading, signature validation, installation and relaunch.
/// This driver only presents that lifecycle in the panel's compact button.
@MainActor
final class UpdateUserDriver: NSObject, ObservableObject, SPUUserDriver {
    enum Phase { case idle, checking, downloading, extracting, installing }

    @Published private(set) var availableVersion: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double?
    @Published var failure: UpdateFailure?
    private var installRequested = false
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    var isVisible: Bool { availableVersion != nil || phase != .idle }
    var isBusy: Bool { phase != .idle }

    var help: String {
        switch phase {
        case .idle: return LF("下载 %@ 并重启", availableVersion ?? "")
        case .checking: return L("正在检查更新…")
        case .downloading:
            return progress.map { LF("正在下载更新：%ld%%", Int($0 * 100)) } ?? L("正在下载更新…")
        case .extracting: return L("正在验证并准备更新…")
        case .installing: return L("正在安装，即将重启…")
        }
    }

    @discardableResult
    func beginInstallation() -> Bool {
        guard availableVersion != nil, !isBusy else { return false }
        installRequested = true
        failure = nil
        phase = .checking
        return true
    }

    func clearAvailableUpdate() {
        availableVersion = nil
    }

    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState) async -> SPUUserUpdateChoice {
        offerUpdate(version: appcastItem.displayVersionString, informationOnly: appcastItem.isInformationOnlyUpdate)
    }

    func offerUpdate(version: String, informationOnly: Bool = false) -> SPUUserUpdateChoice {
        guard !informationOnly else {
            availableVersion = nil
            if installRequested {
                failure = UpdateFailure(message: L("此版本无法自动安装，请查看 GitHub Release。"))
            }
            return .dismiss
        }
        availableVersion = version
        // Dismiss background offers without skipping the version. This keeps
        // Sparkle's scheduler running and allows a newer release to replace it.
        return installRequested ? .install : .dismiss
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error) async {
        clearAvailableUpdate()
    }

    func showUpdaterError(_ error: Error) async {
        if installRequested {
            failure = UpdateFailure(message: error.localizedDescription)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        progress = nil
        phase = .downloading
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        updateDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (total, overflow) = receivedLength.addingReportingOverflow(length)
        receivedLength = overflow ? .max : total
        updateDownloadProgress()
    }

    private func updateDownloadProgress() {
        progress = expectedLength > 0 ? min(1, Double(receivedLength) / Double(expectedLength)) : nil
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .extracting
        progress = nil
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        self.progress = progress.isFinite ? min(1, max(0, progress)) : nil
    }

    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        // Only the user's download button authorizes the subsequent relaunch.
        guard installRequested else { return .dismiss }
        phase = .installing
        progress = nil
        return .install
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        progress = nil
        // The app delegate's normal quit path stops managed services.
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        clearAvailableUpdate()
    }

    func dismissUpdateInstallation() {
        installRequested = false
        phase = .idle
        progress = nil
    }
}

struct AppUpdateButton: View {
    @EnvironmentObject private var appUpdater: AppUpdater

    var body: some View {
        let driver = appUpdater.driver
        if driver.isVisible {
            Button(action: appUpdater.installUpdate) {
                Group {
                    if driver.isBusy {
                        if let progress = driver.progress {
                            ZStack {
                                Circle().stroke(Color.blue.opacity(0.2), lineWidth: 2)
                                Circle().trim(from: 0, to: progress)
                                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 14, height: 14)
                        } else {
                            ProgressView().controlSize(.mini).tint(.blue)
                        }
                    } else {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelHeaderIconButtonStyle())
            .disabled(driver.isBusy || !appUpdater.canCheckForUpdates)
            .help(driver.help)
            .accessibilityLabel(driver.help)
        }
    }
}

struct PanelHeaderIconButtonStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(
                Color.white.opacity(isEnabled && (isHovered || configuration.isPressed)
                    ? (configuration.isPressed ? 0.12 : 0.07) : 0),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .onHover { isHovered = $0 }
    }
}
