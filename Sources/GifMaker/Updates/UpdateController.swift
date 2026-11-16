import AppKit
import Combine
import GifMakerCore

/// Looks for updates in the folder chosen in Settings and installs them.
///
/// Checks are quiet: a result only ever changes what Settings and the menus
/// show. Nothing is installed until the user asks for it.
@MainActor
final class UpdateController: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available
        /// The check found nothing to offer; the text says why.
        case unavailable(String)
        /// An install is under way; the text is the current step.
        case installing(String)
        case failed(String)
    }

    /// What became of an update, reported by the app's first launch after it.
    enum Outcome: Equatable {
        case updated(signatureChanged: Bool)
        case failed
    }

    @Published private(set) var status: Status = .idle
    /// The newest published build, when it is newer than this one and ready.
    @Published private(set) var availableUpdate: AvailableUpdate?
    /// Set when this launch follows an update, or an attempt at one.
    @Published private(set) var lastOutcome: Outcome?

    /// The running app's version; `nil` in a development build with no Info.plist.
    let currentVersion: AppVersion?
    /// Whether the running app is signed without a certificate.
    let isAdHocSigned: Bool
    /// Asked before installing. Returns why the app can't be restarted right
    /// now (a recording or an export is running), or `nil` if it can.
    var installBlocker: (() -> String?)?

    private let preferences: Preferences
    private let installer: UpdateInstaller?
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    /// Identifies the newest check, so a slow one can't overwrite a later result.
    private var checkID = 0

    /// A check that found the app up to date isn't repeated for this long.
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// How often the app looks at whether a check is due while it stays open.
    static let pollInterval: TimeInterval = 60 * 60

    init(preferences: Preferences, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.preferences = preferences
        installer = UpdateInstaller.forRunningApp()
        currentVersion = installer?.currentVersion ?? AppVersion(infoDictionary: Bundle.main.infoDictionary)
        isAdHocSigned = CodeSignature.isAdHoc(Bundle.main.bundleURL)

        typealias Argument = UpdateInstallPlan.LaunchArgument
        if arguments.contains(Argument.failed) {
            lastOutcome = .failed
        } else if arguments.contains(Argument.updated) {
            lastOutcome = .updated(signatureChanged: arguments.contains(Argument.signatureChanged))
        }
    }

    var isBusy: Bool {
        switch status {
        case .checking, .installing: return true
        default: return false
        }
    }

    var isInstalling: Bool {
        if case .installing = status { return true }
        return false
    }

    /// Whether this copy of the app can check for updates at all.
    var canCheck: Bool { currentVersion != nil }

    // MARK: Checking

    /// Starts background checks. Call once, after launch.
    func start() {
        // Changing the folder or turning checks back on is a reason to look now.
        preferences.$updateFolder
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                // The published value arrives before the property changes.
                DispatchQueue.main.async { self?.folderChanged() }
            }
            .store(in: &subscriptions)
        preferences.$automaticallyChecksForUpdates
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.checkIfDue() } }
            .store(in: &subscriptions)

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Let the app finish launching first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkIfDue() }
    }

    /// Runs a background check if one is due: the option is on, a folder is
    /// set, and the last check wasn't a recent "up to date".
    func checkIfDue() {
        guard preferences.automaticallyChecksForUpdates, preferences.updateFolder != nil, canCheck, !isBusy else {
            return
        }
        if preferences.lastUpdateCheckWasUpToDate, let last = preferences.lastUpdateCheck,
            abs(Date().timeIntervalSince(last)) < Self.checkInterval
        {
            return
        }
        check()
    }

    /// Checks now, whatever the schedule says.
    func checkNow() {
        guard !isBusy else { return }
        check()
    }

    private func folderChanged() {
        guard !isInstalling else { return }
        checkID += 1
        availableUpdate = nil
        status = .idle
        preferences.lastUpdateCheck = nil
        if preferences.updateFolder != nil, canCheck { check() }
    }

    private func check() {
        guard let currentVersion else {
            status = .unavailable("Updates work in the built app, not in a development build.")
            return
        }
        guard let folder = preferences.updateFolder else {
            status = .unavailable("Choose the folder your builds are published to first.")
            return
        }
        checkID += 1
        let id = checkID
        status = .checking
        let checker = UpdateChecker(folder: folder, currentVersion: currentVersion)
        Task.detached(priority: .utility) {
            let result = checker.check()
            await MainActor.run { [weak self] in self?.finishCheck(result, id: id) }
        }
    }

    private func finishCheck(_ result: UpdateCheckResult, id: Int) {
        guard id == checkID, status == .checking else { return }
        preferences.lastUpdateCheck = Date()
        preferences.lastUpdateCheckWasUpToDate = result == .upToDate
        switch result {
        case .upToDate:
            availableUpdate = nil
            status = .upToDate
        case .available(let update):
            availableUpdate = update
            status = .available
        case .failed(let failure):
            availableUpdate = nil
            status = .unavailable(failure.message)
        }
    }

    // MARK: Installing

    /// Installs the available update and restarts the app.
    func installUpdate() {
        guard let update = availableUpdate, !isBusy else { return }
        guard let installer else {
            status = .failed("Updates can only be installed by the built app, not a development build.")
            return
        }
        if let reason = installBlocker?() {
            status = .failed(reason)
            return
        }
        do {
            try installer.checkInstallLocation()
        } catch {
            // The app can't replace itself here, so hand over the disk image.
            status = .failed(error.localizedDescription)
            showDiskImage()
            return
        }

        status = .installing("Preparing…")
        let report: @Sendable (String) -> Void = { [weak self] step in
            Task { @MainActor in
                if self?.isInstalling == true { self?.status = .installing(step) }
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let prepared = try installer.prepare(update, progress: report)
                await self?.finishInstall(prepared, installer: installer)
            } catch {
                let message = error.localizedDescription
                await self?.installFailed(message)
            }
        }
    }

    private func installFailed(_ message: String) {
        status = .failed(message)
    }

    private func finishInstall(_ prepared: UpdateInstaller.Prepared, installer: UpdateInstaller) {
        // A recording may have started while the update was being prepared.
        if let reason = installBlocker?() {
            installer.discard(prepared)
            status = .failed(reason)
            return
        }
        do {
            try installer.startSwap(prepared) { [weak self] _ in
                // The script only finishes under a running app if the app never quit.
                Task { @MainActor in
                    self?.status = .failed("GIF Maker didn't quit, so the update wasn't installed. Try again.")
                }
            }
        } catch {
            installer.discard(prepared)
            status = .failed("The update couldn't be started. \(error.localizedDescription)")
            return
        }
        status = .installing("Restarting…")
        NSApp.terminate(nil)
    }

    /// Shows the update's disk image in Finder, for installing by hand.
    func showDiskImage() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.activateFileViewerSelecting([update.diskImageURL])
    }

    func showLog() {
        NSWorkspace.shared.activateFileViewerSelecting([UpdateInstaller.logURL])
    }
}
