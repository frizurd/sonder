import AppKit
import Sparkle

/// Updates through Sparkle: once a day Sonder reads the release feed (appcast.xml on the newest GitHub
/// release), and when there's a newer version it offers to download and install it. Each update is
/// checked against the EdDSA key in Info.plist and the app's own code signature before it's installed.
/// scripts/build-dmg.sh writes the feed.
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?

    /// Starts checking. Only for the app bundle: `swift run`, tests and snapshots have no bundle to update.
    func start() {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        if CommandLine.arguments.contains("--debug-update") { debugUpdate() }
        // `--debug-update-window` opens the update window, as Check for Updates… does.
        if CommandLine.arguments.contains("--debug-update-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.checkForUpdates() }
        }
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    /// `SONDER_UPDATE_FEED` points at another feed, to test an update without publishing it.
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["SONDER_UPDATE_FEED"]
    }

    // MARK: Development aid

    /// `--debug-update` checks right away, downloads in the background, logs each step, and quits once
    /// the update is ready, so Sparkle installs it.
    private var debugging = false

    private func debugUpdate() {
        guard let updater = controller?.updater else { return }
        debugging = true
        updater.automaticallyDownloadsUpdates = true
        log("running \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?"), feed \(updater.feedURL?.absoluteString ?? "none")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { updater.checkForUpdatesInBackground() }
    }

    private func log(_ message: String) {
        guard debugging else { return }
        print("update: \(message)")
        fflush(stdout)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log("found \(item.displayVersionString) (\(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        log("no update")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        log("downloaded \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        log("ready to install \(item.displayVersionString) on quit")
        if debugging { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        log("aborted: \(error.localizedDescription)")
    }
}
